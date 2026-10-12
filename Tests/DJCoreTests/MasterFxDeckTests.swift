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

  @Test func aSetWithFXMacrosReplaysToTheByte() throws {
    let (session, live) = try Self.perform(blocks: 360)
    #expect(session.events.contains { $0.kind == .action(.macro(deck: "A", id: "sweep-lp")) })
    let a = try SessionPlayer(session: session).render()
    let b = try SessionPlayer(session: session).render()
    #expect(a.left == live.left && a.right == live.right, "the replay is the live set")
    #expect(a.left == b.left && a.right == b.right, "two renders, same bytes")
  }
}
