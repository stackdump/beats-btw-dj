import Testing

@testable import DJCore

// The loops' master FX (LoopMasterBus.swift, LoopMasterFx.swift): the decks' master chain and
// macros on the loop channel "L", after the voices are summed and before the limiter, clocked by
// the loops' bar grid. Off is exact; a sweep is a loop bar long and lands on the loops' bar line;
// vinyl brake slows every loop and drops them back in time; panic restores; the limiter still
// holds; A / B and L stay apart unless linked; the APC aims at L; sets replay to the byte.

private let sr = 48_000.0
private let bar120 = 96_000  // one bar at 120 bpm, 48 kHz

/// Two sines a loop: a low one (375 Hz) and a bright one (6 kHz), whole periods.
private func twoTones() -> [SampleBuffer] {
  [fxSineBuffer(hz: 375, amplitude: 0.2), fxSineBuffer(hz: 6000, amplitude: 0.2)]
}

private func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }

struct LoopMasterBusTests {
  // MARK: off is exact

  @Test func atRestAndAfterAMacroTheBusIsBitIdentical() {
    let dry = FxBankRig(twoTones()).render(4 * bar120 / 2)
    let rig = FxBankRig(twoTones())
    rig.bank.master.fire(.sweepLp, bars: 1, frame: 0, bpm: 240)  // one bar = 1 s
    let wet = rig.render(4 * bar120 / 2)
    #expect(
      sameSamples(wet.left[24_000..<48_000], dry.left[24_000..<48_000]) != .identical,
      "the sweep is heard")
    // 1 s, then the filter's last ramp: well after, the same bytes again
    let from = 96_000
    #expect(sameSamples(Array(wet.left[from...]), Array(dry.left[from...])) == .identical)
    #expect(sameSamples(Array(wet.right[from...]), Array(dry.right[from...])) == .identical)
    #expect(rig.bank.master.filterCorners.bypassed && rig.bank.master.activeMasterMacros.isEmpty)
    #expect(rig.bank.limiter.idle)
  }

  // MARK: what a sweep does to the loops

  @Test func anLPSweepTakesTheTopOffTheLoopsOverItsBar() {
    let dry = FxBankRig(twoTones()).render(2 * bar120)
    let rig = FxBankRig(twoTones())
    rig.bank.master.fire(.sweepLp, bars: 1, frame: 0, bpm: 120)
    let wet = rig.render(2 * bar120)
    // 0.8 s in, the LP is half way down (slider ~50: ~1.5 kHz); 4608 frames = whole periods
    let w = 38_000..<(38_000 + 4608)
    let hfDry = toneAmplitude(Array(dry.left[w]), hz: 6000)
    let hfWet = toneAmplitude(Array(wet.left[w]), hz: 6000)
    let lfDry = toneAmplitude(Array(dry.left[w]), hz: 375)
    let lfWet = toneAmplitude(Array(wet.left[w]), hz: 375)
    #expect(dB(hfWet / hfDry) < -30, "the 6 kHz tone is swept out: \(dB(hfWet / hfDry)) dB")
    #expect(dB(hfWet / hfDry) < dB(lfWet / lfDry) - 15, "far more than the 375 Hz one")
    // a bar and a bit later, all of it is back
    let after = (bar120 + 24_000)..<(bar120 + 24_000 + 4608)
    let hfBack = toneAmplitude(Array(wet.left[after]), hz: 6000)
    #expect(abs(dB(hfBack / hfDry)) < 0.1)
  }

  // MARK: timing

  @Test func aOneBarSweepSpansExactlyOneLoopBar() {
    let rig = FxBankRig(twoTones())
    let fire = 10_000  // inside a block
    rig.bank.master.fire(.sweepLp, bars: 1, frame: fire, bpm: 120)
    var lastActiveEnd = 0
    var firstInactiveEnd = 0
    while rig.frame < 3 * bar120 {
      rig.skip(512)
      let on = rig.bank.master.isActive(.sweepLp)
      if on {
        lastActiveEnd = rig.frame
      } else if firstInactiveEnd == 0 {
        firstInactiveEnd = rig.frame
      }
    }
    // running through every block that ends by fire + 1 bar, done in the block holding its end
    #expect(lastActiveEnd <= fire + bar120 && lastActiveEnd > fire + bar120 - 512)
    #expect(firstInactiveEnd > fire + bar120 && firstInactiveEnd <= fire + bar120 + 512)
  }

  @Test func aFireLandsOnItsFrameInsideABlock() {
    let dry = FxBankRig(twoTones()).render(bar120)
    let rig = FxBankRig(twoTones())
    let fire = 10_000
    rig.bank.master.fire(.vinylBrake, bars: 1, frame: fire, bpm: 120)
    let wet = rig.render(bar120)
    #expect(
      sameSamples(wet.left[..<fire], dry.left[..<fire]) == .identical, "nothing before its frame")
    #expect(
      sameSamples(wet.left[fire..<(fire + 256)], dry.left[fire..<(fire + 256)]) != .identical,
      "the brake from it")
  }

  // MARK: vinyl brake

  @Test func vinylBrakeSlowsEveryLoopAndDropsThemBackInTime() {
    let dry = FxBankRig(twoTones()).render(3 * bar120)
    let rig = FxBankRig(twoTones())
    let fire = 4096
    rig.bank.master.fire(.vinylBrake, bars: 1, frame: fire, bpm: 120)
    var mid: Bool?
    var out: [Float] = []
    while out.count < 3 * bar120 {
      out += rig.render(512).left
      if mid == nil, rig.frame >= fire + bar120 / 2 { mid = rig.bank.master.isActive(.vinylBrake) }
    }
    #expect(mid == true, "the brake shows while it runs")
    // spinning down: the bright tone falls in pitch (fewer crossings in a window than dry)
    func crossings(_ x: ArraySlice<Float>) -> Int {
      zip(x.dropFirst(), x).filter { ($0 >= 0) != ($1 >= 0) }.count
    }
    let w = (fire + bar120 / 2)..<(fire + bar120 / 2 + 4800)
    #expect(Double(crossings(out[w])) < 0.6 * Double(crossings(dry.left[w])))
    // stopped for its last quarter
    let stop = (fire + bar120 * 77 / 100)..<(fire + bar120 * 99 / 100)
    #expect(peak(Array(out[stop])) < 1e-4)
    // released at fire + 1 bar over 5 ms: every loop where it would have been, to the byte
    let back = fire + bar120 + 480
    #expect(sameSamples(Array(out[back..<dry.left.count]), Array(dry.left[back...])) == .identical)
    #expect(!rig.bank.master.isActive(.vinylBrake))
  }

  // MARK: panic

  @Test func panicRestoresTheLoopsAtOnce() {
    let dry = FxBankRig(twoTones()).render(3 * bar120)
    let rig = FxBankRig(twoTones())
    rig.bank.master.fire(.sweepLp, bars: 4, frame: 0, bpm: 120)
    rig.bank.master.fire(.octaveUp, bars: 4, frame: 0, bpm: 120)
    rig.skip(bar120)
    #expect(rig.bank.master.isActive(.sweepLp) && rig.bank.master.isActive(.octaveUp))
    rig.bank.master.panic()
    rig.skip(512)
    #expect(rig.bank.master.activeMasterMacros.isEmpty)
    let start = rig.frame
    let rest = rig.render(3 * bar120 - start)
    // the LP's jump back and the pitch shifter's fade out, then the dry loops again
    let from = bar120 / 2
    #expect(
      sameSamples(Array(rest.left[from...]), Array(dry.left[(start + from)...])) == .identical)
  }

  @Test func panicReleasesABrakeInTime() {
    let dry = FxBankRig(twoTones()).render(2 * bar120)
    let rig = FxBankRig(twoTones())
    rig.bank.master.fire(.vinylBrake, bars: 2, frame: 0, bpm: 120)
    rig.skip(bar120 / 2)
    rig.bank.master.panic()
    let rest = rig.render(2 * bar120 - rig.frame)
    let start = bar120 / 2
    #expect(
      sameSamples(Array(rest.left[1024...]), Array(dry.left[(start + 1024)...])) == .identical,
      "back in time")
  }

  // MARK: the limiter stays last

  @Test func theLimiterStillBoundsThePeaksAfterTheChain() {
    // loud loops (just under full scale together), pitched up and distorted on the bus
    let clips = (0..<6).map { fxSineBuffer(hz: 375 + 125 * Double($0), amplitude: 0.155) }
    let rig = FxBankRig(clips)
    let bus = rig.bank.master
    bus.setSlider(.distortion, 100)
    bus.setSlider(.crushBits, 60)
    bus.fire(.octaveUp, bars: 2, frame: 0, bpm: 120)
    let out = rig.render(2 * bar120)
    let p = max(peak(out.left), peak(out.right))
    #expect(p <= LoopFxLimiter.ceiling + 1e-6, "\(p)")
    #expect(p > 0.8, "and it is loud: \(p)")
    #expect(out.left.allSatisfy { $0.isFinite })
  }
}

// MARK: - the engine: L as a target

@MainActor
struct LoopMasterEngineTests {
  /// Deck A plays the demo loop (120 bpm, 48 kHz) and a one-bar clip loops on L.
  func engine() throws -> (DJEngine, LoopClip) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    let c = fxTestClip(1)
    dj.restoreClips([c])
    try dj.start()
    _ = try renderOffline(dj, frames: 8192)
    dj.setLooping(c.id, true)
    _ = try renderOffline(dj, frames: bar120 + 4096)
    dj.serviceLoopTakes()
    return (dj, c)
  }

  func run(_ dj: DJEngine, until frame: Int) throws {
    while dj.loopChannel.renderedFrames < frame {
      _ = try renderOffline(dj, frames: 512)
      dj.serviceLoopTakes()
    }
  }

  @Test func aMacroOnLLandsOnTheLoopsNextBarAndLastsItsBarsOfTheirTempo() throws {
    let (dj, c) = try engine()
    defer { dj.stop() }
    #expect(dj.loopState(c.id) == .on)
    let bus = try #require(dj.loopMaster)
    let at = dj.loopMasterFireFrame()
    let clock = dj.loopClock(for: nil)
    let beat = clock.beat(at)
    #expect(abs(beat / 4 - (beat / 4).rounded()) < 1e-3, "on a bar line: beat \(beat)")
    let now = dj.loopChannel.renderedFrames
    #expect(at > now && at <= now + bar120 + 4096)
    dj.perform(.macro(deck: "L", id: "sweep-lp"))
    #expect(bus.isActive(.sweepLp), "shows at once (waiting for its bar)")
    try run(dj, until: at - 1024)
    #expect(bus.filterCorners.bypassed, "not before its bar")
    try run(dj, until: at + bar120 / 2)
    #expect(bus.isActive(.sweepLp) && !bus.filterCorners.bypassed)
    #expect(bus.filterCorners.lp < 20_000)
    // its default length, 4 bars, of the loops' tempo
    try run(dj, until: at + 4 * bar120 - 1024)
    #expect(bus.isActive(.sweepLp))
    try run(dj, until: at + 4 * bar120 + 1024)
    #expect(!bus.isActive(.sweepLp), "over after four loop bars")
    // a 1-bar one: exactly one loop bar, from the next bar line
    let at1 = dj.loopMasterFireFrame()
    dj.fireLoopMaster(.sweepLp, bars: 1)
    try run(dj, until: at1 + bar120 - 1024)
    #expect(bus.isActive(.sweepLp))
    try run(dj, until: at1 + bar120 + 1024)
    #expect(!bus.isActive(.sweepLp), "over after one loop bar")
    // the decks never saw it
    #expect(dj["A"]!.wave.activeMasterMacros.isEmpty && dj["B"]!.wave.activeMasterMacros.isEmpty)
  }

  @Test func netMacrosDoNothingOnLAndPanicRestores() throws {
    let (dj, _) = try engine()
    defer { dj.stop() }
    let bus = try #require(dj.loopMaster)
    dj.perform(.macro(deck: "L", id: "drop"))
    dj.perform(.macro(deck: "L", id: "breakdown"))
    #expect(bus.activeMasterMacros.isEmpty)
    dj.perform(.macro(deck: "L", id: "riser"))
    dj.perform(.macro(deck: "L", id: "build-crush"))
    try run(dj, until: dj.loopChannel.renderedFrames + bar120 + 8192)
    #expect(Set(bus.activeMasterMacros) == [.riser, .buildCrush])
    dj.perform(.panic(deck: "L"))
    try run(dj, until: dj.loopChannel.renderedFrames + 2048)
    #expect(bus.activeMasterMacros.isEmpty)
    try run(dj, until: dj.loopChannel.renderedFrames + 24_000)
    #expect(bus.filterCorners.bypassed)
  }

  @Test func deckMacrosLeaveTheLoopsAloneUnlessLinked() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let a = dj["A"]!
    await a.generate(TrackSpec(genre: "techno", seed: 42, structure: nil))
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let bus = try #require(dj.loopMaster)
    _ = try renderOffline(dj, frames: 4096)
    dj.perform(.macro(deck: "A", id: "sweep-hp"))
    _ = try renderOffline(dj, frames: 4096)
    #expect(a.wave.activeMasterMacros == [.sweepHp])
    #expect(bus.activeMasterMacros.isEmpty, "not linked: the loops keep theirs")
    dj.perform(.loopFxLink(on: true))
    #expect(dj.loopFxLink && dj.loopSettings.contains(.loopFxLink(on: true)))
    dj.perform(.macro(deck: "A", id: "octave-down"))
    _ = try renderOffline(dj, frames: 4096)
    #expect(bus.activeMasterMacros == [.octaveDown], "linked: the loops take it at once")
    #expect(a.wave.activeMasterMacros.contains(.octaveDown))
    dj.perform(.panic(deck: "A"))
    _ = try renderOffline(dj, frames: 4096)
    #expect(bus.activeMasterMacros.isEmpty, "and the deck's panic releases them")
    // L's own fire never reaches the deck
    dj.perform(.loopFxLink(on: false))
    dj.perform(.macro(deck: "L", id: "phaser-drone"))
    _ = try renderOffline(dj, frames: 4096)
    #expect(!a.wave.activeMasterMacros.contains(.phaserDrone))
    #expect(bus.isActive(.phaserDrone))
  }

  // MARK: the APC aims at the loops

  @Test func theApcAimsAtTheLoopsAndItsFadersAndPadsActOnThem() throws {
    let (dj, _) = try engine()
    defer { dj.stop() }
    let s = SurfaceController(profile: .apcMiniMK2, engine: dj)
    let bus = try #require(dj.loopMaster)
    s.handle(bytes: [0x90, 0x7A, 0x7F])  // SHIFT
    s.handle(bytes: [0x90, 0x73, 0x7F])  // + aim A: aim at the loops
    s.handle(bytes: [0x80, 0x73, 0x00])
    s.handle(bytes: [0x80, 0x7A, 0x00])
    #expect(dj.focus == "L")
    // LEDs: the deck aim buttons blink; SHIFT shows the loops' aim lit
    let frame = s.ledFrame()
    #expect(frame.contains([0x90, 0x73, 2]) && frame.contains([0x90, 0x74, 2]))
    #expect(s.lights(shift: true)["scene"]?[3].level == .full)
    // a fader is the loops' FX unit, not deck A's
    s.handle(bytes: [0xB0, 0x32, 0])  // fader 3: LP closed
    #expect(dj.loopChannel.fxUnit[.lp] == 0 && dj["A"]!.fxUnit[.lp] == 1)
    // a master macro pad fires on the loops; a net macro pad is dark and does nothing
    s.handle(bytes: [0x90, 8, 0x7F])  // sweep-lp
    #expect(bus.isActive(.sweepLp))
    s.handle(bytes: [0x90, 0, 0x7F])  // drop
    // past the presses' flash (`flashSeconds`, on the uptime clock): 1e6 s was before the
    // presses once the Mac had been up 11.6 days, so every pressed pad still read flashed
    let later = 1e12
    let lit = s.ledFrame(now: later)
    #expect(lit.contains([0x96, 8, 37]), "sweep-lp bright cyan while it runs on the loops")
    let pads = s.lights(now: later)["pads"]
    #expect(pads?[0] == PadLight(colorIndex: 0, level: .dim), "drop: dark on the loops")
    #expect(pads?[8] == PadLight(colorIndex: 37, level: .full))
    s.handle(bytes: [0x90, 0x77, 0x7F])  // panic
    #expect(bus.activeMasterMacros.isEmpty)
    // aim A again: the faders go back to the deck
    s.handle(bytes: [0x90, 0x73, 0x7F])
    #expect(dj.focus == "A")
    #expect(s.ledFrame().contains([0x90, 0x73, 1]))
  }

  // MARK: the pokes

  @Test func theLinkRoundTripsAndTheCheckpointKeepsIt() throws {
    let a = DeckAction.loopFxLink(on: true)
    #expect(DeckAction(json: a.json) == a)
    #expect(DeckAction(json: try JSONValue.parse(a.json.canonicalJS)) == a)
    let m = DeckAction.macro(deck: "L", id: "vinyl-brake")
    #expect(DeckAction(json: m.json) == m)
    #expect(SessionEvent(json: SessionEvent(frame: 3, kind: .action(a)).json)?.kind == .action(a))
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    #expect(!dj.loopFxLink && dj.loopSettings == DJEngine.defaultLoopSettings)
    dj.perform(a)
    let state = try #require(JournalState(json: JournalState(engine: dj).json))
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    state.restore(into: fresh) { _ in nil }
    #expect(fresh.loopFxLink)
  }

  @Test func aSetWithLoopMasterFxReplaysToTheByte() throws {
    func script(_ dj: DJEngine, _ bar: Int, _ b: Int) {
      switch b {
      case 4 * bar: dj.perform(.macro(deck: "L", id: "sweep-hp"))
      case 6 * bar + 11: dj.perform(.macro(deck: "L", id: "vinyl-brake"))
      case 8 * bar: dj.perform(.loopFxLink(on: true))
      case 8 * bar + 5: dj.perform(.macro(deck: "L", id: "octave-up"))
      case 8 * bar + 200: dj.perform(.panic(deck: "L"))
      case 9 * bar: dj.perform(.macro(deck: "L", id: "feel-drive"))
      default: break
      }
    }
    let blocks = 11 * 344
    let live = try loopMasterSet(blocks: blocks, script)
    let brake = DeckAction.macro(deck: "L", id: "vinyl-brake")
    #expect(live.session.events.contains { $0.kind == .action(brake) })
    let replay = try SessionPlayer(session: live.session).render()
    #expect(sameSamples(replay.left, live.audio.left) == .identical, "session replay")
    #expect(sameSamples(replay.right, live.audio.right) == .identical, "session replay")
    let j = try Journal.replay(live.journal, endFrame: blocks * 128, render: true)
    let audio = try #require(j.audio)
    let n = min(audio.frames, live.audio.frames)
    #expect(n > blocks * 128 - 1024)
    #expect(
      sameSamples(Array(audio.left.prefix(n)), Array(live.audio.left.prefix(n))) == .identical,
      "journal replay")
    // and the bus was heard: the same set without it differs
    let dry = try loopMasterSet(blocks: blocks) { _, _, _ in }
    #expect(sameSamples(dry.audio.left, live.audio.left) != .identical)
    let before = 4 * 344 * 128  // up to the first poke, the same
    #expect(
      sameSamples(Array(dry.audio.left.prefix(before)), Array(live.audio.left.prefix(before)))
        == .identical)
  }
}
