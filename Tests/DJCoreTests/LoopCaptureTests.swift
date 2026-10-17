@preconcurrency import AVFoundation
import Testing

@testable import DJCore

// New ways to take a loop: a tap of LOOP that records a fixed number of bars, and grabbing the
// last bars a deck already played out of its capture history.

/// Renders an offline engine the way the app runs it (as `LoopRecordTests`' rig): small blocks,
/// the takes serviced between them. Keeps the master's left channel.
@MainActor
private final class CaptureRig {
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

  func runUntilClip(limit: Int = 10 * 96_000) throws -> LoopClip? {
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

private func samples(_ c: LoopClip) -> [Float] {
  Array(UnsafeBufferPointer(start: c.buffer.left, count: c.buffer.length))
}

/// A sample whose every value says where it is: left[i] = i / length.
private func ramp(bars: Int) -> SampleBuffer {
  let n = bars * bar
  return SampleBuffer(
    left: (0..<n).map { Float($0) / Float(n) }, right: (0..<n).map { -Float($0) / Float(n) },
    sampleRate: 48_000)
}

@MainActor
struct LoopCaptureTests {
  func netDeck(_ dj: DJEngine) async throws -> Deck {
    let d = try #require(dj["A"])
    await d.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    d.setPlaying(true)
    return d
  }

  fileprivate func rampDeck(_ rig: CaptureRig) throws -> (Deck, SampleBuffer) {
    let a = try #require(rig.dj["A"])
    let src = ramp(bars: 12)
    rig.dj.perform(
      .load(deck: "A", source: .sample(id: "", title: "ramp", grid: nil)), buffer: src)
    rig.dj.perform(.grid(deck: "A", bpm: 120, offset: 0))
    a.setPlaying(true)
    return (a, src)
  }

  // MARK: grab

  @Test func grabbingTakesTheLastWholeBarsANetDeckPlayed() async throws {
    let rig = try CaptureRig()
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: 3 * bar + bar / 3)  // a third into bar 3
    rig.dj.perform(.grabBars(deck: "A", bars: 2))
    let clip = try #require(rig.dj.clips.last, "lands at once: the bars are already played")
    #expect(clip.bars == 2 && clip.buffer.length == 2 * bar, "bars 1 and 2, downbeat to downbeat")
    #expect(clip.startBeat == 4 && abs(clip.bpm - 120) < 1e-9 && clip.source == "A")
    // sample for sample what the deck played after its EQ
    let take = samples(clip)
    #expect(maxDiff(take[...], rig.master[bar..<(3 * bar)]) < 1e-6)
    #expect(take.contains { $0 != 0 })
    let p = try #require(clip.provenance)
    #expect(p["grabbed"]?.bool == true && p["bars"]?.int == 2 && p["bar"]?.int == 2)
    #expect(p["source"]?["kind"]?.string == "net")
    // it loops like a fresh take: in at once, in phase
    #expect(rig.dj.loopState(clip.id) == .starting)
    try rig.run(to: rig.dj.frame + 4096)
    #expect(rig.dj.loopState(clip.id) == .on)
  }

  @Test func grabbingASampleDeckEndsOnItsGridsLastDownbeat() throws {
    let rig = try CaptureRig()
    let (_, src) = try rampDeck(rig)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: 3 * bar + bar / 2)
    let id = try #require(rig.dj.grabLastBars("A", bars: 2))
    let clip = try #require(rig.dj.clip(id))
    #expect(clip.bars == 2 && clip.buffer.length == 2 * bar && clip.startBeat == 4)
    // whole bars of the sample: its first sample is a bar line of the ramp (give or take the
    // motor's spin-up and a block, as for a take)
    let at = Double(clip.buffer.left[0]) * Double(src.length)
    let barLine = (at / Double(bar)).rounded() * Double(bar)
    #expect(abs(at - barLine) < 2048, "starts \(at - barLine) samples off a bar line")
    #expect(clip.provenance?["source"]?["id"]?.string == src.contentID)
    #expect(clip.provenance?["grabbed"]?.bool == true)
  }

  @Test func grabbingRefusesWhatTheHistoryDoesNotHold() async throws {
    let rig = try CaptureRig(decks: ["A", "B"])
    #expect(rig.dj.grabLastBars("A", bars: 1) == nil, "a deck that is not playing")
    #expect(rig.dj.grabLastBars("L", bars: 1) == nil, "the loop channel")
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: 3 * bar + bar / 3)
    #expect(rig.dj.grabLastBars("A", bars: 4) == nil, "before the deck started")
    #expect(rig.dj.grabLastBars("A", bars: 0) == nil)
    #expect(rig.dj.clips.isEmpty)
    // past the ring (2^20 frames, ~10.9 bars here): 11 bars back is gone, 10 are still there
    try rig.run(to: 12 * bar + bar / 2)
    #expect(rig.dj.grabLastBars("A", bars: 11) == nil, "beyond the capture history")
    let id = try #require(rig.dj.grabLastBars("A", bars: 10))
    let clip = try #require(rig.dj.clip(id))
    #expect(clip.bars == 10 && clip.buffer.length == 10 * bar && clip.startBeat == 8)
    #expect(maxDiff(samples(clip)[...], rig.master[(2 * bar)..<(12 * bar)]) < 1e-6)
  }

  // MARK: fixed-length takes

  @Test func aTapRecordsExactlyTheBarsItNames() async throws {
    let rig = try CaptureRig()
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    rig.dj.perform(.loopRecord(deck: "A", on: true, bars: 2))
    try rig.run(to: rig.dj.frame + 4096)  // ~85 ms
    rig.dj.perform(.loopRecord(deck: "A", on: false))
    let p = try #require(rig.dj.loopTakeProgress("A"))
    #expect(p.bars == 2 && p.released, "shows the bars it will take while they finish")
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 2 && clip.buffer.length == 2 * bar && clip.startBeat == 4)
    #expect(maxDiff(samples(clip)[...], rig.master[bar..<(3 * bar)]) < 1e-6)
    #expect(!rig.dj.isRecordingLoop("A"))
  }

  @Test func aTapOnASampleDeckCountsBarsAtItsTempo() throws {
    let rig = try CaptureRig()
    _ = try rampDeck(rig)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 2)
    #expect(rig.dj.loopRecord("A", on: true, bars: 4))
    try rig.run(to: rig.dj.frame + rig.dj.loopTapFrames - 512)
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 4 && clip.buffer.length == 4 * bar)
  }

  @Test func aHoldIsAHoldWhateverTheTapLength() async throws {
    let rig = try CaptureRig()
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    rig.dj.loopRecord("A", on: true, bars: 4)
    try rig.run(to: rig.dj.frame + rig.dj.loopTapFrames + 1024)  // just longer than a tap
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 1 && clip.buffer.length == bar, "to the next downbeat, as before")
  }

  @Test func aTapWithoutALengthIsAShortHold() async throws {
    let rig = try CaptureRig()
    _ = try await netDeck(rig.dj)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    rig.dj.loopRecord("A", on: true)
    try rig.run(to: rig.dj.frame + 2048)
    rig.dj.loopRecord("A", on: false)
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 1 && clip.buffer.length == bar)
  }

  @Test func theInpulseLoopButtonTapsTheEnginesLength() async throws {
    let rig = try CaptureRig(decks: ["A", "B"])
    _ = try await netDeck(rig.dj)
    let s = SurfaceController(profile: .inpulse200MK3, engine: rig.dj)
    rig.dj.tapTakeBars = 4
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    s.handle(bytes: [0x91, 0x03, 0x7F])  // deck A LOOP down
    try rig.run(to: rig.dj.frame + 2048)
    s.handle(bytes: [0x91, 0x03, 0x00])  // and up: a tap
    #expect(rig.dj.loopTakeProgress("A")?.bars == 4)
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.bars == 4 && clip.buffer.length == 4 * bar && clip.startBeat == 4)
  }

  // MARK: actions

  @Test func theCaptureActionsRoundTrip() {
    for a in [
      DeckAction.loopRecord(deck: "A", on: true), .loopRecord(deck: "A", on: true, bars: 4),
      .loopRecord(deck: "B", on: false), .grabBars(deck: "A", bars: 2),
      .grabBars(deck: "B", bars: 1),
    ] {
      #expect(DeckAction(json: a.json) == a)
    }
    // a hold-only press encodes as it always did, and an old session's press decodes to one
    #expect(DeckAction.loopRecord(deck: "A", on: true).json["bars"] == nil)
    let old = JSONValue.object(
      JSONObject([("op", .string("loopRecord")), ("deck", .string("A")), ("on", .bool(true))]))
    #expect(DeckAction(json: old) == .loopRecord(deck: "A", on: true, bars: nil))
  }
}
