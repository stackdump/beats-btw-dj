import Testing

@testable import DJCore

/// A clip of `bars` bars at 120 bpm whose samples say which clip it is.
private func clip(_ n: Int, bars: Int = 1, rate: Double = 48_000) -> LoopClip {
  let len = Int(rate * 2) * bars
  let l = (0..<len).map { i in Float(n) * 0.01 + Float(i % 100) * 1e-4 }
  let b = SampleBuffer(left: l, right: l.map { -$0 }, sampleRate: rate)
  return LoopClip(
    id: b.contentID, title: "A loop \(n)", source: n % 2 == 0 ? "B" : "A", bars: bars, bpm: 120,
    startBeat: Double(4 * n), buffer: b, waveform: WaveformOverview(buffer: b, columns: 40))
}

struct LoopLibraryTests {
  @Test func aSavedRowComesBackAsItWas() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    #expect(lib.load(sampleRate: 48_000).isEmpty, "no library yet")
    let row = [clip(1), clip(2, bars: 2), clip(3)]
    try lib.save(row)
    let back = lib.load(sampleRate: 48_000)
    #expect(back.map(\.id) == row.map(\.id), "same audio, same order")
    #expect(back.map(\.title) == row.map(\.title) && back.map(\.bars) == [1, 2, 1])
    #expect(back.map(\.source) == ["A", "B", "A"] && back.map(\.startBeat) == [4, 8, 12])
    #expect(back.allSatisfy { $0.bpm == 120 })
  }

  @Test func takingAClipOffTheRowMovesItsAudioToRemoved() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (a, b) = (clip(1), clip(2))
    try lib.save([a, b])
    try lib.save([b])
    #expect(loopLibraryFiles(lib) == ["\(b.id).wav", "library.json", "removed"].sorted())
    #expect(removedLoopFiles(lib) == ["\(a.id).wav", "removed.json"].sorted())
    #expect(lib.load(sampleRate: 48_000).map(\.id) == [b.id])
  }

  @Test func anotherSampleRateResamplesAndKeepsTheBars() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    try lib.save([clip(1, bars: 2)])
    let back = try #require(lib.load(sampleRate: 44_100).first)
    #expect(back.bars == 2 && back.bpm == 120)
    #expect(
      abs(back.buffer.length - 2 * 88_200) < 64, "two bars at 44.1 kHz: \(back.buffer.length)")
  }

  @Test @MainActor func restoredClipsJoinTheRowAndReorder() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let row = [clip(1), clip(2), clip(3)]
    dj.restoreClips(row)
    dj.restoreClips([row[0]])  // already there: not twice
    #expect(dj.clips.map(\.id) == row.map(\.id))
    #expect(dj.sampleLibrary[row[1].id] != nil, "a session can name them")
    dj.moveClip(row[2].id, before: row[0].id)
    #expect(dj.clips.map(\.id) == [row[2].id, row[0].id, row[1].id])
    dj.moveClip(row[2].id, before: nil)
    #expect(dj.clips.map(\.id) == [row[0].id, row[1].id, row[2].id])
    dj.setLooping(row[1].id, true)
    #expect(dj.loopState(row[1].id) == .starting, "a restored clip loops like a fresh one")
  }

  @Test @MainActor func aSequenceIsItsStepsBackToBack() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let (a, b) = (clip(1), clip(2, bars: 2))
    dj.restoreClips([a, b])
    let id = try #require(
      dj.makeSequence([SequenceStep(clipID: a.id, repeats: 2), SequenceStep(clipID: b.id)]))
    let seq = try #require(dj.clip(id))
    #expect(dj.clips.map(\.id) == [a.id, b.id, id], "on the end of the row")
    #expect(seq.beats == 4 * 2 + 8 && seq.bpm == 120 && seq.source == a.source)
    #expect(seq.steps == [SequenceStep(clipID: a.id, repeats: 2), SequenceStep(clipID: b.id)])
    func samples(_ c: LoopClip) -> [Float] {
      Array(UnsafeBufferPointer(start: c.buffer.left, count: c.buffer.length))
    }
    #expect(samples(seq) == samples(a) + samples(a) + samples(b), "exactly, sample for sample")
    #expect(seq.title == "seq 1×2→2")
  }

  @Test @MainActor func anotherTempoIsStretchedToTheFirstClips() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let a = clip(1)
    let fast = clip(2)  // same audio length, but say it is at 240 bpm: one bar takes half as long
    let quick = LoopClip(
      id: fast.id, title: fast.title, source: fast.source, bars: 1, bpm: 240, startBeat: 0,
      buffer: fast.buffer, waveform: fast.waveform)
    dj.restoreClips([a, quick])
    let id = try #require(
      dj.makeSequence([SequenceStep(clipID: a.id), SequenceStep(clipID: quick.id)]))
    let seq = try #require(dj.clip(id))
    #expect(seq.bpm == 120 && seq.beats == 8)
    // a's bar, then the 240 bpm bar played at 120: twice as long as it was
    #expect(seq.buffer.length == a.buffer.length + 2 * quick.buffer.length)
  }

  @Test @MainActor func editingASequenceKeepsItsPlaceAndItsLoop() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let (a, b, c) = (clip(1), clip(2), clip(3))
    dj.restoreClips([a, b, c])
    let id = try #require(
      dj.makeSequence([SequenceStep(clipID: a.id), SequenceStep(clipID: b.id)]))
    dj.moveClip(id, before: c.id)
    dj.setClipGain(id, 0.3)
    dj.setLooping(id, true)
    #expect(dj.makeSequence([SequenceStep(clipID: "gone")], replacing: id) == nil, "nothing left")
    dj.perform(
      .clipSequence(
        steps: [SequenceStep(clipID: b.id, repeats: 4), SequenceStep(clipID: "gone")],
        replacing: id))
    let new = try #require(dj.clips[2].steps.map { _ in dj.clips[2] })
    #expect(dj.clips.map(\.id) == [a.id, b.id, new.id, c.id], "where it was")
    #expect(new.steps == [SequenceStep(clipID: b.id, repeats: 4)], "a missing clip is left out")
    #expect(new.beats == 16 && dj.clipGain(new.id) == 0.3)
    #expect(dj.loopState(new.id) == .starting, "it keeps looping")
    #expect(dj.loopState(id) != .on)
  }

  @Test func theLibraryKeepsASequencesSteps() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let plain = clip(5, bars: 2)
    let seq = LoopClip(
      id: DJEngine.sequenceID(plain.buffer), title: "seq x×2→y", source: "A", beats: 8, bpm: 120,
      startBeat: 0, buffer: plain.buffer, waveform: plain.waveform,
      steps: [SequenceStep(clipID: "x", repeats: 2), SequenceStep(clipID: "y")])
    try lib.save([clip(1), seq])
    let back = lib.load(sampleRate: 48_000)
    #expect(back[0].steps == nil && back[1].steps == seq.steps)
    #expect(back[1].id == seq.id, "still a sequence's id after a reload")
    // provenance is kept as it was written
    let p = JSONValue.object(JSONObject([("deck", .string("B")), ("bar", .int(9))]))
    let withP = LoopClip(
      id: plain.id, title: plain.title, source: "B", beats: 8, bpm: 120, startBeat: 32,
      buffer: plain.buffer, waveform: plain.waveform, provenance: p)
    try lib.save([withP])
    #expect(lib.load(sampleRate: 48_000).first?.provenance?.canonicalJS == p.canonicalJS)
    let action = DeckAction.clipSequence(steps: seq.steps!, replacing: "z")
    #expect(DeckAction(json: action.json) == action)
    let fresh = DeckAction.clipSequence(steps: seq.steps!, replacing: nil)
    #expect(DeckAction(json: fresh.json) == fresh)
  }
}
