import CryptoKit
import Foundation

/// The Minecraft sounds installed on this Mac by a launcher (PrismLauncher), read where they
/// lie: the asset index (`indexes/<id>.json`: "minecraft/sounds/note/harp2.ogg" → SHA-1), the
/// content-addressed objects (`objects/<xx>/<sha1>`) and `minecraft/sounds.json` (sound event →
/// files). Nothing is copied: `MinecraftImport` builds a local SoundFont from them on this Mac.
///
/// Licensing: the user's own game assets, for personal local use only. Neither the .ogg files
/// nor anything built from them (`minecraft-local.sf2`) may enter the repo, a release or the
/// CDN; `music/*` and `records/*` (the soundtrack and discs) are never read.
public struct MinecraftAssets: Sendable {
  /// The assets folder (`…/PrismLauncher/assets`).
  public let root: String
  /// The asset index used (`"32"`: the newest installed, unless asked for another).
  public let indexID: String
  /// Logical path (`minecraft/sounds/note/harp2.ogg`) → object SHA-1.
  let objects: [String: String]
  /// `sounds.json`: event → its sound names (`block.note_block.harp` → [`note/harp2`]).
  let events: [String: [String]]

  public enum Unavailable: Error, CustomStringConvertible, Equatable {
    case noAssets(String)
    case noIndex(String)
    case noSoundsJSON(String)
    case missingObject(String)
    case badHash(String)

    public var description: String {
      switch self {
      case .noAssets(let d):
        return
          "no Minecraft assets at \(d) (install the game with PrismLauncher, or set DJ_MINECRAFT_ASSETS)"
      case .noIndex(let d): return "no asset index in \(d)/indexes"
      case .noSoundsJSON(let i): return "asset index \(i) has no minecraft/sounds.json"
      case .missingObject(let p): return "\(p) is in the index but not downloaded"
      case .badHash(let p): return "\(p) does not match its SHA-1"
      }
    }
  }

  /// Where the assets are looked for: `$DJ_MINECRAFT_ASSETS`, else PrismLauncher's.
  public static var defaultRoot: String {
    if let d = ProcessInfo.processInfo.environment["DJ_MINECRAFT_ASSETS"], !d.isEmpty { return d }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PrismLauncher/assets").path
  }

  /// Sound paths that are never read: the soundtrack and the music discs.
  static func isForbidden(_ sound: String) -> Bool {
    sound.hasPrefix("music/") || sound.hasPrefix("records/")
  }

  /// The installed assets, with the newest index (or `index`), or why there are none.
  public static func locate(root: String = defaultRoot, index: String? = nil) throws
    -> MinecraftAssets
  {
    let fm = FileManager.default
    guard fm.fileExists(atPath: (root as NSString).appendingPathComponent("objects")) else {
      throw Unavailable.noAssets(root)
    }
    let dir = (root as NSString).appendingPathComponent("indexes")
    let ids = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
      .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    guard let id = index ?? newest(ids), ids.contains(id) else { throw Unavailable.noIndex(root) }
    let indexURL = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(id + ".json"))
    let parsed = try JSONValue.parse(String(contentsOf: indexURL, encoding: .utf8))
    var objects: [String: String] = [:]
    for (k, v) in parsed["objects"]?.object?.entries ?? [] {
      if let h = v["hash"]?.string { objects[k] = h }
    }
    guard let sj = objects["minecraft/sounds.json"] else { throw Unavailable.noSoundsJSON(id) }
    let base = MinecraftAssets(root: root, indexID: id, objects: objects, events: [:])
    let sounds = try JSONValue.parse(
      String(contentsOf: URL(fileURLWithPath: base.objectPath(sj)), encoding: .utf8))
    var events: [String: [String]] = [:]
    for (event, def) in sounds.object?.entries ?? [] {
      events[event] = (def["sounds"]?.array ?? []).compactMap { $0.string ?? $0["name"]?.string }
    }
    return MinecraftAssets(root: root, indexID: id, objects: objects, events: events)
  }

  /// Why the assets can't be used, or nil when they can (for a greyed-out palette).
  public static func unavailableReason(root: String = defaultRoot) -> String? {
    do {
      _ = try locate(root: root)
      return nil
    } catch { return "\(error)" }
  }

  /// The numerically newest index id ("5" < "27" < "32").
  static func newest(_ ids: [String]) -> String? {
    ids.max { (Int($0) ?? -1, $0) < (Int($1) ?? -1, $1) }
  }

  func objectPath(_ hash: String) -> String {
    (root as NSString).appendingPathComponent("objects/\(hash.prefix(2))/\(hash)")
  }

  /// The sound names an event plays (`block.note_block.harp` → [`note/harp2`]).
  public func sounds(event: String) -> [String] { events[event] ?? [] }

  /// A sound (`note/harp2`) as a file on disk and its SHA-1, checked: the object exists and
  /// hashes to its name. Never the soundtrack or the discs.
  public func file(sound: String) throws -> (path: String, sha1: String) {
    guard !Self.isForbidden(sound) else { throw Unavailable.missingObject(sound) }
    let logical = "minecraft/sounds/\(sound).ogg"
    guard let hash = objects[logical] else { throw Unavailable.missingObject(logical) }
    let path = objectPath(hash)
    guard let data = FileManager.default.contents(atPath: path) else {
      throw Unavailable.missingObject(logical)
    }
    guard Self.sha1(data) == hash else { throw Unavailable.badHash(logical) }
    return (path, hash)
  }

  static func sha1(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
