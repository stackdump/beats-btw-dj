import Testing

@testable import DJCore

// Brushes on jazz's snare (`Brush`, `WaveOptions.brushes`, `.backbeat`'s jazz): the synth brush
// measured on mono renders of one hit through a linear master, the sampled path's Brush kit,
// and every other genre (and the parity path) left exactly as it was. 120 BPM.

private let sr = 48_000.0

/// One snare hit (GM 38 on beats' snare channel) at step 0 of a 16-step ring.
private func snareHit() -> Project {
  var p = Project()
  p.tempo = 120
  var n = NetBundle.ring(16)
  n.bind(0, note: 38, channel: 11, velocity: 100, duration: 50)
  n.track.channel = 11
  p.nets["snare"] = n
  return p
}

private func linear(brushes: Bool) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.brushes = brushes
  return o
}

/// RMS per `ms`-long window.
private func envelope(_ x: [Float], ms: Double = 5) -> [Double] {
  let w = Int(ms / 1000 * sr)
  return stride(from: 0, to: x.count - w, by: w).map { a in
    var s = 0.0
    for i in a..<(a + w) { s += Double(x[i]) * Double(x[i]) }
    return (s / Double(w)).squareRoot()
  }
}

struct BrushTests {
  /// The brush is band-passed noise and nothing else: no tone under it (beats' snare has a
  /// 180 Hz one), a slow rise and a long fall.
  @Test func theBrushVoiceIsNoiseOnly() {
    let v = Brush.voice
    #expect(v.kind == "snare")
    #expect(v.carrier == "noise")
    #expect(v.tone == 0 && v.toneMix == 0)
    #expect(v.filter == "bandpass")
    #expect(v.pulse.alpha == [1, -1])
    #expect(v.pulse.tau == [Brush.decay, Brush.attack])
    let stick = drumVoice(kind: "snare", instrument: "drums")
    #expect(stick.carrier == "noise+tone")
  }

  /// Rise ≥ 15 ms (onset at −20 dB to the peak, 5 ms windows) where the stick snare's is one
  /// window; the swish lasts 150–300 ms above −20 dB.
  @Test func theBrushRisesAndSwishes() {
    func shape(_ brushes: Bool) -> (riseMs: Double, lengthMs: Double) {
      let x = renderRunner(snareHit(), opts: linear(brushes: brushes), sampleRate: sr, seconds: 0.6)
      let env = envelope(x)
      let peak = env.max()!
      let at = env.firstIndex(of: peak)!
      let onset = env.firstIndex { $0 > peak * 0.1 }!
      let end = env.lastIndex { $0 > peak * 0.1 }!
      return (Double(at - onset) * 5, Double(end - onset + 1) * 5)
    }
    let brush = shape(true)
    let stick = shape(false)
    print("brush rise \(brush.riseMs) ms, length \(brush.lengthMs) ms; stick \(stick)")
    #expect(brush.riseMs >= 15, "brush rise \(brush.riseMs) ms")
    #expect(stick.riseMs <= 5, "stick rise \(stick.riseMs) ms")
    #expect(brush.lengthMs >= 150 && brush.lengthMs <= 300, "brush length \(brush.lengthMs) ms")
  }

  /// No tonal body: at the stick snare's 180 Hz tone (and below) the brush has nothing to speak
  /// of, relative to its own level.
  @Test func theBrushHasNoBody() {
    func body(_ brushes: Bool) -> Double {
      let x = renderRunner(snareHit(), opts: linear(brushes: brushes), sampleRate: sr, seconds: 0.3)
      return toneDB(x[...], 180, sampleRate: sr) - rmsDB(x[...])
    }
    let brush = body(true)
    let stick = body(false)
    print("180 Hz against the hit's RMS: brush \(brush) dB, stick \(stick) dB")
    #expect(stick - brush > 20, "brush \(brush) dB vs stick \(stick) dB")
  }

  /// Jazz plays brushes under `.backbeat`; no other genre does, and the parity options never.
  @Test func onlyJazzUnderBackbeatPlaysBrushes() {
    #expect(WaveOptions.extended.forGenre("jazz").brushes)
    for g in ["lofi", "bossa", "techno", "house", "ambient", "dnb"] {
      #expect(!WaveOptions.extended.forGenre(g).brushes, "\(g)")
    }
    var o = WaveOptions.extended
    o.musicality.remove(.backbeat)
    #expect(!o.forGenre("jazz").brushes)
    #expect(!WaveOptions().forGenre("jazz").brushes)
    #expect(!WaveOptions().brushes)
  }

  /// Every other genre renders bit for bit what it did; jazz's snare changes.
  @Test func otherGenresAreBitIdentical() {
    var base = WaveOptions()
    base.master = "linear"
    base.musicality = .backbeat
    let before = renderRunner(kitPhraseProject(), opts: base, sampleRate: sr, seconds: 1)
    for g in ["lofi", "bossa", "techno", "house"] {
      var o = base.forGenre(g)
      o.genre = nil
      #expect(
        renderRunner(kitPhraseProject(), opts: o, sampleRate: sr, seconds: 1) == before, "\(g)")
    }
    var jazz = base.forGenre("jazz")
    jazz.genre = nil
    #expect(renderRunner(kitPhraseProject(), opts: jazz, sampleRate: sr, seconds: 1) != before)
  }

  /// The Brush kit of a bank: bank 128 program 40, else the first bank-128 preset named a brush.
  @Test func theBrushPresetIsPicked() {
    let gm = [
      BankPreset(name: "Standard", bank: 128, program: 0),
      BankPreset(name: "Jazz", bank: 128, program: 32),
      BankPreset(name: "Brush", bank: 128, program: 40),
      BankPreset(name: "Brush 2", bank: 128, program: 41),
    ]
    #expect(DrumKits.brushPreset(in: gm)?.program == 40)
    let named = [
      BankPreset(name: "Standard", bank: 128, program: 0),
      BankPreset(name: "Brush Kit", bank: 128, program: 50),
      BankPreset(name: "Brushes", bank: 0, program: 40),
    ]
    #expect(DrumKits.brushPreset(in: named)?.program == 50)
    #expect(DrumKits.brushPreset(in: [BankPreset(name: "Standard", bank: 128, program: 0)]) == nil)
    #expect(DrumKits.brushKit(for: .kit("/nowhere.sf2", bank: 0, program: 127)) == nil)
  }

  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func museScoreHasABrushKit() throws {
    let kit = try #require(DrumKits.source(for: floorKit))
    let brush = try #require(DrumKits.brushKit(for: kit))
    guard case .kit(_, let bank, let program) = brush else {
      Issue.record("not a kit: \(brush)")
      return
    }
    #expect(bank == 128 && program == 40)
  }

  @Test(.enabled(if: appleBank != nil, "no gs_instruments.dls"))
  func applesBankHasABrushKit() throws {
    let kit = try #require(DrumKits.source(for: "gs_instruments.dls#128:0"))
    #expect(DrumKits.brushKit(for: kit) != nil)
  }

  /// On a sampled kit the snare lane plays the bank's Brush kit (another slot than the kit's),
  /// at full velocity; the other lanes keep the kit.
  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func aSampledSnarePlaysTheBrushKit() throws {
    let bank = SamplerBank(sampleRate: sr)
    var o = kitOptions(bank)
    let plain = WaveRunner.prepare(kitPhraseProject(kit: floorKit), sampleRate: sr, opts: o)
    o.brushes = true
    let brushed = WaveRunner.prepare(kitPhraseProject(kit: floorKit), sampleRate: sr, opts: o)
    func slot(_ p: WaveProject, _ kind: String) -> Lane? { p.lanes.first { $0.kind == kind } }
    let snare = try #require(slot(brushed, "snare"))
    let kick = try #require(slot(brushed, "kick"))
    #expect(snare.samplerSlot >= 0)
    #expect(snare.samplerSlot != kick.samplerSlot)
    #expect(snare.kitVelocity == 1)
    #expect(slot(plain, "snare")?.samplerSlot == slot(plain, "kick")?.samplerSlot)
    #expect(kick.samplerSlot == slot(plain, "kick")?.samplerSlot)
  }
}
