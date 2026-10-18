import Darwin
import Testing

@testable import DJCore

// Per-loop after effects (LoopFx.swift): off is exact, drive is the dB it says, every shaper
// adds harmonics and stays bounded, crush quantises to its bits, changes are smoothed, the loop
// channel's limiter holds the peak, and the poke records, saves and replays.
struct LoopFxTests {
  static let hz = 375.0  // 128 samples a period at 48 kHz

  // MARK: off is exact

  @Test func noFxIsBitIdenticalToNoChain() {
    let clips = [fxSineBuffer(), fxSineBuffer(hz: 500, amplitude: 0.3)]
    let plain = FxBankRig(clips).render(48_000)
    // the default value, and settings that are bypassed or do nothing, never enter the chain
    for fx in [
      LoopFX(), LoopFX(bypass: true, drive: 24, mode: .fold, amount: 1, tone: 0.2, trim: 6),
      LoopFX(mode: .soft, amount: 0), LoopFX(drive: 12, mix: 0),
    ] {
      #expect(!fx.isActive)
      let rig = FxBankRig(clips, fx: [fx, fx])
      let out = rig.render(48_000)
      #expect(out.left == plain.left && out.right == plain.right, "\(fx)")
    }
  }

  @Test func switchedOffItIsExactAgainAfterTheFade() {
    let clips = [fxSineBuffer()]
    let plain = FxBankRig(clips).render(48_000)
    let rig = FxBankRig(clips)
    rig.skip(4096)
    rig.set(0, LoopFX(drive: 6, mode: .soft, amount: 0.7))
    rig.skip(8192)
    rig.set(0, LoopFX())
    rig.skip(4096)  // the 10 ms fade out, and the limiter (never engaged) idle
    let after = rig.render(48_000 - rig.frame)
    #expect(Array(plain.left[16_384...]) == after.left)
    #expect(!rig.bank.fx[0].running)
  }

  // MARK: drive

  @Test func driveIsTheGainItSaysAndAutoLevelHoldsTheLevel() {
    let clip = fxSineBuffer(amplitude: 0.05)
    let dry = rms(FxBankRig([clip]).render(24_576).left)
    for drive in [6.0, 12.0, 24.0] {
      let loud = FxBankRig([clip], fx: [LoopFX(drive: drive, autoLevel: false)]).render(24_576)
      #expect(abs(dB(rms(loud.left) / dry) - drive) < 0.05, "+\(drive) dB")
      let level = FxBankRig([clip], fx: [LoopFX(drive: drive)]).render(24_576)
      #expect(abs(dB(rms(level.left) / dry)) < 1, "auto-level at +\(drive) dB")
    }
  }

  @Test func autoLevelKeepsADistortedLoopNearItsLevel() {
    let clip = fxSineBuffer(amplitude: 0.2)
    let dry = rms(FxBankRig([clip]).render(48_000).left)
    for mode in [LoopFXMode.soft, .hard, .tube, .fold] {
      let rig = FxBankRig([clip], fx: [LoopFX(drive: 12, mode: mode, amount: 0.8)])
      rig.skip(48_000)  // the followers settle (~0.3 s)
      let out = rig.render(24_576)
      #expect(abs(dB(rms(out.left) / dry)) < 1.5, "\(mode): \(dB(rms(out.left) / dry)) dB")
    }
  }

  // MARK: shapers

  @Test func everyShaperAddsHarmonicsAndIsBounded() {
    let clip = fxSineBuffer(amplitude: 0.25)
    let dry = FxBankRig([clip]).render(24_576)
    let clean = thd(Array(dry.left[4096...]), hz: Self.hz)
    #expect(clean < 1e-4, "the dry sine is clean: \(clean)")
    for mode in LoopFXMode.allCases where mode != .clean {
      for drive in [0.0, 24.0] {
        let fx = LoopFX(drive: drive, mode: mode, amount: 0.8, bits: 4)
        let out = FxBankRig([clip], fx: [fx]).render(24_576)
        let tail = Array(out.left[4096...])
        let d = thd(tail, hz: Self.hz)
        #expect(d > 0.02, "\(mode) +\(drive) dB adds harmonics: THD \(d)")
        let finite = out.left.allSatisfy { $0.isFinite } && out.right.allSatisfy { $0.isFinite }
        #expect(finite, "\(mode)")
        let peak = out.left.map(abs).max() ?? 0
        #expect(peak <= LoopFxLimiter.ceiling + 1e-6, "\(mode) +\(drive) dB peak \(peak)")
      }
    }
  }

  @Test func tubeIsAsymmetricAndTheOthersAreNot() {
    // even harmonics come from an asymmetric curve: tube's second harmonic, soft's none
    let clip = fxSineBuffer(amplitude: 0.25)
    func second(_ mode: LoopFXMode) -> Double {
      let out = FxBankRig([clip], fx: [LoopFX(drive: 6, mode: mode, amount: 0.7)]).render(24_576)
      let tail = Array(out.left[8192...])
      return toneAmplitude(tail, hz: 2 * Self.hz) / toneAmplitude(tail, hz: Self.hz)
    }
    #expect(second(.tube) > 0.01, "\(second(.tube))")
    #expect(second(.soft) < 1e-3, "\(second(.soft))")
    #expect(second(.hard) < 1e-3, "\(second(.hard))")
  }

  @Test func crushQuantisesToItsBitsAndHoldsItsSamples() {
    let clip = fxSineBuffer(amplitude: 0.4)
    for bits in [2.0, 4.0, 6.0] {
      let fx = LoopFX(mode: .crush, amount: 1, bits: bits, autoLevel: false)
      let out = FxBankRig([clip], fx: [fx]).render(8192)
      let step = Float(crushStep(bits: bits))
      #expect(
        out.left.allSatisfy { ($0 / step).rounded() * step == $0 },
        "every sample on the \(Int(bits))-bit grid")
      #expect(Set(out.left).count <= Int(2 * 0.4 / Double(step)) + 2, "and only those levels")
    }
    // ÷4: each value held for four samples, from the voice's first
    let held = FxBankRig(
      [clip], fx: [LoopFX(mode: .crush, amount: 1, bits: 12, downsample: 4, autoLevel: false)]
    ).render(8192).left
    let changes = (1..<held.count).filter { held[$0] != held[$0 - 1] }
    #expect(!changes.isEmpty && changes.allSatisfy { $0 % 4 == 0 }, "\(changes.prefix(8))")
  }

  // MARK: smoothing

  @Test func parameterChangesAreSmoothed() {
    // each change mid-loop: the samples while it moves never jump further from one to the next
    // than the steadier of the settings before and after it (an unsmoothed jump to +24 dB at a
    // peak of this sine would be ~0.75 in one sample)
    let clip = fxSineBuffer(amplitude: 0.05)
    let rig = FxBankRig([clip], fx: [LoopFX(autoLevel: false)])
    rig.skip(4096)
    var before = maxStep(rig.render(2048).left[...])
    for fx in [
      LoopFX(drive: 24, autoLevel: false), LoopFX(drive: 0, autoLevel: false),
      LoopFX(drive: 24, autoLevel: false),
      LoopFX(drive: 24, mode: .soft, amount: 0.3, autoLevel: false),
      LoopFX(drive: 24, mode: .fold, amount: 0.3, autoLevel: false),
      LoopFX(drive: 24, mode: .fold, amount: 0.3, tone: 0, autoLevel: false),
      LoopFX(drive: 24, mode: .fold, amount: 0.3, tone: 0, mix: 0.2, autoLevel: false),
      LoopFX(drive: 24, mode: .fold, amount: 0.3, tone: 0, mix: 0.2, trim: -12, autoLevel: false),
      LoopFX(),
    ] {
      rig.set(0, fx)
      let moving = maxStep(rig.render(4096).left[...])
      let after = maxStep(rig.render(2048).left[...])
      #expect(
        moving <= 1.1 * max(before, after) + 0.002,
        "\(fx.summary): \(moving) vs \(before) → \(after)")
      before = after
    }
  }

  // MARK: the loop channel's limiter

  @Test func theLimiterHoldsTheChannelUnderFullScale() {
    // six loops that sum under full scale dry, all pushed +24 dB
    let clips = (0..<6).map { fxSineBuffer(hz: 375 + 125 * Double($0), amplitude: 0.1) }
    let fx = LoopFX(drive: 24, autoLevel: false)
    let rig = FxBankRig(clips, fx: Array(repeating: fx, count: clips.count))
    let out = rig.render(96_000)
    let peak = max(out.left.map(abs).max() ?? 0, out.right.map(abs).max() ?? 0)
    #expect(peak <= LoopFxLimiter.ceiling + 1e-6 && peak < 1, "\(peak)")
    #expect(peak > 0.9, "and it is loud: \(peak)")
    #expect(out.left.allSatisfy { $0.isFinite })
    // once the FX are off and the gain has come back up, it lets go
    for v in clips.indices { rig.set(v, LoopFX()) }
    rig.skip(96_000)
    #expect(rig.bank.limiter.idle)
  }

  // MARK: the poke

  @Test func clipFxRoundTripsThroughItsCodec() throws {
    let fx = LoopFX(
      bypass: true, drive: 13.5, mode: .tube, amount: 0.33, bits: 5, downsample: 3, tone: 0.42,
      mix: 0.7, trim: -3.5, autoLevel: false)
    let a = DeckAction.clipFx(id: "abc", fx: fx)
    #expect(DeckAction(json: a.json) == a)
    let text = a.json.canonicalJS
    #expect(DeckAction(json: try JSONValue.parse(text)) == a)
    #expect(SessionEvent(json: SessionEvent(frame: 9, kind: .action(a)).json)?.kind == .action(a))
    // every preset too, and missing fields are the defaults, out of range is clamped
    for p in LoopFX.presets {
      let a = DeckAction.clipFx(id: "x", fx: p.fx)
      #expect(DeckAction(json: a.json) == a)
    }
    #expect(LoopFX(json: .object(JSONObject())) == LoopFX())
    let wild = LoopFX(
      json: try JSONValue.parse(#"{"drive":99,"bits":0,"downsample":100,"mode":"x"}"#))
    #expect(wild.drive == 24 && wild.bits == 1 && wild.downsample == 32 && wild.mode == .clean)
    #expect(DeckAction(json: try JSONValue.parse(#"{"op":"clipFx"}"#)) == nil, "needs an id")
    #expect(JournalEvent.action(a).foldKey == "fx.abc")
    #expect(a.clipIDs == ["abc"])
  }

  @Test @MainActor func thePokeSetsTheClipAndItsVoice() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = fxTestClip(1)
    dj.restoreClips([c])
    let warm = LoopFX.presets[1].fx
    dj.perform(.clipFx(id: c.id, fx: warm))
    #expect(dj.clipFx(c.id) == warm)
    #expect(dj.clip(c.id)?.fx == warm)
    // a crop keeps it; a new sequence starts off, an edited one keeps its own
    let cropped = try #require(dj.cropClip(c.id, from: 0, to: 2))
    #expect(dj.clipFx(cropped) == warm)
    let seq = try #require(dj.makeSequence([SequenceStep(clipID: cropped, repeats: 2)]))
    #expect(dj.clipFx(seq) == LoopFX())
    dj.setClipFx(seq, LoopFX.presets[3].fx)
    let edited = try #require(
      dj.makeSequence([SequenceStep(clipID: cropped, repeats: 3)], replacing: seq))
    #expect(dj.clipFx(edited) == LoopFX.presets[3].fx)
    // removed and put back, it still has it
    dj.removeClip(cropped)
    #expect(dj.clipFx(cropped) == warm)
    dj.restoreClip(cropped)
    #expect(dj.clipFx(cropped) == warm)
  }

  @Test func theLibraryKeepsAClipsFx() throws {
    let lib = LoopLibrary(dir: fxTempDir())
    defer { removeLoopLibrary(lib) }
    var a = fxTestClip(1)
    let b = fxTestClip(2)
    a.fx = LoopFX(drive: 9, mode: .hard, amount: 0.55, tone: 0.75)
    try lib.save([a, b])
    let back = lib.load(sampleRate: 48_000)
    #expect(back.map(\.fx) == [a.fx, LoopFX()])
    // taken off the row, its FX go with it into removed/
    try lib.save([b])
    #expect(lib.removedClip(a.id, sampleRate: 48_000)?.fx == a.fx)
  }

  @Test @MainActor func theJournalCheckpointKeepsAClipsFx() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let c = fxTestClip(1)
    dj.restoreClips([c])
    let fx = LoopFX(drive: 3, mode: .crush, amount: 1, bits: 5, downsample: 2)
    dj.setClipFx(c.id, fx)
    let state = JournalState(engine: dj)
    let back = try #require(JournalState(json: state.json))
    #expect(back.clips.first?.fx == fx)
    #expect(back == state)
    // restored over a library clip with other FX, the run's own win
    let fresh = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    var stale = c
    stale.fx = LoopFX.presets[5].fx
    back.restore(into: fresh) { $0 == c.id ? stale : nil }
    #expect(fresh.clipFx(c.id) == fx)
  }

  @Test func aSetWithFxChangesReplaysToTheByte() throws {
    let (session, live) = try loopFxSet(
      first: LoopFX.presets[2].fx, second: LoopFX(drive: 18, mode: .fold, amount: 0.6, tone: 0.5))
    let pokes = session.events.filter {
      if case .action(.clipFx) = $0.kind { return true }
      return false
    }
    #expect(pokes.count == 3, "on, changed, off: \(pokes.count)")
    let a = try SessionPlayer(session: session).render()
    #expect(a.left == live.left && a.right == live.right, "the replay is the live set")
    // and the FX were heard: the set differs from the same set with no FX at all
    let (_, dry) = try loopFxSet(first: LoopFX(), second: LoopFX())
    #expect(dry.left != live.left)
  }
}

// MARK: a clip on deck A / B

extension LoopFxTests {
  /// An engine (never started) with clip `c` on its row, moved onto deck A and playing there.
  @MainActor
  private func clipOnDeck(_ c: LoopClip) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj.restoreClips([c])
    dj.playClip(c.id, on: "A")
    let deck = try #require(dj["A"])
    #expect(deck.clipID == c.id)
    deck.launch()
    return (dj, deck)
  }

  /// The same clip's audio loaded on a deck as a plain looping sample: no FX ever.
  @MainActor
  private func plainDeck(_ c: LoopClip) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    let deck = try #require(dj["A"])
    deck.load(c.buffer, title: c.title, level: false)
    deck.setLoop(0, Double(c.buffer.length))
    deck.launch()
    return (dj, deck)
  }

  @Test @MainActor func aClipMovedOntoADeckKeepsItsFx() throws {
    let frames = 24_576
    for fx in [
      LoopFX.presets[1].fx, LoopFX.presets[3].fx, LoopFX.presets[4].fx,
      LoopFX(drive: 12, mode: .fold, amount: 0.7, tone: 0.5, mix: 0.6, trim: -3),
    ] {
      var c = fxTestClip(1)
      c.fx = fx
      let (_, deck) = try clipOnDeck(c)
      let onDeck = renderDeck(deck, frames)
      #expect(deck.renderer.fxRunning, "\(fx.summary)")
      let mixer = FxBankRig([c.buffer], fx: [fx]).render(frames)
      let dry = FxBankRig([c.buffer]).render(frames)
      let l = residualDB(onDeck.left, mixer.left)
      let r = residualDB(onDeck.right, mixer.right)
      #expect(l < -40 && r < -40, "\(fx.summary): deck vs mixer \(l) / \(r) dB")
      // and the FX are heard: it is not the dry clip
      #expect(residualDB(onDeck.left, dry.left) > -20, "\(fx.summary)")
    }
  }

  @Test @MainActor func aDryClipOnADeckIsBitIdentical() throws {
    let frames = 24_576
    for fx in [LoopFX(), LoopFX(bypass: true, drive: 24, mode: .hard, amount: 1)] {
      var c = fxTestClip(2)
      c.fx = fx
      let (_, deck) = try clipOnDeck(c)
      let (_, plain) = try plainDeck(c)
      let a = renderDeck(deck, frames)
      let b = renderDeck(plain, frames)
      #expect(a.left == b.left && a.right == b.right, "\(fx)")
      #expect(!deck.renderer.fxRunning)
    }
  }

  @Test @MainActor func changingTheClipsFxReachesTheDeckAndALoadDropsThem() throws {
    let c = fxTestClip(1)
    let (dj, deck) = try clipOnDeck(c)
    let (_, plain) = try plainDeck(c)
    _ = renderDeck(deck, 4096)
    _ = renderDeck(plain, 4096)
    #expect(!deck.renderer.fxRunning)
    dj.perform(.clipFx(id: c.id, fx: LoopFX.presets[2].fx))
    let wet = renderDeck(deck, 8192)
    let dry = renderDeck(plain, 8192)
    #expect(deck.renderer.fxRunning)
    #expect(residualDB(Array(wet.left[2048...]), Array(dry.left[2048...])) > -20)
    // off again: out over the fade, then the turntable's bytes
    dj.perform(.clipFx(id: c.id, fx: LoopFX()))
    _ = renderDeck(deck, 4096)
    _ = renderDeck(plain, 4096)
    #expect(!deck.renderer.fxRunning)
    // on, then anything else loaded on the deck plays dry
    dj.perform(.clipFx(id: c.id, fx: LoopFX.presets[3].fx))
    _ = renderDeck(deck, 4096)
    #expect(deck.renderer.fxRunning)
    deck.load(c.buffer, title: "plain", level: false)
    #expect(deck.clipID == nil)
    _ = renderDeck(deck, 512)
    #expect(!deck.renderer.fxRunning)
    // and a clip edit no longer reaches it
    dj.perform(.clipFx(id: c.id, fx: LoopFX.presets[1].fx))
    _ = renderDeck(deck, 512)
    #expect(!deck.renderer.fxRunning)
  }
}

/// `DJ_FX_WAV_DIR=… make swift-test-filter FILTER=LoopFxListening`: the demo loop dry and
/// through each preset, to listen to.
struct LoopFxListening {
  @Test func beforeAndAfter() {
    let paths = writeLoopFxWavs()
    for p in paths { print("WAV: \(p)") }
  }
}
