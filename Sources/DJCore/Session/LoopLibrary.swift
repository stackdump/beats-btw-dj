import Foundation

/// The LOOP-record clips on disk, so the row under the mixer comes back on the next launch:
/// one float WAV per clip, named by its content id, and an index (`library.json`) that keeps
/// the row's order and each clip's bars, tempo and source. Removing a clip from the row
/// removes its file.
public struct LoopLibrary: Sendable {
  public static let schema = "dj-vevr-se/loops/v1"
  public let dir: URL

  public init(dir: URL = LoopLibrary.defaultDir) { self.dir = dir }

  public static var defaultDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/loops", isDirectory: true)
  }

  var indexFile: URL { dir.appendingPathComponent("library.json") }
  func audioFile(_ id: String) -> URL { dir.appendingPathComponent("\(id).wav") }

  /// The saved clips in row order, decoded (and resampled) to `sampleRate`. A missing index is an
  /// empty library; an entry whose audio is gone or unreadable is skipped.
  public func load(sampleRate: Double) -> [LoopClip] {
    guard let text = try? String(contentsOf: indexFile, encoding: .utf8),
      let doc = try? JSONValue.parse(text)
    else { return [] }
    return (doc["loops"]?.array ?? []).compactMap { e in
      guard let id = e["id"]?.string,
        let beats = e["beats"]?.int ?? e["bars"]?.int.map({ $0 * 4 }), beats > 0,
        let bpm = e["bpm"]?.double,
        let buffer = try? Deck.decode(audioFile(id), sampleRate: sampleRate)
      else { return nil }
      let steps = e["steps"].map { [SequenceStep](json: $0) }
      return LoopClip(
        id: steps == nil ? buffer.contentID : DJEngine.sequenceID(buffer),
        title: e["title"]?.string ?? "loop",
        source: e["source"]?.string ?? "A", beats: beats, bpm: bpm,
        startBeat: e["startBeat"]?.double ?? 0, buffer: buffer,
        waveform: WaveformOverview(buffer: buffer, columns: 400), steps: steps,
        provenance: e["provenance"])
    }
  }

  /// Make the disk hold exactly `clips`, in this order: write the audio of any clip not saved
  /// yet, the index, and delete the audio of clips no longer on the row.
  public func save(_ clips: [LoopClip]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for c in clips where !fm.fileExists(atPath: audioFile(c.id).path) {
      let b = c.buffer
      let audio = RenderedAudio(
        sampleRate: b.sampleRate, left: Array(UnsafeBufferPointer(start: b.left, count: b.length)),
        right: Array(UnsafeBufferPointer(start: b.right, count: b.length)))
      try WAV.encode(audio, float32: true).write(to: audioFile(c.id), options: .atomic)
    }
    let doc = JSONValue.object(
      JSONObject([
        ("schema", .string(Self.schema)),
        (
          "loops",
          .array(
            clips.map { c in
              var o = JSONObject([
                ("id", .string(c.id)), ("title", .string(c.title)), ("source", .string(c.source)),
                ("beats", .int(c.beats)), ("bpm", .number(c.bpm)),
                ("startBeat", .number(c.startBeat)),
              ])
              if let steps = c.steps { o["steps"] = steps.json }
              if let p = c.provenance { o["provenance"] = p }
              return .object(o)
            })
        ),
      ]))
    try Data((doc.canonicalJS + "\n").utf8).write(to: indexFile, options: .atomic)
    let keep = Set(clips.map { "\($0.id).wav" })
    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    where f.hasSuffix(".wav") && !keep.contains(f) {
      try? fm.removeItem(at: dir.appendingPathComponent(f))
    }
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
