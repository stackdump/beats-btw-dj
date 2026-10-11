import Foundation

// Port of share/url.js `parseShareFromUrl` / `buildShareUrlForms` (the pure parts) and of
// the raw-`nets` branch of petri-note.js `_bootGenerate`.
//
// A share link is `?cid=z<base58>&z=<base64url-gzip>`: self-contained when `z` is present
// (decoded, re-hashed, and refused unless it matches `cid`), otherwise a short link whose
// payload lives on a server — fetching is the caller's job (`.needsFetch`), and the
// fetched text goes through `Share.decode(json:cid:)`, which re-hashes it the same way.
// Legacy `?p=` / `?g=&s=&structure=&t=` links still parse.

public enum ShareLink {
  /// A verified `share-v1` envelope (`shareFromPayload(payload, cid)`).
  case envelope(Share)
  /// A short link. `legacy` is what the JS falls back to when the fetch fails.
  case needsFetch(cid: String, legacy: JSONValue?)
  /// A legacy link: `?p=` returns the decoded object verbatim (it only has to have a
  /// truthy `genre`); `?g=` returns `{ genre, params }`.
  case legacy(JSONValue)

  /// Parse a share URL. Accepts a full URL, `?query`, or a bare `a=b&c=d` query. `location.search`
  /// is what the JS reads; as an extension (no JS counterpart) a URL with no query but a
  /// `#a=b` fragment reads the fragment instead. nil when the link carries nothing usable.
  public static func parse(_ link: String) -> ShareLink? {
    let q = Query(Self.queryString(of: link))
    if let cid = q["cid"], !cid.isEmpty {
      if let z = q["z"], !z.isEmpty {
        if let text = try? ShareCodec.b64URLToGunzip(z),
          let payload = try? JSONValue.parse(text)
        {
          // JS: any decode/parse failure is swallowed (console.warn) and falls through.
          if BeatsCID.shareCID(payload) == cid {
            return .envelope(Share(payload: payload, cid: cid))
          }
        }
      } else {
        return .needsFetch(cid: cid, legacy: legacy(q))
      }
    }
    return legacy(q).map { .legacy($0) }
  }

  private static func legacy(_ q: Query) -> JSONValue? {
    if let p = q["p"], !p.isEmpty, let decoded = ShareCodec.b64urlDecode(p),
      let g = decoded["genre"], g.isTruthy
    {
      return decoded
    }
    guard let g = q["g"], !g.isEmpty else { return nil }
    var params = JSONObject()
    if let s = q["s"], let n = jsParseInt(s) { params["seed"] = .number(n) }
    if let st = q["structure"], !st.isEmpty { params["structure"] = .string(st) }
    if let t = q["t"], !t.isEmpty, let traits = ShareCodec.b64urlDecode(t) {
      switch traits {
      case .object(let o): for (k, v) in o.entries { params[k] = v }
      case .array(let a): for (i, v) in a.enumerated() { params[String(i)] = v }
      default: break
      }
    }
    return .object(JSONObject([("genre", .string(g)), ("params", .object(params))]))
  }

  // MARK: building

  /// `buildShareUrlForms`: the short (`?cid=`) and self-contained (`?cid=&z=`) forms for a payload.
  public static func forms(payload: JSONValue, base: String) -> (
    cid: String, short: String, full: String
  ) {
    let canonical = payload.canonicalJS
    let cid = BeatsCID.shareCID(canonical: canonical)
    return (cid, "\(base)?cid=\(cid)", "\(base)?cid=\(cid)&z=\(ShareCodec.gzipToB64URL(canonical))")
  }

  // MARK: query handling (URLSearchParams)

  static func queryString(of link: String) -> String {
    var s = Substring(link)
    var fragment: Substring = ""
    if let h = s.firstIndex(of: "#") {
      fragment = s[s.index(after: h)...]
      s = s[..<h]
    }
    if let qm = s.firstIndex(of: "?") { return String(s[s.index(after: qm)...]) }
    if !fragment.isEmpty { return String(fragment) }
    return s.contains("://") ? "" : String(s)
  }

  /// `new URLSearchParams(search)`: `+` is a space, percent escapes decode as UTF-8 (bad
  /// sequences become U+FFFD), `get` returns the first match.
  struct Query {
    var pairs: [(String, String)] = []
    init(_ s: String) {
      for part in s.split(separator: "&", omittingEmptySubsequences: true) {
        let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        pairs.append((Self.decode(kv[0]), kv.count > 1 ? Self.decode(kv[1]) : ""))
      }
    }
    subscript(key: String) -> String? { pairs.first { $0.0 == key }?.1 }

    static func decode(_ s: Substring) -> String {
      var out: [UInt8] = []
      let u = Array(s.utf8)
      var i = 0
      func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
      }
      while i < u.count {
        if u[i] == 0x2B {
          out.append(0x20)
        } else if u[i] == 0x25, i + 2 < u.count, let a = hex(u[i + 1]), let b = hex(u[i + 2]) {
          out.append(a << 4 | b)
          i += 2
        } else {
          out.append(u[i])
        }
        i += 1
      }
      return String(decoding: out, as: UTF8.self)
    }
  }
}

/// JS `parseInt(s, 10)`: leading whitespace, optional sign, digits; nil for NaN.
func jsParseInt(_ s: String) -> Double? {
  var digits = ""
  var sign = 1.0
  var started = false
  for c in s.unicodeScalars {
    if !started && digits.isEmpty && c.properties.isWhitespace { continue }
    if !started && (c == "-" || c == "+") {
      started = true
      if c == "-" { sign = -1 }
      continue
    }
    started = true
    guard c.isASCII, c.properties.numericType != nil else { break }
    digits.unicodeScalars.append(c)
  }
  guard !digits.isEmpty, let d = Double(digits) else { return nil }
  return sign * d
}

// MARK: - Raw-nets envelopes

extension Share {
  /// The browser expands a raw-`nets` envelope with `ArrangeWithOpts` when it carries a
  /// `structure` other than "loop". That port is not done (see ROADMAP 2.4), so such an
  /// envelope has no honest project yet.
  public var needsArrange: Bool {
    guard nets != nil, let s = structure else { return false }
    return s != .string("loop")
  }

  /// `deriveShareName` (petri-note.js): the name of a hand-authored share with none.
  /// Seeded from the CID (djb2 over UTF-16 units) when there is one, else the numeric seed.
  public var derivedName: String {
    var seed: UInt32 = 0
    if let cid {
      var h: Int32 = 5381
      for u in cid.utf16 { h = (h &* 33) ^ Int32(u) }
      seed = UInt32(bitPattern: h)
    } else if let s = params["seed"]?.double {
      seed = UInt32(bitPattern: jsToInt32(s))
    }
    if seed == 0 { seed = 1 }
    return generateTrackName(genre: genre ?? "custom", seed: Double(seed))
  }

  /// The project the browser loads for a raw-`nets` envelope (`project-load`): name, tempo /
  /// swing / humanize from the overrides, the nets verbatim, `initialMutes`. nil when the
  /// envelope has no nets or still needs arranging (`needsArrange`).
  public func rawNetsProject() -> Project? {
    guard let nets, !needsArrange else { return nil }
    var proj = JSONObject()
    proj["name"] = .string(name ?? derivedName)
    proj["tempo"] = overrides?["tempo"] ?? .number(120)
    proj["swing"] = overrides?["swing"] ?? .number(0)
    proj["humanize"] = overrides?["humanize"] ?? .number(0)
    proj["nets"] = nets
    if let m = overrides?["initialMutes"], m.isTruthy { proj["initialMutes"] = m }
    return Project(json: .object(proj))
  }

  /// Legacy `{ genre, params }` links as a `Share` (the composer path).
  public init(legacy: JSONValue) {
    var p = JSONObject()
    p["genre"] = legacy["genre"]
    self.init(payload: .object(p))
    params = legacy["params"]?.object ?? JSONObject()
  }
}
