import Foundation

/// A saved way to play an instrument: a name ("short zap"), the tweak, and whether a sampled
/// channel plays its synth voice with it. Applying one is an ordinary `voiceTweak` (its values
/// inline), so a session replays without the library.
public struct VoiceVariation: Equatable, Sendable {
  public var name: String
  public var params: VoiceTweak
  public var useSynth: Bool
  public init(name: String, params: VoiceTweak, useSynth: Bool = false) {
    self.name = name
    self.params = params
    self.useSynth = useSynth
  }

  /// "laser · short zap": how a chip names it beside its instrument.
  public func label(_ instrument: String) -> String { "\(instrument) · \(name)" }
}

/// The saved variations, on disk: one JSON file (`~/Library/Application
/// Support/dj-vevr-se/voices.json`), instrument name → its variations in the order saved. The
/// only thing about a voice tweak that outlives the app: the tweaks themselves are session state.
public struct VoiceVariationStore {
  public static let schema = "dj-vevr-se/voices/v1"
  public let file: URL

  public init(file: URL = VoiceVariationStore.defaultFile) { self.file = file }

  public static var defaultFile: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/voices.json")
  }

  /// Every instrument's variations. A missing or unreadable file is none.
  public func all() -> [String: [VoiceVariation]] {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
      let doc = try? JSONValue.parse(text), let o = doc["instruments"]?.object
    else { return [:] }
    var out: [String: [VoiceVariation]] = [:]
    for (instrument, list) in o.entries {
      let vs = (list.array ?? []).compactMap(VoiceVariation.init(json:))
      if !vs.isEmpty { out[instrument] = vs }
    }
    return out
  }

  public func list(_ instrument: String) -> [VoiceVariation] { all()[instrument] ?? [] }

  /// Save `variation` for `instrument` (replacing one of the same name, in its place). Returns
  /// the instrument's new list.
  @discardableResult
  public func save(_ variation: VoiceVariation, for instrument: String) throws -> [VoiceVariation] {
    let before = all()
    let after = Self.saving(variation, for: instrument, in: before)
    if after != before { try write(after) }
    return after[instrument] ?? []
  }

  /// Rename one (a name already taken replaces that one). Returns the instrument's new list.
  @discardableResult
  public func rename(_ name: String, to new: String, for instrument: String) throws
    -> [VoiceVariation]
  {
    let before = all()
    let after = Self.renaming(name, to: new, for: instrument, in: before)
    if after != before { try write(after) }
    return after[instrument] ?? []
  }

  /// Delete one. Returns the instrument's new list.
  @discardableResult
  public func delete(_ name: String, for instrument: String) throws -> [VoiceVariation] {
    let after = Self.deleting(name, for: instrument, in: all())
    try write(after)
    return after[instrument] ?? []
  }

  /// Make the file exactly `all` (a journal replay rebuilding the library).
  public func replaceAll(_ all: [String: [VoiceVariation]]) throws { try write(all) }

  // The edits as pure functions of the library, so a journal replay applies what the store does.

  public static func saving(
    _ variation: VoiceVariation, for instrument: String, in all: [String: [VoiceVariation]]
  ) -> [String: [VoiceVariation]] {
    var v = variation
    v.name = clean(v.name)
    guard !v.name.isEmpty else { return all }
    var all = all
    var mine = all[instrument] ?? []
    if let i = mine.firstIndex(where: { $0.name == v.name }) { mine[i] = v } else { mine.append(v) }
    all[instrument] = mine
    return all
  }

  public static func renaming(
    _ name: String, to new: String, for instrument: String, in all: [String: [VoiceVariation]]
  ) -> [String: [VoiceVariation]] {
    let to = clean(new)
    var all = all
    guard !to.isEmpty, var mine = all[instrument],
      let i = mine.firstIndex(where: { $0.name == name }), to != name
    else { return all }
    mine[i].name = to
    mine = mine.enumerated().filter { $0.offset == i || $0.element.name != to }.map(\.element)
    all[instrument] = mine
    return all
  }

  public static func deleting(
    _ name: String, for instrument: String, in all: [String: [VoiceVariation]]
  ) -> [String: [VoiceVariation]] {
    var all = all
    let mine = (all[instrument] ?? []).filter { $0.name != name }
    all[instrument] = mine.isEmpty ? nil : mine
    return all
  }

  static func clean(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func write(_ all: [String: [VoiceVariation]]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let instruments = JSONObject(
      all.keys.sorted().map { k in (k, JSONValue.array(all[k]!.map(\.json))) })
    let doc = JSONValue.object(
      JSONObject([("schema", .string(Self.schema)), ("instruments", .object(instruments))]))
    try Data((doc.jsStringified + "\n").utf8).write(to: file, options: .atomic)
  }
}

extension VoiceVariation {
  /// The entry as the library (and the journal) writes it.
  var json: JSONValue {
    var o = JSONObject([("name", .string(name)), ("params", params.json)])
    if useSynth { o["useSynth"] = .bool(true) }
    return .object(o)
  }

  init?(json e: JSONValue) {
    guard let name = e["name"]?.string, !name.isEmpty else { return nil }
    self.init(
      name: name, params: VoiceTweak(json: e["params"]), useSynth: e["useSynth"]?.bool ?? false)
  }
}
