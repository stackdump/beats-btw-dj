import Testing

@testable import DJCore

/// A one-bar clip at 120 bpm whose samples say which clip it is, with a provenance naming the
/// deck it came from.
private func take(_ n: Int, provenance: JSONValue? = nil) -> LoopClip {
  let len = 96_000
  let l = (0..<len).map { i in Float(n) * 0.01 + Float(i % 100) * 1e-4 }
  let b = SampleBuffer(left: l, right: l.map { -$0 }, sampleRate: 48_000)
  return LoopClip(
    id: b.contentID, title: "A loop \(n)", source: "A", bars: 1, bpm: 120,
    startBeat: Double(4 * n), buffer: b, waveform: WaveformOverview(buffer: b, columns: 40),
    provenance: provenance
      ?? .object(JSONObject([("deck", .string("A")), ("bar", .int(n)), ("title", .string("t"))])))
}

/// LOOP-record provenance of a net deck playing `genre` seed 7, in section 2.
private let netProvenance = JSONValue.object(
  JSONObject([
    ("deck", .string("B")), ("title", .string("techno 7")), ("mode", .string("net")),
    (
      "source",
      .object(
        JSONObject([
          ("kind", .string("net")),
          ("share", .object(JSONObject([("genre", .string("techno")), ("seed", .int(7))]))),
        ]))
    ),
    ("section", .object(JSONObject([("index", .int(2)), ("name", .string("drop"))]))),
  ]))

@MainActor
struct LoopLibraryRemovalTests {
  @Test func removalKeepsTheAudioUnderRemovedWithItsPlace() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (a, b, c) = (take(1), take(2), take(3))
    try lib.save([a, b, c])
    try lib.save([a, c])
    #expect(removedLoopFiles(lib).contains("\(b.id).wav"), "the audio is kept")
    let gone = lib.removed()
    #expect(gone.map(\.id) == [b.id] && gone.first?.index == 1 && gone.first?.title == b.title)
    #expect(gone.first?.removed.isEmpty == false, "with when")
    try lib.save([c])
    #expect(lib.removed().map(\.id) == [a.id, b.id], "newest first")
    #expect(lib.load(sampleRate: 48_000).map(\.id) == [c.id])
  }

  @Test func restoringBringsItBackWithItsProvenanceAndPlace() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (a, b, c) = (take(1), take(2, provenance: netProvenance), take(3))
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj.restoreClips([a, b, c])
    dj.perform(.clipColor(id: b.id, color: "teal"))
    try lib.save(dj.clips)  // the app saves the row whenever it changes
    dj.perform(.clipRemove(id: b.id))
    #expect(dj.clips.map(\.id) == [a.id, c.id] && dj.removedClips.first?.index == 1)
    try lib.save(dj.clips)
    // the next launch: the row from the library, the removed clip from removed/
    let dj2 = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj2.restoreClips(lib.load(sampleRate: 48_000))
    let entry = try #require(lib.removed().first)
    let back = try #require(lib.removedClip(entry.id, sampleRate: 48_000))
    dj2.rememberRemovedClip(back, at: entry.index)
    dj2.perform(.clipRestore(id: b.id, at: nil))
    #expect(dj2.clips.map(\.id) == [a.id, b.id, c.id], "where it was")
    let restored = try #require(dj2.clip(b.id))
    #expect(restored.provenance?.canonicalJS == netProvenance.canonicalJS)
    #expect(restored.color == "teal" && restored.title == b.title)
    #expect(dj2.removedClips.isEmpty)
    try lib.save(dj2.clips)
    #expect(lib.removed().isEmpty && !removedLoopFiles(lib).contains("\(b.id).wav"))
    #expect(loopLibraryFiles(lib).contains("\(b.id).wav"), "moved back")
    #expect(lib.load(sampleRate: 48_000).map(\.id) == [a.id, b.id, c.id])
  }

  @Test func deleteForeverDeletesTheAudio() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (a, b) = (take(1), take(2))
    try lib.save([a, b])
    try lib.save([a])
    try lib.deleteForever(b.id)
    #expect(lib.removed().isEmpty && removedLoopFiles(lib) == ["removed.json"])
    #expect(lib.removedClip(b.id, sampleRate: 48_000) == nil)
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj.restoreClips([a, b])
    dj.perform(.clipRemove(id: b.id))
    dj.perform(.clipForget(id: b.id))
    #expect(!dj.restoreClip(b.id) && dj.clips.map(\.id) == [a.id], "no longer restorable")
  }

  @Test func undoingARemovalPutsItBackAsItWas() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let (a, b, c) = (take(1), take(2), take(3))
    dj.restoreClips([a, b, c])
    dj.setClipGain(a.id, 0.4)
    dj.perform(.clipRemove(id: a.id))
    dj.perform(.clipRemove(id: c.id))
    #expect(dj.removedClips.map(\.clip.id) == [c.id, a.id], "newest first")
    dj.perform(.clipRestore(id: a.id, at: nil))
    #expect(dj.clips.map(\.id) == [a.id, b.id] && dj.clipGain(a.id) == 0.4)
    dj.perform(.clipRestore(id: c.id, at: 0))
    #expect(dj.clips.map(\.id) == [c.id, a.id, b.id], "or where it is asked to go")
    dj.perform(.clipRestore(id: c.id, at: nil))
    #expect(dj.clips.count == 3, "not twice")
  }

  @Test func namesAndColoursAreKeptAndRecorded() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let (a, b) = (take(1), take(2))
    dj.restoreClips([a, b])
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.clipRename(id: a.id, title: "  big drop  "))
    dj.perform(.clipRename(id: b.id, title: "   "))
    dj.perform(.clipColor(id: a.id, color: "orange"))
    dj.perform(.clipColor(id: b.id, color: "chartreuse"))
    #expect(dj.clips.map(\.title) == ["big drop", b.title], "blank names are ignored")
    #expect(dj.clips.map(\.color) == ["orange", nil], "only palette colours")
    dj.cropClip(a.id, from: 0, to: 2)
    #expect(dj.clips[0].title == "big drop" && dj.clips[0].color == "orange", "a crop keeps both")
    try lib.save(dj.clips)
    let back = lib.load(sampleRate: 48_000)
    #expect(back.map(\.title) == ["big drop", b.title] && back.map(\.color) == ["orange", nil])
    let ops = rec.finish().events.compactMap { e -> String? in
      if case .action(let a) = e.kind { return a.json["op"]?.string }
      return nil
    }
    #expect(ops == ["clipRename", "clipRename", "clipColor", "clipColor"])
  }

  @Test func theLibraryActionsRoundTrip() {
    let actions: [DeckAction] = [
      .clipRemove(id: "x"), .clipRestore(id: "x", at: 3), .clipRestore(id: "x", at: nil),
      .clipForget(id: "x"), .clipRename(id: "x", title: "drop → break"),
      .clipColor(id: "x", color: "pink"), .clipColor(id: "x", color: nil),
    ]
    for a in actions {
      #expect(DeckAction(json: a.json) == a, "\(a)")
      #expect(DeckAction(json: try! JSONValue.parse(a.json.canonicalJS)) == a, "\(a) as text")
    }
  }

  @Test func aClipKnowsTheTrackItCameFrom() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let net = take(1, provenance: netProvenance)
    let other = take(9)
    let sampleProv = JSONValue.object(
      JSONObject([
        ("deck", .string("A")),
        (
          "source",
          DeckSourceDescriptor.sample(
            id: other.id, title: "kick.wav", grid: BeatGrid(bpm: 120, offset: 0, confidence: 1)
          ).json
        ),
      ]))
    let sampled = take(2, provenance: sampleProv)
    dj.restoreClips([net, sampled])
    let o = try #require(dj.clipOrigin(net.id))
    guard case .net(let spec) = o.source else {
      Issue.record("a net: \(o.source)")
      return
    }
    #expect(spec.genre == "techno" && spec.seed == 7 && o.section == 2)
    #expect(net.originGenre == "techno" && net.originTitle == "techno 7")
    #expect(dj.clipOrigin(sampled.id) == nil, "its audio is not in the library")
    dj.sampleLibrary[other.id] = other.buffer
    #expect(dj.clipOrigin(sampled.id)?.buffer != nil)
    // a crop (and a crop of a crop) still knows
    let crop = try #require(dj.cropClip(net.id, from: 0, to: 2))
    let crop2 = try #require(dj.cropClip(crop, from: 1, to: 2))
    #expect(dj.clipOrigin(crop2)?.section == 2)
    let seq = try #require(dj.makeSequence([SequenceStep(clipID: crop2)]))
    #expect(dj.clip(seq)?.originGenre == "techno", "and a sequence, by its first step")
  }

  @Test func aClipIsAWAVFile() throws {
    let c = take(4)
    let data = c.wavData()
    #expect(data.count > 96_000 * 8 && data.prefix(4).elementsEqual("RIFF".utf8))
    var named = c
    named.title = "drop: A/B?"
    #expect(named.fileName == "drop- A-B-.wav")
  }
}
