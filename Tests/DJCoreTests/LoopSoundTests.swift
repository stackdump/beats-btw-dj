@preconcurrency import AVFoundation
import Testing

@testable import DJCore

/// An offline engine rendered the way the app runs it (as LoopRecordTests' rig): 512-frame
/// blocks, the takes and loops serviced between them.
@MainActor
private final class SoundRig {
  let dj: DJEngine
  let out: AVAudioPCMBuffer
  static let block = 512

  init(decks: [String] = ["A", "B"]) throws {
    dj = try DJEngine(decks: decks, offline: true, sampleRate: 48_000)
    out = AVAudioPCMBuffer(
      pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.block))!
    dj.crossfader = 0
    dj.master = 1
    for d in dj.decks.values { d.volume = 1 }
  }

  func run(to frame: Int) throws {
    while dj.frame < frame {
      let n = min(Self.block, frame - dj.frame)
      guard try dj.engine.renderOffline(AVAudioFrameCount(n), to: out) == .success else { return }
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
    }
  }

  func run(_ frames: Int) throws { try run(to: dj.frame + frames) }

  /// Deck A plays a 120 bpm techno net; one bar of it is taken and loops under the mixer.
  func oneTake() async throws -> LoopClip {
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    try dj.start()
    try run(to: bar + 100)
    dj.loopRecord("A", on: true)
    try run(to: 2 * bar - 100)
    dj.loopRecord("A", on: false)
    let count = dj.clips.count
    for _ in 0..<800 where dj.clips.count == count { try run(Self.block) }
    let clip = try #require(dj.clips.last)
    try run(4096)  // in
    return clip
  }

  /// A second take, after the first.
  func anotherTake() throws -> LoopClip {
    dj.loopRecord("A", on: true)
    try run(bar / 2)
    dj.loopRecord("A", on: false)
    let count = dj.clips.count
    for _ in 0..<800 where dj.clips.count == count { try run(Self.block) }
    try run(4096)
    return try #require(dj.clips.last)
  }

  /// The loop channel's peak over its last `frames`.
  func loopPeak(_ frames: Int = 4096) -> Float {
    var l: [Float] = []
    var r: [Float] = []
    let lc = dj.loopChannel
    _ = lc.capture.copy(
      from: lc.renderedFrames - frames, to: lc.renderedFrames, left: &l, right: &r)
    return max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
  }

  func voice(_ id: String) throws -> Int {
    try #require(dj.loopVoices.firstIndex { $0.clipID == id })
  }

  /// How far through its bar clip `c`'s voice is, against deck A's bar: the error, 0…0.5.
  func phaseError(_ c: LoopClip) throws -> Double {
    let tt = dj.loopChannel.bank!.voices[try voice(c.id)]
    let len = Double(tt.length)
    let phase = (tt.position / len * Double(c.bars)).truncatingRemainder(dividingBy: 1)
    let a = try #require(dj["A"]!.beatState)
    let err = abs(phase - a.barPhase)
    return min(err, 1 - err)
  }
}

private let bar = 96_000  // 120 bpm at 48 kHz

/// A loop bank with one voice holding a constant 1.0 (so its output is its gain), playing.
private func dcBank(fade: Int, at frame: Int = 100) -> LoopBank {
  let bank = LoopBank(sampleRate: 48_000)
  let tt = bank.voices[0]
  tt.load(SampleBuffer(left: [Float](repeating: 1, count: 4800), sampleRate: 48_000))
  tt.send(.loop(start: 0, end: 4800))
  tt.send(.start)
  bank.send(.gain(voice: 0, 1))
  bank.send(.start(voice: 0, frame: frame, fade: fade))
  return bank
}

/// Render `frames` of `bank` from deck frame `start`: the left channel.
private func render(_ bank: LoopBank, _ frames: Int, from start: Int) -> [Float] {
  var l = [Float](repeating: 0, count: frames)
  var r = [Float](repeating: 0, count: frames)
  l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
      bank.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: start)
    }
  }
  return l
}

@MainActor
struct LoopSoundTests {
  // MARK: the bank: fades and ramps on the audio thread

  @Test func aStartRampsUpFromZero() {
    let bank = dcBank(fade: 480)
    let out = render(bank, 1024, from: 0)
    #expect(out[0..<100].allSatisfy { $0 == 0 }, "silent before its frame")
    #expect(out[100] == 0, "the first sample is at 0")
    for k in [1, 120, 240, 479] {
      #expect(abs(out[100 + k] - Float(k) / 480) < 1e-4, "\(k) in: \(out[100 + k])")
    }
    #expect(zip(out[100..<580], out[101..<581]).allSatisfy { $0 <= $1 }, "rises, never steps back")
    #expect(out[580...].allSatisfy { abs($0 - 1) < 1e-6 }, "then holds at its level")
  }

  @Test func withTheFadeOffAStartIsAtOnce() {
    let out = render(dcBank(fade: 0), 512, from: 0)
    #expect(out[99] == 0 && out[100] == 1)
  }

  @Test func aFadedStopEndsAtZeroAfterTheFade() {
    let bank = dcBank(fade: 0, at: 0)
    _ = render(bank, 512, from: 0)
    bank.send(.stop(voice: 0, frame: 1000, fade: 2400))
    let out = render(bank, 4096, from: 512)
    let at = 1000 - 512
    #expect(abs(out[at - 1] - 1) < 1e-6 && abs(out[at] - 1) < 1e-6, "full until the stop")
    #expect(abs(out[at + 1200] - 0.5) < 1e-3, "half way down half way through")
    #expect(zip(out[at..<(at + 2400)], out[(at + 1)...]).allSatisfy { $0 >= $1 }, "falls only")
    #expect(out[(at + 2400)...].allSatisfy { $0 == 0 }, "silent from the fade's end")
    #expect(!bank.isActive(0), "and then the voice is off")
  }

  @Test func aStopWithoutAFadeCutsAndAFadingVoiceStaysOnUntilItEnds() {
    let bank = dcBank(fade: 0, at: 0)
    _ = render(bank, 512, from: 0)
    bank.send(.stop(voice: 0, frame: 600, fade: 4000))
    _ = render(bank, 512, from: 512)
    #expect(bank.isActive(0), "still fading")
    // started again while fading out: it comes back up instead of going
    bank.send(.start(voice: 0, frame: 0, fade: 480))
    let out = render(bank, 2048, from: 1024)
    #expect(bank.isActive(0) && abs(out.last! - 1) < 1e-6)
    bank.send(.stop(voice: 0, frame: 3100, fade: 0))
    let cut = render(bank, 512, from: 3072)
    #expect(cut[27] == 1 && cut[28...].allSatisfy { $0 == 0 } && !bank.isActive(0))
  }

  @Test func aLevelChangeRampsInsteadOfStepping() {
    let bank = dcBank(fade: 0, at: 0)
    _ = render(bank, 512, from: 0)
    bank.send(.gain(voice: 0, 0.5))
    let out = render(bank, 512, from: 512)
    let ramp = bank.rampFrames
    #expect(ramp == 240, "5 ms")
    #expect(out[0] > 0.99 && abs(out[ramp / 2] - 0.75) < 0.01 && abs(out[ramp + 10] - 0.5) < 1e-6)
    let steps = zip(out[0..<ramp], out[1...]).map { abs($0 - $1) }
    #expect(steps.max()! < 0.01, "no zipper step: \(steps.max()!)")
  }

  // MARK: mute and solo

  @Test func aMutedLoopIsSilentAndKeepsItsPlace() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    let one = try await rig.oneTake()
    #expect(rig.loopPeak() > 0.001, "it plays")
    rig.dj.perform(.clipMute(id: one.id, on: true))
    #expect(rig.dj.isClipMuted(one.id) && rig.dj.audibleClipGain(one.id) == 0)
    let v = try rig.voice(one.id)
    let tt = rig.dj.loopChannel.bank!.voices[v]
    let before = tt.position
    try rig.run(bar / 2)
    #expect(rig.loopPeak(bar / 4) == 0, "a muted voice adds silence")
    #expect(rig.dj.loopState(one.id) == .on, "but it is still looping")
    #expect(tt.position != before, "and its playhead moved on")
    rig.dj.perform(.clipMute(id: one.id, on: false))
    try rig.run(bar / 4)
    #expect(rig.loopPeak() > 0.001, "back")
    #expect(try rig.phaseError(one) < 0.01, "in time with deck A, as if it had never stopped")
  }

  @Test func soloSilencesEveryLoopThatIsNotSoloed() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    let one = try await rig.oneTake()
    let two = try rig.anotherTake()
    #expect(Set(rig.dj.loopingClips) == [one.id, two.id])
    rig.dj.perform(.clipSolo(id: two.id, on: true))
    #expect(rig.dj.audibleClipGain(one.id) == 0 && rig.dj.audibleClipGain(two.id) == 1)
    try rig.run(bar / 4)
    #expect(rig.loopPeak() > 0.001, "the soloed one plays")
    // with the soloed one muted too, nothing is left: the other is soloed out
    rig.dj.perform(.clipMute(id: two.id, on: true))
    try rig.run(bar / 4)
    #expect(rig.loopPeak() == 0)
    rig.dj.perform(.clipSolo(id: two.id, on: false))
    try rig.run(bar / 4)
    #expect(rig.loopPeak() > 0.001, "solo off: the first is heard again")
    #expect(rig.dj.loopState(one.id) == .on && rig.dj.loopState(two.id) == .on)
  }

  @Test func muteSoloAndKeyLockFollowACrop() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    let one = try await rig.oneTake()
    rig.dj.perform(.clipMute(id: one.id, on: true))
    rig.dj.perform(.clipSolo(id: one.id, on: true))
    rig.dj.perform(.clipKeyLock(id: one.id, on: true))
    let c = try #require(rig.dj.cropClip(one.id, from: 0, to: 2))
    #expect(rig.dj.isClipMuted(c) && rig.dj.isClipSoloed(c) && rig.dj.isKeyLocked(c))
    #expect(!rig.dj.isClipMuted(one.id) && !rig.dj.isClipSoloed(one.id))
    rig.dj.removeClip(c)
    #expect(!rig.dj.isClipSoloed(c) && rig.dj.clipSolos.isEmpty)
  }

  // MARK: fades in the engine

  @Test func theRowsFadeSetsHowLongALoopTakesToGoOut() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    #expect(rig.dj.loopFade == .declick)
    let one = try await rig.oneTake()
    rig.dj.perform(.loopFade(mode: "bar"))
    #expect(rig.dj.loopFade == .bar)
    #expect(
      rig.dj.loopFadeFrames(bpm: 120) == bar && rig.dj.loopFadeFrames(bpm: 120, short: true) == 480)
    rig.dj.perform(.clipLoop(id: one.id, on: false))
    let stop = try #require(rig.dj.loopVoices[try rig.voice(one.id)].stopFrame)
    try rig.run(to: stop + bar / 2)
    #expect(rig.dj.loopState(one.id) == .stopping, "half way through its bar-long fade")
    try rig.run(to: stop + bar + 4096)
    #expect(rig.dj.loopState(one.id) == .off && rig.loopPeak() == 0)
  }

  // MARK: key lock

  @Test func wsolaKeepsTheLengthToTheRatio() {
    let sr = 48_000.0
    let x = sineTone(hz: 440, count: 96_000, sampleRate: sr)
    for ratio in [0.8, 0.97, 1.25, 1.5] {
      let out = TimeStretch.wsola(left: x, right: x, ratio: ratio, sampleRate: sr)
      let want = Double(x.count) / ratio
      #expect(abs(Double(out.left.count) - want) <= 512, "\(ratio): \(out.left.count) vs \(want)")
      #expect(out.left.count == out.right.count)
    }
  }

  @Test func wsolaKeepsTheFrequencyOfATone() {
    let sr = 48_000.0
    // 440 periods in a second: a seamless loop, as a clip is
    let x = sineTone(hz: 440, count: 48_000, sampleRate: sr)
    for ratio in [0.8, 1.25] {
      let out = TimeStretch.wsola(left: x, right: x, ratio: ratio, sampleRate: sr).left
      let n = out.count
      let hz = zeroCrossingHz(out[(n / 8)..<(7 * n / 8)], sampleRate: sr)
      #expect(abs(hz / 440 - 1) < 0.01, "at \(ratio)×: \(hz) Hz")
      // and it is a tone, not a gap-filled mess: about the input's level throughout
      let peak = out[(n / 8)..<(7 * n / 8)].map(abs).max() ?? 0
      #expect(peak > 0.45 && peak < 0.55, "peak \(peak)")
    }
  }

  @Test func aLockedLoopAtAnotherTempoPlaysAStretchedCopyAtPitchZero() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    let one = try await rig.oneTake()
    let a = try #require(rig.dj["A"])
    a.pitch = 0.5  // +4 %: 124.8 bpm
    try rig.run(bar / 4)  // the turntable eases to its new speed
    let v = try rig.voice(one.id)
    let tt = rig.dj.loopChannel.bank!.voices[v]
    #expect(abs(tt.currentRate - 1.04) < 1e-3, "unlocked: varispeed, \(tt.currentRate)")
    #expect(!rig.dj.isClipStretched(one.id))
    rig.dj.perform(.clipKeyLock(id: one.id, on: true))
    #expect(rig.dj.isKeyLocked(one.id))
    // the tempo holds for the debounce, the copy renders off the main thread, then swaps in
    for _ in 0..<2000 where !rig.dj.isClipStretched(one.id) {
      try rig.run(SoundRig.block)
      if rig.dj.isClipStretching(one.id) { try await Task.sleep(for: .milliseconds(2)) }
    }
    #expect(rig.dj.isClipStretched(one.id))
    try rig.run(2048)
    let want = Double(one.buffer.length) / 1.04
    #expect(abs(Double(tt.length) - want) <= 1, "the stretched copy: \(tt.length) vs \(want)")
    // pitch 0, give or take the copy's length being whole samples (a few ppm)
    #expect(abs(tt.currentRate - 1) < 1e-4, "at turntable pitch 0: \(tt.currentRate)")
    #expect(try rig.phaseError(one) < 0.01, "swapped in phase")
    #expect(rig.loopPeak() > 0.001)

    // unlocked again: back to its own audio, varispeed
    rig.dj.perform(.clipKeyLock(id: one.id, on: false))
    try rig.run(2048)
    #expect(!rig.dj.isClipStretched(one.id) && tt.length == one.buffer.length)
    #expect(abs(tt.currentRate - 1.04) < 1e-3, "varispeed at once: \(tt.currentRate)")
    #expect(try rig.phaseError(one) < 0.01)
  }

  @Test func theRowsKeyLockCoversClipsWithoutTheirOwn() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    rig.dj.deterministic = true  // the stretch renders inline, as in a replay
    let one = try await rig.oneTake()
    rig.dj.perform(.loopKeyLock(on: true))
    #expect(rig.dj.loopKeyLock && rig.dj.isKeyLocked(one.id))
    rig.dj["A"]!.pitch = -0.5  // −4 %
    try rig.run(Int(DJEngine.stretchDebounce * 48_000) + 8192)
    #expect(rig.dj.isClipStretched(one.id))
    // a clip's own setting wins over the row's
    rig.dj.perform(.clipKeyLock(id: one.id, on: false))
    try rig.run(2048)
    #expect(!rig.dj.isClipStretched(one.id))
    // back near its own tempo, a locked loop needs no copy
    rig.dj.perform(.clipKeyLock(id: one.id, on: true))
    rig.dj["A"]!.pitch = 0.02
    try rig.run(Int(DJEngine.stretchDebounce * 48_000) + 8192)
    #expect(!rig.dj.isClipStretched(one.id))
  }

  @Test func theRowsFadeAndKeyLockStartARecordedSession() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let quiet = try SessionRecorder.start(on: dj)
    #expect(quiet.finish().events.isEmpty, "at the defaults there is nothing to say")
    dj.perform(.loopFade(mode: "bar"))
    dj.perform(.loopKeyLock(on: true))
    let rec = try SessionRecorder.start(on: dj)
    let events = rec.finish().events.map(\.kind)
    #expect(events == [.action(.loopFade(mode: "bar")), .action(.loopKeyLock(on: true))])
    // so a replay, from a fresh engine, fades and locks as the set did
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    for case .action(let a) in events { fresh.perform(a) }
    #expect(fresh.loopFade == .bar && fresh.loopKeyLock)
  }

  @Test func theLoopClockKeepsAVoicesTempoThroughASwap() async throws {
    let rig = try SoundRig()
    defer { rig.dj.stop() }
    rig.dj.deterministic = true  // the stretch renders inline
    let one = try await rig.oneTake()
    let a = try #require(rig.dj["A"])
    a.pitch = 0.625  // +5 %: 126 bpm
    rig.dj.perform(.clipKeyLock(id: one.id, on: true))
    try rig.run(Int(DJEngine.stretchDebounce * 48_000) + 8192)
    #expect(rig.dj.isClipStretched(one.id))
    // nothing plays: the loop is the clock, at the tempo it was left at
    a.setPlaying(false)
    try rig.run(4096)
    let v = try rig.voice(one.id)
    #expect(abs(rig.dj.loopVoices[v].targetBPM - 126) < 0.01)
    #expect(abs((rig.dj.loopClock(for: nil).bpm ?? 0) - 126) < 0.05)
    // unlock: the voice swaps back to its own 120 bpm audio at speed 1.05, from the next block.
    // Until that block, the clock still says 126 (not the new audio's 120 × the old rate 1).
    rig.dj.perform(.clipKeyLock(id: one.id, on: false))
    #expect(rig.dj.loopVoices[v].bufferBPM == one.bpm, "the swap is queued")
    let clock = rig.dj.loopClock(for: nil)
    #expect(abs((clock.bpm ?? 0) - 126) < 0.05, "\(clock.bpm ?? 0)")
    #expect(abs(clock.framesPerBeat - 60 / 126 * 48_000) < 1)
    try rig.run(2048)
    #expect(abs((rig.dj.loopClock(for: nil).bpm ?? 0) - 126) < 0.05, "and after it")
  }

  @Test func theSoundActionsRoundTrip() {
    for a in [
      DeckAction.clipMute(id: "abc", on: true), .clipMute(id: "abc", on: false),
      .clipSolo(id: "abc", on: true), .clipKeyLock(id: "abc", on: true),
      .loopKeyLock(on: true), .loopKeyLock(on: false),
    ] + LoopFade.allCases.map({ DeckAction.loopFade(mode: $0.rawValue) }) {
      #expect(DeckAction(json: a.json) == a, "\(a)")
    }
    #expect(LoopFade.allCases.map(\.label) == ["off", "10 ms", "1 beat", "1 bar"])
  }
}
