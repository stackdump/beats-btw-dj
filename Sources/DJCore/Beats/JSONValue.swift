import Foundation

/// A JSON object that remembers key order the way a JS engine does: integer-like
/// keys ("0", "17", up to 2^32-2) first in ascending order, then every other key
/// in insertion order. Re-setting an existing key keeps its original position.
public struct JSONObject: Equatable, Sendable {
  public private(set) var entries: [(key: String, value: JSONValue)] = []
  private var index: [String: Int] = [:]

  public init() {}

  public init(_ pairs: [(String, JSONValue)]) {
    for (k, v) in pairs { self[k] = v }
  }

  public subscript(key: String) -> JSONValue? {
    get { index[key].map { entries[$0].value } }
    set {
      if let i = index[key] {
        if let newValue {
          entries[i].value = newValue
        } else {
          entries.remove(at: i)
          reindex()
        }
      } else if let newValue {
        index[key] = entries.count
        entries.append((key, newValue))
        if Self.arrayIndex(key) != nil { normalizeOrder() }
      }
    }
  }

  public var keys: [String] { entries.map(\.key) }

  public static func == (a: JSONObject, b: JSONObject) -> Bool {
    a.entries.count == b.entries.count
      && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
  }

  /// The numeric value of a canonical array-index key, else nil.
  static func arrayIndex(_ key: String) -> UInt32? {
    guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    if key.utf8.count > 1 && key.utf8.first == 0x30 { return nil }
    guard let n = UInt32(key), n != UInt32.max else { return nil }
    return n
  }

  private mutating func normalizeOrder() {
    let ints = entries.compactMap { e in Self.arrayIndex(e.key).map { ($0, e) } }
      .sorted { $0.0 < $1.0 }.map(\.1)
    let rest = entries.filter { Self.arrayIndex($0.key) == nil }
    entries = ints + rest
    reindex()
  }

  private mutating func reindex() {
    index.removeAll(keepingCapacity: true)
    for (i, e) in entries.enumerated() { index[e.key] = i }
  }
}

public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  public static func int(_ n: Int) -> JSONValue { .number(Double(n)) }
}

public enum JSONError: Error, Equatable {
  case syntax(String, offset: Int)
}

// MARK: - JS-faithful number formatting

/// `Number.prototype.toString()` for a double (ECMAScript Number::toString).
/// Also what `JSON.stringify` writes, except that non-finite values become `null`
/// there (handled by the caller).
public func jsNumberString(_ d: Double) -> String {
  if d.isNaN { return "NaN" }
  if d == 0 { return "0" }  // also -0
  if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
  let sign = d < 0 ? "-" : ""
  // Swift's description is the shortest round-tripping digit string, as JS requires;
  // only the layout differs, so pull out digits + exponent and re-lay them out.
  let text = "\(abs(d))"
  var mantissa = Substring(text)
  var exp10 = 0
  if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
    mantissa = text[..<e]
    exp10 = Int(text[text.index(after: e)...].replacingOccurrences(of: "+", with: "")) ?? 0
  }
  var intPart = mantissa
  var fracPart: Substring = ""
  if let dot = mantissa.firstIndex(of: ".") {
    intPart = mantissa[..<dot]
    fracPart = mantissa[mantissa.index(after: dot)...]
  }
  var digits = String(intPart) + String(fracPart)
  var n = intPart.count + exp10  // decimal point position relative to digits
  // Strip leading zeros (e.g. "0.001"), adjusting n; strip trailing zeros.
  while digits.hasPrefix("0") && digits.count > 1 {
    digits.removeFirst()
    n -= 1
  }
  while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
  let k = digits.count
  let out: String
  if k <= n && n <= 21 {
    out = digits + String(repeating: "0", count: n - k)
  } else if 0 < n && n <= 21 {
    let i = digits.index(digits.startIndex, offsetBy: n)
    out = digits[..<i] + "." + digits[i...]
  } else if -6 < n && n <= 0 {
    out = "0." + String(repeating: "0", count: -n) + digits
  } else {
    let e = n - 1
    let es = (e < 0 ? "-" : "+") + String(abs(e))
    if k == 1 {
      out = digits + "e" + es
    } else {
      let i = digits.index(after: digits.startIndex)
      out = digits[..<i] + "." + digits[i...] + "e" + es
    }
  }
  return sign + out
}

/// ECMAScript ToInt32.
public func jsToInt32(_ d: Double) -> Int32 {
  guard d.isFinite else { return 0 }
  let t = d.rounded(.towardZero)
  let m = t.truncatingRemainder(dividingBy: 4_294_967_296)
  let u = m < 0 ? m + 4_294_967_296 : m
  return Int32(truncatingIfNeeded: UInt32(u))
}

// MARK: - Serialization

extension JSONValue {
  /// `JSON.stringify(value)` — insertion order, compact, JS string escaping.
  public var jsStringified: String {
    var out = ""
    write(&out, sortKeys: false, goEscape: false)
    return out
  }

  /// `canonicalizeJSON` from share/codec.js: sorted keys, plain JSON.stringify strings.
  /// This is what share envelopes are hashed over.
  public var canonicalJS: String {
    var out = ""
    write(&out, sortKeys: true, goEscape: false)
    return out
  }

  /// `canonicalStringify` from pflow.js: sorted keys plus Go's json.Marshal HTML
  /// escaping (`<` `>` `&` U+2028 U+2029). This is what model CIDs are hashed over.
  public var canonicalGo: String {
    var out = ""
    write(&out, sortKeys: true, goEscape: true)
    return out
  }

  private func write(_ out: inout String, sortKeys: Bool, goEscape: Bool) {
    switch self {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .number(let d): out += d.isFinite ? jsNumberString(d) : "null"
    case .string(let s): Self.writeString(s, &out, goEscape: goEscape)
    case .array(let a):
      out += "["
      for (i, v) in a.enumerated() {
        if i > 0 { out += "," }
        v.write(&out, sortKeys: sortKeys, goEscape: goEscape)
      }
      out += "]"
    case .object(let o):
      var entries = o.entries
      if sortKeys {
        // Array.prototype.sort() default: UTF-16 code unit order.
        entries.sort { Array($0.key.utf16).lexicographicallyPrecedes(Array($1.key.utf16)) }
      }
      out += "{"
      for (i, e) in entries.enumerated() {
        if i > 0 { out += "," }
        Self.writeString(e.key, &out, goEscape: goEscape)
        out += ":"
        e.value.write(&out, sortKeys: sortKeys, goEscape: goEscape)
      }
      out += "}"
    }
  }

  private static func writeString(_ s: String, _ out: inout String, goEscape: Bool) {
    out += "\""
    for u in s.unicodeScalars {
      switch u.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x0C: out += "\\f"
      case 0x0A: out += "\\n"
      case 0x0D: out += "\\r"
      case 0x09: out += "\\t"
      case 0..<0x20: out += "\\u" + hex4(u.value)
      case 0x3C where goEscape: out += "\\u003c"
      case 0x3E where goEscape: out += "\\u003e"
      case 0x26 where goEscape: out += "\\u0026"
      case 0x2028 where goEscape: out += "\\u2028"
      case 0x2029 where goEscape: out += "\\u2029"
      default: out.unicodeScalars.append(u)
      }
    }
    out += "\""
  }

  private static func hex4(_ v: UInt32) -> String {
    let h = String(v, radix: 16)
    return String(repeating: "0", count: 4 - h.count) + h
  }
}

// MARK: - Parsing (JSON.parse semantics: order kept, last duplicate wins, numbers are doubles)

extension JSONValue {
  public static func parse(_ text: String) throws -> JSONValue {
    var p = Parser(bytes: Array(text.utf8))
    p.skipWS()
    let v = try p.value()
    p.skipWS()
    if p.i != p.bytes.count { throw JSONError.syntax("trailing characters", offset: p.i) }
    return v
  }

  private struct Parser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func skipWS() {
      while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    func fail(_ m: String) -> JSONError { .syntax(m, offset: i) }

    mutating func value() throws -> JSONValue {
      guard i < bytes.count else { throw fail("unexpected end") }
      switch bytes[i] {
      case UInt8(ascii: "{"): return try object()
      case UInt8(ascii: "["): return try array()
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"):
        try literal("true")
        return .bool(true)
      case UInt8(ascii: "f"):
        try literal("false")
        return .bool(false)
      case UInt8(ascii: "n"):
        try literal("null")
        return .null
      default: return try number()
      }
    }

    mutating func literal(_ s: String) throws {
      let u = Array(s.utf8)
      guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else {
        throw fail("bad literal")
      }
      i += u.count
    }

    mutating func number() throws -> JSONValue {
      let start = i
      if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
      guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad number") }
      if bytes[i] == UInt8(ascii: "0") {
        i += 1
      } else {
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
      }
      if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
        i += 1
        guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad fraction") }
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
      }
      if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
        i += 1
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
          i += 1
        }
        guard i < bytes.count, isDigit(bytes[i]) else { throw fail("bad exponent") }
        while i < bytes.count, isDigit(bytes[i]) { i += 1 }
      }
      let s = String(decoding: bytes[start..<i], as: UTF8.self)
      guard let d = Double(s) else { throw fail("bad number") }
      return .number(d)
    }

    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    mutating func string() throws -> String {
      i += 1  // opening quote
      var units: [UInt16] = []
      var raw: [UInt8] = []
      func flush() {
        if !raw.isEmpty {
          units.append(contentsOf: Array(String(decoding: raw, as: UTF8.self).utf16))
          raw.removeAll()
        }
      }
      while i < bytes.count {
        let b = bytes[i]
        if b == UInt8(ascii: "\"") {
          i += 1
          flush()
          // Lone surrogates can't live in a Swift String; they become U+FFFD.
          return String(decoding: units, as: UTF16.self)
        }
        if b < 0x20 { throw fail("control character in string") }
        if b == UInt8(ascii: "\\") {
          flush()
          i += 1
          guard i < bytes.count else { break }
          let e = bytes[i]
          i += 1
          switch e {
          case UInt8(ascii: "\""): units.append(0x22)
          case UInt8(ascii: "\\"): units.append(0x5C)
          case UInt8(ascii: "/"): units.append(0x2F)
          case UInt8(ascii: "b"): units.append(0x08)
          case UInt8(ascii: "f"): units.append(0x0C)
          case UInt8(ascii: "n"): units.append(0x0A)
          case UInt8(ascii: "r"): units.append(0x0D)
          case UInt8(ascii: "t"): units.append(0x09)
          case UInt8(ascii: "u"):
            guard i + 4 <= bytes.count,
              let v = UInt16(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw fail("bad \\u escape") }
            i += 4
            units.append(v)
          default: throw fail("bad escape")
          }
        } else {
          raw.append(b)
          i += 1
        }
      }
      throw fail("unterminated string")
    }

    mutating func array() throws -> JSONValue {
      i += 1
      var out: [JSONValue] = []
      skipWS()
      if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
        i += 1
        return .array(out)
      }
      while true {
        skipWS()
        out.append(try value())
        skipWS()
        guard i < bytes.count else { throw fail("unterminated array") }
        if bytes[i] == UInt8(ascii: ",") {
          i += 1
          continue
        }
        if bytes[i] == UInt8(ascii: "]") {
          i += 1
          return .array(out)
        }
        throw fail("expected , or ]")
      }
    }

    mutating func object() throws -> JSONValue {
      i += 1
      var obj = JSONObject()
      skipWS()
      if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
        i += 1
        return .object(obj)
      }
      while true {
        skipWS()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
        let k = try string()
        skipWS()
        guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
        i += 1
        skipWS()
        obj[k] = try value()
        skipWS()
        guard i < bytes.count else { throw fail("unterminated object") }
        if bytes[i] == UInt8(ascii: ",") {
          i += 1
          continue
        }
        if bytes[i] == UInt8(ascii: "}") {
          i += 1
          return .object(obj)
        }
        throw fail("expected , or }")
      }
    }
  }
}

// MARK: - Accessors

extension JSONValue {
  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }
  public subscript(index: Int) -> JSONValue? {
    if case .array(let a) = self, a.indices.contains(index) { return a[index] }
    return nil
  }
  public var string: String? { if case .string(let s) = self { s } else { nil } }
  public var double: Double? { if case .number(let d) = self { d } else { nil } }
  public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
  public var object: JSONObject? { if case .object(let o) = self { o } else { nil } }
}
