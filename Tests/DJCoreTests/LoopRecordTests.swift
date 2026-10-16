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

  @Test func aClipLoopsOnTheLoopChannelAndMovesToADeck() async throws {
    let rig = try Rig(decks: ["A", "B"])
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + 100)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: 2 * bar - 100)
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    let l = rig.dj.loopChannel
    #expect(rig.dj["L"] === l)
    #expect(l.clipID == clip.id && l.playing && l.looping)
    #expect(l.loopStart == 0 && l.loopEnd == Double(clip.buffer.length))
    #expect(l.beatGrid?.bpm == clip.bpm)
    // in time with A: the same place in the bar
    try rig.run(to: rig.dj.frame + bar / 3)
    let la = try #require(l.beatState)
    let aa = try #require(rig.dj["A"]!.beatState)
    let err = (la.barPhase - aa.barPhase).magnitude
    #expect(min(err, 1 - err) < 0.02, "loop \(la.barPhase) vs A \(aa.barPhase)")
    try rig.run(to: rig.dj.frame + 2 * bar)
    #expect(l.playing, "still looping past its end")

    rig.dj.perform(.clip(deck: "B", id: clip.id))
    let b = try #require(rig.dj["B"])
    #expect(b.clipID == clip.id && b.looping && b.beatGrid?.bpm == clip.bpm)
    #expect(!l.playing, "moved off the loop channel")
    #expect(rig.dj.sampleLibrary[clip.id] != nil, "a session can name it")

    rig.dj.perform(.clip(deck: "L", id: clip.id))
    #expect(l.playing && l.clipID == clip.id)
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
      .clip(deck: "L", id: "abc"),
    ] {
      #expect(DeckAction(json: a.json) == a)
    }
  }
}
