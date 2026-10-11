import Compression
import Foundation

// Port of the byte-level helpers in share/codec.js: base64url (strings and JSON) and
// gzip <-> base64url. gzip is built on the Compression framework's raw deflate
// (COMPRESSION_ZLIB is RFC 1951, no zlib header) with the RFC 1952 header and
// CRC-32 / ISIZE trailer added here, so no zlib dependency is needed.

public enum ShareCodec {
  /// Largest inflated size accepted (a share envelope is a few KB; this only bounds abuse).
  public static let maxInflatedBytes = 16 << 20

  // MARK: base64url

  /// `btoa(bin).replace(+ -> -, / -> _).replace(=+$, '')`
  public static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The decode half shared by `b64urlDecode` / `b64UrlToGunzip`: pad, map to the standard
  /// alphabet, then `atob` (forgiving-base64: ASCII whitespace ignored, bad characters or
  /// a length of 1 mod 4 throw). nil where JS throws.
  public static func base64URLDecode(_ str: String) -> [UInt8]? {
    let pad = String(repeating: "=", count: (4 - str.utf16.count % 4) % 4)
    var s = Array(
      (str + pad).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/").utf8)
    s.removeAll { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0C || $0 == 0x0D }
    if s.count % 4 == 0 {
      if s.last == 0x3D { s.removeLast() }
      if s.last == 0x3D { s.removeLast() }
    }
    if s.count % 4 == 1 { return nil }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var table = [Int](repeating: -1, count: 256)
    for (i, c) in alphabet.enumerated() { table[Int(c)] = i }
    var out: [UInt8] = []
    out.reserveCapacity(s.count * 3 / 4)
    var acc = 0
    var bits = 0
    for c in s {
      let v = table[Int(c)]
      if v < 0 { return nil }
      acc = (acc << 6) | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8((acc >> bits) & 0xFF))
        acc &= (1 << bits) - 1
      }
    }
    return out
  }

  /// `b64urlEncode(obj)`: `JSON.stringify` -> UTF-8 -> base64url.
  public static func b64urlEncode(_ value: JSONValue) -> String {
    base64URL(Array(value.jsStringified.utf8))
  }

  /// `b64urlDecode(str)`: nil on any failure (the JS returns null).
  public static func b64urlDecode(_ str: String) -> JSONValue? {
    guard let bytes = base64URLDecode(str) else { return nil }
    return try? JSONValue.parse(String(decoding: bytes, as: UTF8.self))
  }

  // MARK: gzip

  /// `gzipToB64Url(str)`
  public static func gzipToB64URL(_ text: String) -> String {
    base64URL(gzip(Array(text.utf8)))
  }

  /// `b64UrlToGunzip(str)`: throws where the JS rejects.
  public static func b64URLToGunzip(_ str: String) throws -> String {
    guard let bytes = base64URLDecode(str) else { throw ShareError.badBase64 }
    return String(decoding: try gunzip(bytes), as: UTF8.self)
  }

  /// A single-member gzip stream (deflate, no name, mtime 0, OS unknown).
  public static func gzip(_ input: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]
    if input.isEmpty {
      out += [0x03, 0x00]  // an empty final fixed-Huffman block
    } else {
      let cap = input.count + input.count / 8 + 128
      var dst = [UInt8](repeating: 0, count: cap)
      let n = input.withUnsafeBufferPointer { src in
        dst.withUnsafeMutableBufferPointer { d in
          compression_encode_buffer(
            d.baseAddress!, cap, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
      }
      precondition(n > 0, "deflate failed")
      out += dst[0..<n]
    }
    for shift in stride(from: 0, to: 32, by: 8) {
      out.append(UInt8((crc32(input) >> UInt32(shift)) & 0xFF))
    }
    let size = UInt32(truncatingIfNeeded: input.count)
    for shift in stride(from: 0, to: 32, by: 8) {
      out.append(UInt8((size >> UInt32(shift)) & 0xFF))
    }
    return out
  }

  /// Inflate one gzip member; verifies CRC-32 and ISIZE.
  public static func gunzip(_ data: [UInt8]) throws -> [UInt8] {
    guard data.count >= 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
      throw ShareError.badGzip
    }
    let flags = data[3]
    var i = 10
    if flags & 4 != 0 {
      guard i + 2 <= data.count else { throw ShareError.badGzip }
      i += 2 + Int(data[i]) + Int(data[i + 1]) << 8
    }
    for bit: UInt8 in [8, 16] where flags & bit != 0 {
      guard let z = data[min(i, data.count)...].firstIndex(of: 0) else { throw ShareError.badGzip }
      i = z + 1
    }
    if flags & 2 != 0 { i += 2 }
    let end = data.count - 8
    guard i <= end else { throw ShareError.badGzip }
    func le32(_ at: Int) -> UInt32 {
      (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[at + $1]) << UInt32(8 * $1) }
    }
    let crc = le32(end)
    let size = Int(le32(end + 4))
    guard size <= maxInflatedBytes else { throw ShareError.badGzip }
    var out = [UInt8](repeating: 0, count: max(size, 1))
    let produced: Int
    if size == 0 {
      produced = 0
    } else {
      produced = data[i..<end].withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { d in
          compression_decode_buffer(
            d.baseAddress!, d.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
      }
    }
    guard produced == size else { throw ShareError.badGzip }
    out.removeLast(out.count - size)
    guard crc32(out) == crc else { throw ShareError.badGzip }
    return out
  }

  // MARK: CRC-32 (IEEE, as gzip)

  private static let crcTable: [UInt32] = (0..<256).map { n in
    (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  }

  public static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
  }
}
