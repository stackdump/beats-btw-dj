import Foundation

/// The opt-in composition techniques (`compose` overrides beats doesn't have, plus a few
/// numeric overrides of the genre table), as `generate` takes them: validated, normalised,
/// and stored in a `TrackSpec`'s `extra` so a share / session replays them and its CID
/// reflects them. Options that are off are left out, so "all off" is the plain spec (same
/// CID as before). COMPOSE-OPTIONS.md describes each one.
public enum ComposeOptions {
  /// The keys `generate` accepts.
  public static let keys = [
    "hook", "hookBars", "chordSnap", "chordSnapArp", "layerBudget", "melodyDensity",
    "bassDensity", "ghostNotes", "syncopation", "humanize", "bassFollow", "keyLock",
  ]

  /// Where each option lives in `TrackSpec.extra` (beats' own key when it has one).
  static let storedKey = ["ghostNotes": "ghost-notes"]

  public struct Invalid: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
  }

  /// `spec` with `options` merged into its `extra` (validated; off values removed).
  public static func apply(_ options: JSONObject, to spec: TrackSpec) throws -> TrackSpec {
    var spec = spec
    for (k, v) in options.entries {
      guard keys.contains(k) else {
        throw Invalid(description: "unknown option \(k) (one of \(keys.joined(separator: ", ")))")
      }
      let stored = storedKey[k] ?? k
      spec.extra[stored] = try normalised(k, v)
    }
    if spec.extra["hook"] == nil { spec.extra["hookBars"] = nil }
    if spec.extra["chordSnap"] == nil { spec.extra["chordSnapArp"] = nil }
    return spec
  }

  /// The options a spec carries, under their `generate` names (for deck state).
  public static func describe(_ spec: TrackSpec) -> JSONObject {
    var o = JSONObject()
    for k in keys {
      if let v = spec.extra[storedKey[k] ?? k] { o[k] = v }
    }
    return o
  }

  /// nil = off (not stored).
  static func normalised(_ k: String, _ v: JSONValue) throws -> JSONValue? {
    func bad(_ want: String) -> Invalid { Invalid(description: "\(k): expected \(want)") }
    func unit() throws -> JSONValue {
      guard let d = v.double, d >= 0, d <= 1 else { throw bad("a number 0…1") }
      return .number(d)
    }
    switch k {
    case "hook", "chordSnapArp", "bassFollow", "keyLock":
      guard let b = v.bool else { throw bad("true or false") }
      return b ? .bool(true) : nil
    case "hookBars":
      guard let d = v.double, d == 1 || d == 2 else { throw bad("1 or 2") }
      return .int(Int(d))
    case "chordSnap":
      if let b = v.bool { return b ? .string("strong") : nil }
      guard let s = v.string, ["off", "strong", "all"].contains(s) else {
        throw bad("off | strong | all")
      }
      return s == "off" ? nil : .string(s)
    case "layerBudget":
      if v.string == "auto" { return .string("auto") }
      if v.string == "off" || v.bool == false { return nil }
      guard let d = v.double, d == d.rounded(), d >= 0, d <= 8 else {
        throw bad("\"auto\", \"off\" or an integer 1…8")
      }
      return d == 0 ? nil : .int(Int(d))
    case "melodyDensity", "bassDensity":
      guard let d = v.double, d > 0, d <= 1 else { throw bad("a number in (0, 1]") }
      return .number(d)
    case "ghostNotes", "syncopation":
      return try unit()
    case "humanize":
      guard let d = v.double, d >= 0, d <= 100 else { throw bad("a number 0…100") }
      return .number(d)
    default:
      throw Invalid(description: "unknown option \(k)")
    }
  }
}
