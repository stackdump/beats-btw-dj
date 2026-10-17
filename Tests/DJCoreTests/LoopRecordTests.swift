@preconcurrency import AVFoundation
import Testing

@testable import DJCore

/// Renders an offline engine the way the app runs it: small blocks, the takes serviced between
/// them (the hub's housekeeping tick). Keeps the master's left channel.
@MainActor
private final class Rig {
  let dj: DJEngine
  let out: AVAudioPCMBuffer
  var master: [Float] = []
  static let block = 512

  init(decks: [String] = ["A"]) throws {
    dj = try DJEngine(decks: decks, offline: true, sampleRate: 48_000)
    out = AVAudioPCMBuffer(
      pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.block))!
    // the strip at unity, so the master window is the deck after its EQ, sample for sample
    dj.crossfader = 0
    dj.master = 1
    for d in dj.decks.values { d.volume = 1 }
  }

  /// Render until engine frame `frame`.
  func run(to frame: Int) throws {
    while dj.frame < frame {
      let n = min(Self.block, frame - dj.frame)
      guard try dj.engine.renderOffline(AVAudioFrameCount(n), to: out) == .success else { return }
      master += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
    }
  }

  /// Render until a clip lands (at most `limit` more frames).
  func runUntilClip(limit: Int = 4 * 96_000) throws -> LoopClip? {
    let count = dj.clips.count
    let stop = dj.frame + limit
    while dj.clips.count == count, dj.frame < stop { try run(to: dj.frame + Self.block) }
    return dj.clips.count > count ? dj.clips.last : nil
  }
}

private let bar = 96_000  // 120 bpm at 48 kHz

private func maxDiff(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
  zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

/// A sample whose every value says where it is: left[i] = i / length.
private func ramp(bars: Int) -> SampleBuffer {
  let n = bars * bar
  return SampleBuffer(
    left: (0..<n).map { Float($0) / Float(n) }, right: (0..<n).map { -Float($0) / Float(n) },
    sampleRate: 48_000)
}

@MainActor
struct LoopRecordTests {
  func netDeck(_ dj: DJEngine) async throws -> Deck {
    let d = try #require(dj["A"])
    await d.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    d.setPlaying(true)
    return d
  }

  @Test func theCaptureTapIsOnAndBeforeTheFader() throws {
    let rig = try Rig()
    let a = try #require(rig.dj["A"])
    #expect(a.capture.isAttached)
    a.loadDemo()
    a.volume = 0  // the take is pre-fader: a closed fader still records
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: 48_000)
    #expect(a.capture.endFrame == a.renderedFrames)
    var l: [Float] = []
    var r: [Float] = []
    _ = a.capture.copy(from: 24_000, to: 48_000, left: &l, right: &r)
    #expect(l.count == 24_000 && l.contains { $0 != 0 })
    #expect(rig.master[24_000...].allSatisfy { $0 == 0 }, "the fader is closed")
  }

  @Test func aNetTakeIsWholeBarsFromDownbeatToDownbeat() async throws {
    let rig = try Rig()
    let a = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)  // a third into bar 1
    #expect(rig.dj.loopRecord("A", on: true))
    try rig.run(to: 2 * bar + bar / 2)  // half way through bar 2
    #expect(rig.dj.loopRecord("A", on: false))
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 2)
    #expect(clip.startBeat == 4, "snapped back to bar 1")
    #expect(clip.buffer.length == 2 * bar, "ended at the downbeat of bar 3")
    #expect(abs(clip.bpm - 120) < 1e-9)
    #expect(clip.source == "A" && !rig.dj.isRecordingLoop("A"))
    // sample for sample what the deck played after its EQ (the master, with the strip at unity)
    let take = Array(UnsafeBufferPointer(start: clip.buffer.left, count: clip.buffer.length))
    #expect(maxDiff(take[...], rig.master[bar..<(3 * bar)]) < 1e-6)
    #expect(take.contains { $0 != 0 })
    _ = a
  }

  @Test func releasingOnTheOneEndsThere() async throws {
    let rig = try Rig()
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 2)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar + bar / 40)  // just after the downbeat of bar 2
    rig.dj.loopRecord("A", on: false)
    // that bar is already in the history: the clip lands on the release itself
    let clip = try #require(rig.dj.clips.last)
    #expect(clip.bars == 1 && clip.buffer.length == bar)
  }

  @Test func aSampleTakeSnapsToTheGrid() throws {
    let rig = try Rig()
    let a = try #require(rig.dj["A"])
    let src = ramp(bars: 8)
    rig.dj.perform(
      .load(deck: "A", source: .sample(id: "", title: "ramp", grid: nil)), buffer: src)
    rig.dj.perform(.grid(deck: "A", bpm: 120, offset: 0))
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 2)
    #expect(rig.dj.loopRecord("A", on: true))
    try rig.run(to: 3 * bar + bar / 4)
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 3 && clip.buffer.length == 3 * bar)
    #expect(abs(clip.bpm - 120) < 1e-9)
    // The first sample is the source's bar line, give or take the motor's spin-up and a block.
    let at = Double(clip.buffer.left[0]) * Double(src.length)
    let barLine = (at / Double(bar)).rounded() * Double(bar)
    #expect(abs(at - barLine) < 2048, "starts \(at - barLine) samples off a bar line")
  }

  @Test func pressingAStoppedDeckDoesNothing() throws {
    let rig = try Rig()
    rig.dj["A"]!.loadDemo()
    #expect(!rig.dj.loopRecord("A", on: true))
    #expect(!rig.dj.isRecordingLoop("A"))
    #expect(!rig.dj.loopRecord("A", on: false))
    #expect(!rig.dj.loopRecord("L", on: true), "the loop channel does not record itself")
  }

  /// Two one-bar takes of a net deck at 120 bpm, both looping under the mixer.
  fileprivate func twoTakes(_ rig: Rig) async throws -> (LoopClip, LoopClip) {
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    try rig.run(to: bar + 100)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar - 100)
    rig.dj.loopRecord("A", on: false)
    let one = try #require(try rig.runUntilClip())
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: rig.dj.frame + bar / 2)
    rig.dj.loopRecord("A", on: false)
    let two = try #require(try rig.runUntilClip())
    return (one, two)
  }

  /// Engine frames where the loop channel's capture is silent / sounding, around `frame`.
  func quietBefore(_ l: Deck, _ frame: Int) -> (before: Float, after: Float) {
    var bl: [Float] = []
    var br: [Float] = []
    var al: [Float] = []
    var ar: [Float] = []
    _ = l.capture.copy(from: frame - 256, to: frame, left: &bl, right: &br)
    _ = l.capture.copy(from: frame, to: frame + 2048, left: &al, right: &ar)
    return (bl.map(abs).max() ?? 0, al.map(abs).max() ?? 0)
  }

  @Test func severalClipsLoopAtOnceInTimeWithTheirDeck() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    #expect(Set(rig.dj.loopingClips) == [one.id, two.id], "a new take joins, it does not replace")
    try rig.run(to: rig.dj.frame + 4096)  // a fresh take comes in a lead's time after it lands
    #expect(rig.dj.loopState(one.id) == .on && rig.dj.loopState(two.id) == .on)
    // each voice sits at the same place in the bar as deck A
    try rig.run(to: rig.dj.frame + bar / 3)
    let a = try #require(rig.dj["A"]!.beatState)
    for c in [one, two] {
      let v = try #require(rig.dj.loopVoices.firstIndex { $0.clipID == c.id })
      let tt = rig.dj.loopChannel.bank!.voices[v]
      let phase = (tt.position / Double(c.buffer.length) * Double(c.bars))
        .truncatingRemainder(dividingBy: 1)
      let err = abs(phase - a.barPhase)
      #expect(min(err, 1 - err) < 0.01, "\(c.title) at \(phase) of its bar, A at \(a.barPhase)")
    }
  }

  @Test func aClipGoesInAndOutOnTheDownbeat() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    let l = rig.dj.loopChannel
    rig.dj.perform(.clipLoop(id: two.id, on: false))
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    #expect(rig.dj.loopState(one.id) == .stopping)
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopState(one.id) == .off && rig.dj.loopingClips.isEmpty)
    // in again: silent until A's next downbeat, sounding from it
    let clock = rig.dj.loopClock(for: one)
    let down = clock.nextDownbeat(after: l.renderedFrames + DJEngine.loopLead)
    #expect(clock.ref === rig.dj["A"])
    #expect(abs(clock.beat(down) / 4 - (clock.beat(down) / 4).rounded()) < 1e-9)
    rig.dj.perform(.clipLoop(id: one.id, on: true))
    #expect(rig.dj.loopState(one.id) == .starting)
    try rig.run(to: down + bar / 2)
    #expect(rig.dj.loopState(one.id) == .on)
    let edge = quietBefore(l, down)
    #expect(edge.before == 0 && edge.after > 0.001, "comes in at frame \(down): \(edge)")
  }

  @Test func aClipMovesOntoADeckAndBack() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, _) = try await twoTakes(rig)
    #expect(rig.dj["L"] === rig.dj.loopChannel)
    rig.dj.perform(.clip(deck: "B", id: one.id))
    let b = try #require(rig.dj["B"])
    #expect(b.clipID == one.id && b.looping && b.beatGrid?.bpm == one.bpm)
    #expect(rig.dj.loopState(one.id) != .on, "moved off the loops under the mixer")
    #expect(rig.dj.sampleLibrary[one.id] != nil, "a session can name it")
    try rig.run(to: rig.dj.frame + 4096)
    rig.dj.perform(.clip(deck: "L", id: one.id))
    #expect(rig.dj.loopState(one.id) == .starting)
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopState(one.id) == .on)
  }

  @Test func aClipHasItsOwnLevel() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, _) = try await twoTakes(rig)
    rig.dj.perform(.clipGain(id: one.id, value: 0.25))
    #expect(rig.dj.clipGain(one.id) == 0.25)
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    try rig.run(to: rig.dj.frame + bar + 4096)
    rig.dj.perform(.clipLoop(id: one.id, on: true))
    #expect(rig.dj.clipGain(one.id) == 0.25, "kept across a stop and a start")
  }

  @Test func cropKeepsTheBeatsBetweenTheEdges() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    rig.dj.perform(.clipGain(id: one.id, value: 0.5))
    #expect(one.beats == 4 && rig.dj.loopState(one.id) == .on)
    // nothing to crop, or out of range: refused
    #expect(rig.dj.cropClip(one.id, from: 0, to: 4) == nil)
    #expect(rig.dj.cropClip(one.id, from: 2, to: 2) == nil)
    #expect(rig.dj.cropClip(one.id, from: 1, to: 5) == nil)
    rig.dj.perform(.clipCrop(id: one.id, from: 1, to: 3))
    let c = try #require(rig.dj.clips.first)
    #expect(c.id != one.id && rig.dj.clips.map(\.id) == [c.id, two.id], "in the original's place")
    #expect(c.beats == 2 && c.lengthLabel == "2 beats" && c.bpm == one.bpm)
    #expect(c.startBeat == one.startBeat + 1 && c.source == "A")
    let perBeat = one.buffer.length / 4
    #expect(c.buffer.length == 2 * perBeat)
    let want = Array(UnsafeBufferPointer(start: one.buffer.left + perBeat, count: 2 * perBeat))
    let got = Array(UnsafeBufferPointer(start: c.buffer.left, count: c.buffer.length))
    #expect(got == want, "beats 2 and 3 of the original, sample for sample")
    #expect(rig.dj.clipGain(c.id) == 0.5, "its level carries over")
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.loopState(one.id) == .off, "the original stopped looping")
    #expect(rig.dj.loopState(c.id) == .on, "the cropped one carries on")
    #expect(rig.dj.sampleLibrary[c.id] != nil)
  }

  @Test func aTakeKnowsWhereItCameFrom() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let a = try await netDeck(rig.dj)
    a.eqLow = 0.2
    a.pitch = 0.25
    a.toggleStem("mic")
    try rig.dj.start()
    try rig.run(to: bar + 100)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar - 100)
    #expect(rig.dj.isRecordingLoop("A"))
    rig.dj.loopRecord("A", on: false)
    for _ in 0..<200 where rig.dj.clips.isEmpty { try rig.run(to: rig.dj.frame + Rig.block) }
    let one = try #require(rig.dj.clips.first)
    let p = try #require(one.provenance)
    #expect(p["deck"]?.string == "A" && p["mode"]?.string == "net")
    #expect(p["source"]?["kind"]?.string == "net")
    #expect(p["source"]?["share"]?["genre"]?.string == "techno")
    #expect(p["shareCID"]?.string == a.netSource?.favoriteCID, "names the track it came from")
    #expect(p["bar"]?.int == 2 && p["startBeat"]?.double == 4 && p["bars"]?.int == 1)
    #expect(abs((p["tempo"]?["bpm"]?.double ?? 0) - 120 * 1.02) < 1e-6)
    #expect(p["tempo"]?["pitch"]?.double == 0.25)
    #expect(p["params"]?["eqLow"]?.double == 0.2)
    #expect(p["stemsMuted"]?.array == [.string("mic")])
    #expect(p["rolesOff"]?.array?.contains(.string("melody")) == true)
    #expect(p["recorded"]?.string != nil && p["build"]?.string != nil)

    // a crop and a sequence say what they were made from
    let cropped = try #require(rig.dj.cropClip(one.id, from: 0, to: 2))
    let cp = try #require(rig.dj.clip(cropped)?.provenance)
    #expect(cp["op"]?.string == "crop" && cp["from"]?.string == one.id)
    #expect(cp["beats"]?.array == [.int(0), .int(2)] && cp["parent"]?.canonicalJS == p.canonicalJS)
    let seq = try #require(rig.dj.makeSequence([SequenceStep(clipID: cropped, repeats: 2)]))
    let sp = try #require(rig.dj.clip(seq)?.provenance)
    #expect(sp["op"]?.string == "sequence")
    #expect(
      sp["steps"]?.array?.first?["provenance"]?.canonicalJS == cp.canonicalJS,
      "outlives the clips it used")
  }

  @Test func aSampleTakeNamesItsSampleByContent() throws {
    let rig = try Rig()
    let a = try #require(rig.dj["A"])
    let src = ramp(bars: 8)
    rig.dj.perform(.load(deck: "A", source: .sample(id: "", title: "ramp", grid: nil)), buffer: src)
    rig.dj.perform(.grid(deck: "A", bpm: 120, offset: 0))
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 2)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar + bar / 4)
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    let s = try #require(clip.provenance?["source"])
    #expect(s["kind"]?.string == "sample" && s["title"]?.string == "ramp")
    #expect(s["id"]?.string == src.contentID)
    #expect(s["grid"]?["bpm"]?.double == 120)
  }

  @Test func inpulseLoopPadsSwitchLoopsAndLightWhileTheyPlay() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    let s = SurfaceController(profile: .inpulse200MK3, engine: rig.dj)
    rig.dj.stopAllLoops()
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopingClips.isEmpty)
    _ = s.ledFrame()
    // deck A, LOOP pad mode (channel 6): pad 1 (0x28) = loop 1, pad 2 (0x2A: the notes run
    // down the columns) = loop 2
    s.handle(bytes: [0x96, 0x28, 0x7F])
    s.handle(bytes: [0x96, 0x28, 0x00])
    #expect(rig.dj.loopState(one.id) == .starting && rig.dj.loopState(two.id) == .off)
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopState(one.id) == .on)
    #expect(s.ledFrame().contains([0x96, 0x28, 0x7F]), "its pad lights while it plays")
    s.handle(bytes: [0x96, 0x2A, 0x7F])
    s.handle(bytes: [0x96, 0x28, 0x7F])
    #expect(rig.dj.loopState(two.id) == .starting && rig.dj.loopState(one.id) == .stopping)
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopState(two.id) == .on && rig.dj.loopState(one.id) == .off)
    let leds = s.ledFrame()
    #expect(leds.contains([0x96, 0x28, 0x00]) && leds.contains([0x96, 0x2A, 0x7F]))
    // a pad with no loop in its slot does nothing, and stays dark
    s.handle(bytes: [0x96, 0x2B, 0x7F])
    #expect(rig.dj.loopingClips == [two.id])
    // deck B's pads are loops 5-8: none yet
    s.handle(bytes: [0x97, 0x28, 0x7F])
    #expect(rig.dj.loopingClips == [two.id])
  }

  @Test func mpkBankBPadsAreLoopsOneToEight() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    let s = SurfaceController(profile: .mpkMiniMK2, engine: rig.dj)
    rig.dj.stopAllLoops()
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopingClips.isEmpty)
    // NOTE mode, bank B, channel 10: pad 1 (note 44) = loop 1, pad 2 (45) = loop 2
    s.handle(bytes: [0x99, 0x2C, 0x7F])
    s.handle(bytes: [0x89, 0x2C, 0x00])
    #expect(rig.dj.loopState(one.id) == .starting && rig.dj.loopState(two.id) == .off)
    s.handle(bytes: [0x99, 0x2D, 0x7F])
    #expect(rig.dj.loopState(two.id) == .starting)
    // pad 8 (note 51) is loop 8: no loop there, nothing happens
    s.handle(bytes: [0x99, 0x33, 0x7F])
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(Set(rig.dj.loopingClips) == [one.id, two.id])
    // bank A is the aimed deck's parts on/off
    #expect(s.binding(for: try #require(s.decode([0x99, 0x24, 0x7F])))?.action == .roleMute)
    let map = SurfaceProfile.mpkMiniMK2.deviceMap()
    #expect(map.first { $0.group == "padNotes" && $0.index == 8 }?.action == "loop 1 in/out")
    #expect(map.first { $0.group == "padNotes" && $0.index == 15 }?.action == "loop 8 in/out")
  }

  @Test func apcShiftTurnsTheGridIntoTheLoopPage() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, two) = try await twoTakes(rig)
    let s = SurfaceController(profile: .apcMiniMK2, engine: rig.dj)
    rig.dj.stopAllLoops()
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopingClips.isEmpty)
    // the top-left pad (56) is the aimed deck's first stinger: white, dim
    #expect(s.ledFrame().contains([0x92, 56, 3]))
    s.handle(bytes: [0x90, 0x7A, 0x7F])  // SHIFT down
    // the loop page: loops are dark until they play (loop 1 is there but off)
    #expect(s.ledFrame().contains([0x92, 56, 0]))
    s.handle(bytes: [0x90, 56, 0x7F])  // SHIFT + top-left = loop 1
    s.handle(bytes: [0x80, 56, 0x00])
    #expect(rig.dj.loopState(one.id) == .starting && rig.dj.loopState(two.id) == .off)
    #expect(s.ledFrame().contains([0x9E, 56, 48]), "violet, blinking on its way in")
    #expect(s.lights()["pads"]?[56] == PadLight(colorIndex: 48, level: .blink))
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(rig.dj.loopState(one.id) == .on)
    #expect(s.ledFrame().contains([0x96, 56, 48]), "violet, full while it plays")
    // the pad right of it is loop 2
    s.handle(bytes: [0x90, 57, 0x7F])
    #expect(rig.dj.loopState(two.id) == .starting)
    // SHIFT up: the grid's own colours come back, and the loops keep playing
    s.handle(bytes: [0x80, 0x7A, 0x00])
    let back = s.ledFrame()
    #expect(back.contains([0x92, 56, 3]) && back.contains([0x92, 57, 3]))
    #expect(s.lights()["pads"]?[56] == PadLight(colorIndex: 3, level: .dim))
    try rig.run(to: rig.dj.frame + bar + 4096)
    #expect(Set(rig.dj.loopingClips) == [one.id, two.id])
    // without SHIFT the pad is its stinger again, not the loop
    #expect(s.binding(for: try #require(s.decode([0x90, 56, 0x7F])))?.action == .stinger)
  }

  @Test func aNewSampleForgetsTheOldLoopRegion() throws {
    // a deck that looped something (a clip moved onto it loops its whole length) and then
    // loads a longer sample plays that sample to its end
    let rig = try Rig()
    let a = try #require(rig.dj["A"])
    a.load(ramp(bars: 1), title: "short")
    a.setLoop(0, Double(bar / 2))
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar)
    let long = ramp(bars: 4)
    a.load(long, title: "long")
    #expect(!a.looping && a.loopStart == nil)
    try rig.run(to: rig.dj.frame + 3 * bar)
    #expect(a.turntable.position > Double(bar), "past the old loop's end: \(a.turntable.position)")
  }

  @Test func loopsFollowTheLouderDeck() async throws {
    let rig = try Rig(decks: ["A", "B"])
    defer { rig.dj.stop() }
    let (one, _) = try await twoTakes(rig)  // taken from A at 120
    let b = try #require(rig.dj["B"])
    await b.generate(TrackSpec(genre: "house", seed: 3, extra: JSONObject([("bpm", .number(126))])))
    b.volume = 1
    b.setPlaying(true)
    func tempo() -> Double? {
      rig.dj.loopVoices.first { $0.clipID == one.id }?.targetBPM
    }
    #expect(rig.dj.loopFollow == .louder, "the default")
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.dominantDeck == "A" && abs((tempo() ?? 0) - 120) < 1e-6, "A is up")
    rig.dj.perform(.crossfader(1))  // all B
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.dominantDeck == "B" && abs((tempo() ?? 0) - 126) < 1e-6, "B took over")
    rig.dj.perform(.crossfader(0.5))  // equal: no flapping back
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.dominantDeck == "B")
    rig.dj.perform(.loopFollow(mode: "source"))
    try rig.run(to: rig.dj.frame + 4096)
    #expect(abs((tempo() ?? 0) - 120) < 1e-6, "its own deck again")
    rig.dj.perform(.loopFollow(mode: "louder"))
    b.mute = true  // a silent deck is not the louder one
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.dominantDeck == "A")
    let action = DeckAction.loopFollow(mode: "source")
    #expect(DeckAction(json: action.json) == action)
  }

  @Test func theLoopChannelHasItsOwnMute() throws {
    let rig = try Rig()
    let l = rig.dj.loopChannel
    l.volume = 1
    #expect(l.strip.outputVolume == 1)
    rig.dj.perform(.param(deck: "L", name: "volume", value: 0.5))
    #expect(l.volume == 0.5)
    l.mute = true
    #expect(l.strip.outputVolume == 0)
    l.mute = false
    #expect(l.strip.outputVolume == 0.5)
  }

  @Test func theActionsRoundTrip() {
    for a in [
      DeckAction.loopRecord(deck: "A", on: true), .loopRecord(deck: "B", on: false),
      .clip(deck: "L", id: "abc"), .clipLoop(id: "abc", on: true),
      .clipGain(id: "abc", value: 0.5), .clipCrop(id: "abc", from: 1, to: 3),
    ] {
      #expect(DeckAction(json: a.json) == a)
    }
  }
}
