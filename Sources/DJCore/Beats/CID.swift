import CryptoKit
import Foundation

/// Content ids exactly as beats computes them: CIDv1, dag-json (0x0129),
/// sha2-256, base58btc with the multibase `z` prefix.
public enum BeatsCID {
  static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

  public static func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

  public static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
  }

  public static func encodeBase58(_ bytes: [UInt8]) -> String {
    var digits: [UInt8] = []  // base58 digits, least significant first
    for b in bytes {
      var carry = Int(b)
      for j in 0..<digits.count {
        carry += Int(digits[j]) << 8
        digits[j] = UInt8(carry % 58)
        carry /= 58
      }
      while carry > 0 {
        digits.append(UInt8(carry % 58))
        carry /= 58
      }
    }
    let zeros = bytes.prefix { $0 == 0 }.count
    let body = digits.reversed().map { alphabet[Int($0)] }
    return String(decoding: [UInt8](repeating: alphabet[0], count: zeros) + body, as: UTF8.self)
  }

  public static func decodeBase58(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []  // big-endian-free accumulator, least significant first
    for c in text.utf8 {
      guard let v = alphabet.firstIndex(of: c) else { return nil }
      var carry = v
      for j in 0..<out.count {
        carry += Int(out[j]) * 58
        out[j] = UInt8(carry & 0xFF)
        carry >>= 8
      }
      while carry > 0 {
        out.append(UInt8(carry & 0xFF))
        carry >>= 8
      }
    }
    let zeros = text.utf8.prefix { $0 == alphabet[0] }.count
    return [UInt8](repeating: 0, count: zeros) + out.reversed()
  }

  /// `createCIDv1Bytes`: 0x01, dag-json varint (a9 02), sha2-256 (12 len), digest.
  public static func cidV1Bytes(hash: [UInt8]) -> [UInt8] {
    [0x01, 0xA9, 0x02, 0x12, UInt8(hash.count)] + hash
  }

  /// `computeCidForJsonLd`: canonicalizeJSON → sha256 → CIDv1 → `z` + base58.
  public static func shareCID(_ doc: JSONValue) -> String {
    shareCID(canonical: doc.canonicalJS)
  }

  public static func shareCID(canonical: String) -> String {
    "z" + encodeBase58(cidV1Bytes(hash: sha256(Array(canonical.utf8))))
  }

  /// Model CID: lowercase hex sha256 of `canonicalProjectJSON` (Go-escaped).
  public static func modelCID(canonicalProject: String) -> String {
    hex(sha256(Array(canonicalProject.utf8)))
  }
}
