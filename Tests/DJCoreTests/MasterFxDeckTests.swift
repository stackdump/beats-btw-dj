import Testing

@testable import DJCore

// The master chain on a deck: macros fired through the command ring, run on the deck's transport
// clock, the chain after the net and its samplers; and sessions with FX macros replay to the byte.

private let rate = 22_050.0

private func project(_ genre: String, _ seed: Double, _ structure: String) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

private func source(_ p: Project, tempo: Double? = nil) -> WaveDeckSource {
  let src = WaveDeckSource(sampleRate: rate)
  src.load(WaveRunner.prepare(p, sampleRate: rate))
  if let tempo { src.setTempo(tempo) }
  src.play()
  return src
}

/// `blocks` stereo blocks of 128; `at(b)` runs before block `b` (the main thread's sends).
private func render(
  _ src: WaveDeckSource, blocks: Int, _ at: (Int) -> Void = { _ in }
) -> (l: [Float], r: [Float]) {
  var outL: [Float] = []
  var outR: [Float] = []
  var l = [Float](repeating: 0, count: 128)
  var r = [Float](repeating: 0, count: 128)
  for b in 0..<blocks {
    at(b)
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        src.render(frames: 128, left: lp.baseAddress!, right: rp.baseAddress!)
      }
    }
    outL += l
    outR += r
  }
  return (outL, outR)
}

// A sample deck A at 48 kHz playing `buffer` as a loop from frame 0 at full speed, its grid at
// `bpm` (offset 0), on an engine that is never started: the test pulls `renderBlock` itself.
private let sampleRate48 = 48_000.0
private let bar120 = 96_000  // one bar at 120 bpm, 48 kHz

private func sampleDeck(_ buffer: SampleBuffer, bpm: Double = 120) throws -> (DJEngine, Deck) {
  let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: sampleRate48)
  dj.deterministic = true
  let d = try #require(dj["A"])
  d.load(buffer, title: "tones", level: false)
  d.setBeatGrid(BeatGrid(bpm: bpm, offset: 0, confidence: 1))
  d.setLoop(0, Double(buffer.length))
  d.launch()
  return (dj, d)
}

/// `frames` (a multiple of 512) of `deck`, both channels; `at(f)` runs before the block at
/// frame `f` (the main thread's pokes).
private func render(
  _ deck: Deck, frames: Int, _ at: (Int) -> Void = { _ in }
) -> (l: [Float], r: [Float]) {
  var outL: [Float] = []
  var outR: [Float] = []
  var l = [Float](repeating: 0, count: 512)
  var r = [Float](repeating: 0, count: 512)
  var f = 0
  while f < frames {
    at(f)
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        deck.renderBlock(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!)
      }
    }
    outL += l
    outR += r
    f += 512
  }
  return (outL, outR)
}

/// A low (375 Hz) and a bright (6 kHz) sine together, 2 s of whole periods.
private func twoTones() -> SampleBuffer {
  let lo = fxSineBuffer(hz: 375, amplitude: 0.2, seconds: 2)
  let hi = fxSineBuffer(hz: 6000, amplitude: 0.2, seconds: 2)
  let mix = (0..<lo.length).map { lo.left[$0] + hi.left[$0] }
  return SampleBuffer(left: mix, right: mix, sampleRate: sampleRate48)
}

struct MasterFxDeckTests {
  @Test func aMacroChangesTheSoundAndTheChainReturnsToTransparent() {
    let p = project("techno", 42, "loop")
    // 1 bar at 300 BPM = 0.8 s: sweep-lp is over by ~0.8 s, its last ramp 100 ms later
    let dry = render(source(p, tempo: 300), blocks: 400)
    let wetSrc = source(p, tempo: 300)
    let wet = render(wetSrc, blocks: 400) { b in
      if b == 10 { wetSrc.fire(.sweepLp, bars: 1) }
      if b == 20 { #expect(wetSrc.activeMasterMacros == [.sweepLp]) }
    }
    #expect(wet.l[..<(10 * 128)] == dry.l[..<(10 * 128)], "nothing before the fire")
    #expect(wet.l[(40 * 128)..<(100 * 128)] != dry.l[(40 * 128)..<(100 * 128)], "the LP sweep")
    #expect(wetSrc.activeMasterMacros.isEmpty)
    #expect(wetSrc.masterFilterCorners.bypassed)
    // 0.8 s + 0.1 s ramp + 5 ms fade ≈ block 167 at 22.05 kHz; well after that, the same bytes
    #expect(wet.l[(200 * 128)...] == dry.l[(200 * 128)...])
    #expect(wet.r[(200 * 128)...] == dry.r[(200 * 128)...])
  }

  @Test func fxMacrosRenderTheSameBytesTwice() {
    func once() -> (l: [Float], r: [Float]) {
      let src = source(project("dnb", 3, "minimal"), tempo: 174)
      return render(src, blocks: 900) { b in
        switch b {
        case 5: src.fire(.buildCrush, bars: 1)
        case 30: src.fire(.phaserDrone)
        case 60: src.fire(.octaveUp, bars: 1)
        case 70: src.fire(.riser, bars: 2)
        case 200: src.fire(.vinylBrake)
        case 260: src.fire(.feelBuild, bars: 2)
        case 300: src.panic()
        case 320: src.fire(.filterRes, bars: 0)
        case 400: src.setMasterFx(.lpFreq, 100)
        case 420: src.fire(.feelDrive, bars: 1)
        default: break
        }
      }
    }
    let a = once()
    let b = once()
    #expect(a.l == b.l && a.r == b.r)
    #expect(a.l.allSatisfy { $0.isFinite })
  }

  @Test func feelMovesTheTempoAndPutsItBack() {
    let p = project("techno", 42, "loop")
    let src = source(p)
    let genre = p.tempo
    // a 1-bar snap to Chill: tempo = round(genre BPM × 0.6), restored at the end
    _ = render(src, blocks: 5) { b in if b == 1 { src.fire(.feelChill, bars: 1) } }
    #expect(src.tempo == jsRound(genre * 0.6))
    #expect(src.isActive(.feelChill))
    _ = render(src, blocks: Int(rate * 60 / jsRound(genre * 0.6) * 4 / 128) + 20)
    #expect(src.tempo == genre)
    #expect(!src.isActive(.feelChill))
  }

  @Test func panicPutsTheSlidersBackAndStopRestoresToo() {
    let p = project("techno", 42, "loop")
    let src = source(p, tempo: 120)
    _ = render(src, blocks: 200) { b in
      if b == 1 { src.fire(.sweepHp, bars: 4) }
      if b == 150 { src.panic() }
    }
    #expect(src.activeMasterMacros.isEmpty)
    _ = render(src, blocks: 40)
    #expect(src.masterFilterCorners.hp == 20)
    #expect(src.masterFilterCorners.bypassed)
    _ = render(src, blocks: 20) { b in if b == 1 { src.fire(.octaveDown, bars: 4) } }
    #expect(src.isActive(.octaveDown))
    src.stop()
    _ = render(src, blocks: 2)
    #expect(src.activeMasterMacros.isEmpty)
  }

  @Test func theTransportClockStopsWhilePaused() {
    let src = source(project("techno", 42, "loop"), tempo: 300)
    _ = render(src, blocks: 4) { b in if b == 1 { src.fire(.sweepLp, bars: 1) } }
    src.pause()
    // 3 s paused: the macro (0.8 s) is still in effect
    _ = render(src, blocks: Int(3 * rate / 128))
    #expect(src.isActive(.sweepLp))
    src.play()
    _ = render(src, blocks: Int(1 * rate / 128))
    #expect(!src.isActive(.sweepLp))
  }

  // MARK: sample decks (DeckRenderer.master)

  @Test func aSampleDeckWithoutMacrosIsBitIdentical() throws {
    let b = twoTones()
    let (_, deck) = try sampleDeck(b)
    let out = render(deck, frames: 2 * bar120)
    // the bare turntable, as the deck played it before it had a master bus
    let tt = Turntable(sampleRate: sampleRate48)
    tt.load(b)
    tt.send(.gain(1, now: true))
    tt.send(.loop(start: 0, end: Double(b.length)))
    tt.send(.start)
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    var refL: [Float] = []
    var refR: [Float] = []
    for _ in 0..<(2 * bar120 / 512) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          tt.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!)
        }
      }
      refL += l
      refR += r
    }
    #expect(out.l == refL && out.r == refR)
    let bus = try #require(deck.renderer.master)
    #expect(bus.filterCorners.bypassed && deck.activeMasterMacros.isEmpty)
  }

  @Test func aSampleDeckSweepsItsLowpass() throws {
    let (_, dryDeck) = try sampleDeck(twoTones())
    let dry = render(dryDeck, frames: 4 * bar120)
    let (_, deck) = try sampleDeck(twoTones())
    var fire = -1
    let wet = render(deck, frames: 4 * bar120) { f in
      if f == 512 {
        // fired after the first block (the turntable has its sample): it waits for the deck's
        // next downbeat, bar 2
        fire = deck.sampleMasterFire().frame
        deck.fire(.sweepLp, duration: 1)
      }
      if f == bar120 / 2 { #expect(deck.activeMasterMacros == [.sweepLp], "waiting counts") }
    }
    #expect(abs(fire - bar120) <= 1, "\(fire)")
    #expect(wet.l[..<fire] == dry.l[..<fire], "nothing before its bar")
    // 0.8 s into the bar, the LP is half way down; 4608 frames = whole periods of both tones
    let w = (fire + 38_000)..<(fire + 38_000 + 4608)
    let hf = dB(toneAmplitude(Array(wet.l[w]), hz: 6000) / toneAmplitude(Array(dry.l[w]), hz: 6000))
    let lf = dB(toneAmplitude(Array(wet.l[w]), hz: 375) / toneAmplitude(Array(dry.l[w]), hz: 375))
    #expect(hf < -20, "the 6 kHz tone is swept out: \(hf) dB")
    #expect(hf < lf - 15, "far more than the 375 Hz one (\(lf) dB)")
    // a bar and a bit later, all of it is back, and the bytes are the turntable's again
    let after = (fire + bar120 + 24_000)..<(fire + bar120 + 24_000 + 4608)
    let back = toneAmplitude(Array(wet.l[after]), hz: 6000)
    #expect(abs(dB(back / toneAmplitude(Array(dry.l[after]), hz: 6000))) < 0.1)
    #expect(wet.l[(fire + 2 * bar120)...] == dry.l[(fire + 2 * bar120)...])
    #expect(wet.r[(fire + 2 * bar120)...] == dry.r[(fire + 2 * bar120)...])
    #expect(deck.activeMasterMacros.isEmpty)
    #expect(deck.renderer.master?.filterCorners.bypassed == true)
  }

  @Test func octaveUpShiftsASampleDeck() throws {
    // 220 whole periods a second: a seamless loop
    let (_, deck) = try sampleDeck(fxSineBuffer(hz: 220, amplitude: 0.3, seconds: 1))
    let out = render(deck, frames: 3 * bar120) { f in
      if f == 512 { deck.fire(.octaveUp, duration: 2) }  // lands on bar 2
    }
    let before = fundamental(out.l[20_000..<(20_000 + 8192)], sampleRate: sampleRate48)
    #expect(abs(cents(before, 220)) < 10, "dry: \(before) Hz")
    let w = (bar120 + 24_000)..<(bar120 + 24_000 + 8192)
    let up = fundamental(out.l[w], sampleRate: sampleRate48)
    #expect(abs(cents(up, 220) - 1200) < 10, "an octave up: \(cents(up, 220)) cents")
    #expect(deck.isMasterActive(.octaveUp))
  }

  @Test func theVinylBrakeIsANoOpOnASampleDeck() throws {
    let (_, dryDeck) = try sampleDeck(twoTones())
    let dry = render(dryDeck, frames: bar120)
    let (_, deck) = try sampleDeck(twoTones())
    let wet = render(deck, frames: bar120) { f in
      if f == 0 { deck.fire(.vinylBrake, duration: 1) }
    }
    #expect(wet.l == dry.l && wet.r == dry.r)
    #expect(deck.activeMasterMacros.isEmpty)
  }

  @Test func aSampleDeckSliderAndPanicReachItsBus() throws {
    let (_, deck) = try sampleDeck(twoTones())
    _ = render(deck, frames: 8 * 512) { f in
      if f == 0 {
        deck.fire(.sweepHp, duration: 4)
        deck.setMasterFx(.lpFreq, 40)
      }
    }
    let bus = try #require(deck.renderer.master)
    #expect(bus.sliderSet[.lpFreq] == 40)
    #expect(deck.isMasterActive(.sweepHp))
    deck.panic()
    _ = render(deck, frames: 512)
    #expect(deck.activeMasterMacros.isEmpty)
  }

  @Test func deckFiresEitherCatalogByID() {
    #expect(
      Deck.isMacro(id: "drop") && Deck.isMacro(id: "sweep-lp") && Deck.isMacro(id: "feel-reset"))
    #expect(!Deck.isMacro(id: "delay-throw"), "not ported: no delay on wave audio")
    #expect(!Deck.isMacro(id: "ping-pong") && !Deck.isMacro(id: "tighten"))
  }
}

struct MasterFxScopeTests {
  /// The scope model sees a net deck's master HP / LP (scope-model.js `fxResponse` reads
  /// `_hpFilter` / `_lpFilter`), and nothing of the chain at rest.
  @Test func theModelSeesTheChainsFilters() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    dj.deterministic = true
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "minimal"), sampleRate: rate))
    try dj.start()
    defer { dj.stop() }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    _ = try conductor.step { dj.perform(.play(deck: "A", on: true)) }
    #expect(DeckFx.chainPasses(deck: dj["A"]!).hp == nil)
    _ = try conductor.step { dj.perform(.macro(deck: "A", id: "sweep-hp")) }
    for _ in 0..<200 { _ = try conductor.step {} }
    let passes = DeckFx.chainPasses(deck: dj["A"]!)
    let hp = try #require(passes.hp)
    #expect(hp.fc > 25 && hp.stages == 4 && hp.qDb == 1)
    #expect(passes.lp?.fc == 20000)
    let fx = DeckFx(deck: dj["A"]!, gain: 1)
    #expect(fx.chainHighPass == hp)
    // a high-pass well above 25 Hz takes the bottom rows down
    let rows = ModelFx.response(fx, sampleRate: rate)
    #expect(rows[0] < 0.5)
  }
}

struct MasterFxSessionTests {
  private static func perform(blocks: Int) throws -> (Session, RenderedAudio) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: rate))
    dj["B"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "house", seed: 9, structure: "minimal"), sampleRate: rate))
    try dj.start()
    defer { dj.stop() }
    let router = ControllerRouter(engine: dj)
    let recorder = try SessionRecorder.start(on: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    var l: [Float] = []
    var r: [Float] = []
    for b in 0..<blocks {
      let (bl, br) = try conductor.step {
        switch b {
        case 0:
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        case 10: dj.perform(.macro(deck: "A", id: "sweep-lp"))
        case 40: dj.perform(.macro(deck: "B", id: "octave-up"))
        case 90: dj.perform(.macro(deck: "A", id: "feel-build"))
        case 130: dj.perform(.macro(deck: "B", id: "build-crush"))
        case 170: dj.perform(.macro(deck: "B", id: "phaser-drone"))
        case 220: dj.perform(.panic(deck: "A"))
        case 260: dj.perform(.macro(deck: "A", id: "drop"))
        default: break
        }
      }
      l += bl
      r += br
    }
    return (recorder.finish(), RenderedAudio(sampleRate: rate, left: l, right: r))
  }

  /// A sample deck (the demo loop) with master macros: they record as the decks' own actions
  /// and replay to the byte.
  @Test func aSampleDeckSetWithMasterMacrosReplaysToTheByte() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    dj["B"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "house", seed: 9, structure: "minimal"), sampleRate: rate))
    try dj.start()
    let router = ControllerRouter(engine: dj)
    let recorder = try SessionRecorder.start(on: dj)
    let conductor = OfflineConductor(engine: dj, router: router)
    var l: [Float] = []
    var r: [Float] = []
    for b in 0..<600 {
      let (bl, br) = try conductor.step {
        switch b {
        case 0:
          dj.perform(.play(deck: "A", on: true))
          dj.perform(.play(deck: "B", on: true))
        case 10: dj.perform(.macro(deck: "A", id: "sweep-lp"))
        case 60: dj.perform(.macro(deck: "A", id: "octave-up"))
        case 200: dj.perform(.macro(deck: "A", id: "feel-build"))
        case 330: dj.perform(.panic(deck: "A"))
        case 360: dj.perform(.macro(deck: "A", id: "build-crush"))
        default: break
        }
      }
      l += bl
      r += br
    }
    dj.stop()
    let session = recorder.finish()
    #expect(session.events.contains { $0.kind == .action(.macro(deck: "A", id: "sweep-lp")) })
    let a = try SessionPlayer(session: session).render()
    #expect(a.left == l && a.right == r, "the replay is the live set")
  }

  @Test func aSetWithFXMacrosReplaysToTheByte() throws {
    let (session, live) = try Self.perform(blocks: 360)
    #expect(session.events.contains { $0.kind == .action(.macro(deck: "A", id: "sweep-lp")) })
    let a = try SessionPlayer(session: session).render()
    let b = try SessionPlayer(session: session).render()
    #expect(a.left == live.left && a.right == live.right, "the replay is the live set")
    #expect(a.left == b.left && a.right == b.right, "two renders, same bytes")
  }
}
