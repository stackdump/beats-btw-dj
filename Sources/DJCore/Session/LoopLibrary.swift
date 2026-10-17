import Foundation

/// The LOOP-record clips on disk, so the row under the mixer comes back on the next launch:
/// one float WAV per clip, named by its content id, and an index (`library.json`) that keeps
/// the row's order and each clip's bars, tempo, source, name and colour.
///
/// Nothing is deleted by taking a clip off the row: its WAV moves into `removed/` with its
/// index entry (`removed/removed.json`, newest first, with the place it had and when), so it
/// can be put back. Only `deleteForever` deletes audio.
public struct LoopLibrary: Sendable {
  public static let schema = "dj-vevr-se/loops/v1"
  public static let removedSchema = "dj-vevr-se/loops-removed/v1"
  public let dir: URL

  public init(dir: URL = LoopLibrary.defaultDir) { self.dir = dir }

  public static var defaultDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/loops", isDirectory: true)
  }

  var indexFile: URL { dir.appendingPathComponent("library.json") }
  func audioFile(_ id: String) -> URL { dir.appendingPathComponent("\(id).wav") }
  var removedDir: URL { dir.appendingPathComponent("removed", isDirectory: true) }
  var removedIndexFile: URL { removedDir.appendingPathComponent("removed.json") }
  func removedAudioFile(_ id: String) -> URL { removedDir.appendingPathComponent("\(id).wav") }

  /// The saved clips in row order, decoded (and resampled) to `sampleRate`. A missing index is an
  /// empty library; an entry whose audio is gone or unreadable is skipped.
  public func load(sampleRate: Double) -> [LoopClip] {
    entries(indexFile, key: "loops").compactMap {
      Self.clip($0, audio: audioFile, sampleRate: sampleRate)
    }
  }

  /// A clip from its index entry and its audio.
  static func clip(_ e: JSONValue, audio: (String) -> URL, sampleRate: Double) -> LoopClip? {
    guard let id = e["id"]?.string,
      let beats = e["beats"]?.int ?? e["bars"]?.int.map({ $0 * 4 }), beats > 0,
      let bpm = e["bpm"]?.double,
      let buffer = try? Deck.decode(audio(id), sampleRate: sampleRate)
    else { return nil }
    let steps = e["steps"].map { [SequenceStep](json: $0) }
    return LoopClip(
      id: steps == nil ? buffer.contentID : DJEngine.sequenceID(buffer),
      title: e["title"]?.string ?? "loop",
      source: e["source"]?.string ?? "A", beats: beats, bpm: bpm,
      startBeat: e["startBeat"]?.double ?? 0, buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 400), steps: steps,
      provenance: e["provenance"], color: e["color"]?.string)
  }

  /// A clip's index entry.
  static func entry(_ c: LoopClip) -> JSONObject {
    var o = JSONObject([
      ("id", .string(c.id)), ("title", .string(c.title)), ("source", .string(c.source)),
      ("beats", .int(c.beats)), ("bpm", .number(c.bpm)),
      ("startBeat", .number(c.startBeat)),
    ])
    if let color = c.color { o["color"] = .string(color) }
    if let steps = c.steps { o["steps"] = steps.json }
    if let p = c.provenance { o["provenance"] = p }
    return o
  }

  func entries(_ file: URL, key: String) -> [JSONValue] {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
      let doc = try? JSONValue.parse(text)
    else { return [] }
    return doc[key]?.array ?? []
  }

  func write(_ file: URL, schema: String, key: String, _ list: [JSONValue]) throws {
    let doc = JSONValue.object(JSONObject([("schema", .string(schema)), (key, .array(list))]))
    try Data((doc.canonicalJS + "\n").utf8).write(to: file, options: .atomic)
  }

  /// Make the row on disk exactly `clips`, in this order: write the audio of any clip not saved
  /// yet (or move it back out of `removed/`), the index, and move the audio of clips no longer
  /// on the row into `removed/`, each with its entry, its place and when.
  public func save(_ clips: [LoopClip], removedAt date: Date = Date()) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let before = entries(indexFile, key: "loops")
    for c in clips where !fm.fileExists(atPath: audioFile(c.id).path) {
      if fm.fileExists(atPath: removedAudioFile(c.id).path) {
        try fm.moveItem(at: removedAudioFile(c.id), to: audioFile(c.id))
      } else {
        try c.wavData().write(to: audioFile(c.id), options: .atomic)
      }
    }
    try write(indexFile, schema: Self.schema, key: "loops", clips.map { .object(Self.entry($0)) })
    // what left the row goes to removed/, newest first
    let keep = Set(clips.map(\.id))
    let stamp = LoopProvenance.iso.string(from: date)
    var gone: [JSONValue] = []
    for (i, e) in before.enumerated() {
      guard let id = e["id"]?.string, !keep.contains(id), case .object(var o) = e else { continue }
      o["index"] = .int(i)
      o["removed"] = .string(stamp)
      gone.append(.object(o))
    }
    let strays = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
      $0.hasSuffix(".wav") && !keep.contains(String($0.dropLast(4)))
    }
    let old = entries(removedIndexFile, key: "removed")
    if gone.isEmpty && strays.isEmpty && !old.contains(where: { e in
      e["id"]?.string.map(keep.contains) ?? false
    }) {
      return
    }
    try fm.createDirectory(at: removedDir, withIntermediateDirectories: true)
    for f in strays {
      let to = removedDir.appendingPathComponent(f)
      try? fm.removeItem(at: to)  // the same id is the same audio
      try fm.moveItem(at: dir.appendingPathComponent(f), to: to)
    }
    let goneIDs = Set(gone.compactMap { $0["id"]?.string })
    func kept(_ e: JSONValue) -> Bool {
      e["id"]?.string.map { fm.fileExists(atPath: removedAudioFile($0).path) } ?? false
    }
    let list =
      gone.filter(kept)
      + old.filter { e in
        guard let id = e["id"]?.string else { return false }
        return !keep.contains(id) && !goneIDs.contains(id) && kept(e)
      }
    try write(removedIndexFile, schema: Self.removedSchema, key: "removed", list)
  }

  /// The clips taken off the row, newest first (their entries only: no audio is read).
  public func removed() -> [RemovedLoop] {
    entries(removedIndexFile, key: "removed").compactMap(RemovedLoop.init(entry:))
  }

  /// A removed clip with its audio, decoded to `sampleRate`, to put back on the row.
  public func removedClip(_ id: String, sampleRate: Double) -> LoopClip? {
    entries(removedIndexFile, key: "removed").first { $0["id"]?.string == id }.flatMap {
      Self.clip($0, audio: removedAudioFile, sampleRate: sampleRate)
    }
  }

  /// Delete a removed clip for good: its audio and its entry.
  public func deleteForever(_ id: String) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: removedAudioFile(id).path) {
      try fm.removeItem(at: removedAudioFile(id))
    }
    let list = entries(removedIndexFile, key: "removed").filter { $0["id"]?.string != id }
    if fm.fileExists(atPath: removedIndexFile.path) {
      try write(removedIndexFile, schema: Self.removedSchema, key: "removed", list)
    }
  }
}

/// A clip in the library's `removed/`, as its entry says (`LoopLibrary.removed`).
public struct RemovedLoop: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let source: String
  public let beats: Int
  public let bpm: Double
  public let color: String?
  /// Its place on the row when it was taken off.
  public let index: Int
  /// When (ISO 8601).
  public let removed: String
  public let isSequence: Bool

  init?(entry e: JSONValue) {
    guard let id = e["id"]?.string, let bpm = e["bpm"]?.double else { return nil }
    self.id = id
    title = e["title"]?.string ?? "loop"
    source = e["source"]?.string ?? "A"
    beats = e["beats"]?.int ?? (e["bars"]?.int ?? 0) * 4
    self.bpm = bpm
    color = e["color"]?.string
    index = e["index"]?.int ?? 0
    removed = e["removed"]?.string ?? ""
    isSequence = e["steps"] != nil
  }

  /// The same, for a clip removed in this launch (`DJEngine.removedClips`).
  public init(_ r: RemovedClip, removed: String = "") {
    id = r.clip.id
    title = r.clip.title
    source = r.clip.source
    beats = r.clip.beats
    bpm = r.clip.bpm
    color = r.clip.color
    index = r.index
    self.removed = removed
    isSequence = r.clip.steps != nil
  }
}

extension DJEngine {
  /// Put saved clips back on the row (after any already there), ready to loop.
  public func restoreClips(_ restored: [LoopClip]) {
    for c in restored where clip(c.id) == nil {
      sampleLibrary[c.id] = c.buffer
      clips.append(c)
    }
    loopCount = max(loopCount, clips.count)
  }

  /// Move clip `id` on the row to just before `before` (to the end if nil).
  public func moveClip(_ id: String, before: String?) {
    guard id != before, let from = clips.firstIndex(where: { $0.id == id }) else { return }
    let c = clips.remove(at: from)
    let to = before.flatMap { b in clips.firstIndex { $0.id == b } } ?? clips.count
    clips.insert(c, at: to)
  }
}
