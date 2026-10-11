import Darwin
import Testing

@testable import DJCore

// The grid, the FFT analysis, the per-lane kernel sets, the interpolation and the cache of
// scope-model.js. Expected numbers: ModelEngineOracleData.swift, i.e. the JS run by node
// (scripts/scope-model-oracle.mjs) on the same synthetic inputs, plus closed forms.

private let sr = 44100.0
private let n = ModelKernels.fftN

/// Float tolerance: relative 1e-4 plus a small absolute floor (the FFT is the same algorithm in
/// double; the slack is Float rounding of the input and of r, and 1-ulp libm differences).
private func close(_ a: Double, _ b: Double, rel: Double = 1e-4, abs floor: Double = 1e-5) -> Bool {
  Swift.abs(a - b) <= rel * Swift.abs(b) + floor
}

/// A decaying 1 kHz sine, hit 20 ms into the window: ‖oracle `sigSine`.
private func sigSine() -> [Float] {
  var x = [Float](repeating: 0, count: n)
  let off = Int((ModelKernels.hitAt * sr).rounded())
  for i in off..<n {
    let k = Double(i - off)
    x[i] = Float(exp(-k / (0.05 * sr)) * sin(2 * Double.pi * 1000 * k / sr))
  }
  return x
}

/// Decaying LCG noise (20 ms), hit 20 ms in: ‖ oracle `sigNoise`.
private func sigNoise() -> [Float] {
  var x = [Float](repeating: 0, count: n)
  let off = Int((ModelKernels.hitAt * sr).rounded())
  var s: UInt32 = 12345
  for i in off..<n {
    let k = Double(i - off)
    s = s &* 1_664_525 &+ 1_013_904_223
    let u = Double(s) / 4_294_967_296 - 0.5
    x[i] = Float(u * exp(-k / (0.02 * sr)))
  }
  return x
}

private func lane(
  notes: [Int], durs: [Double] = [], drum: Bool = false, instrument: String = "bass",
  group: String = "main", deck: String = "A"
) -> ScopeLane {
  ScopeLane(
    key: "k", ids: ["k"], channel: drum ? 10 : 1, group: group, drum: drum,
    instrument: instrument, notes: notes, durationsMs: durs, lo: notes.min() ?? 48,
    hi: notes.max() ?? 72, color: ScopeColors.defaultLaneColor,
    deck: deck)
}

struct ModelGridTests {
  @Test func theRowsAreFiveBandsThenTwentyEightBins() {
    #expect(ModelGrid.nb == 5 && ModelGrid.ns == 28 && ModelGrid.nr == 33 && ModelGrid.rows == 6)
    #expect(ModelGrid.bandLabels == ["sub", "low", "lomid", "himid", "high"])
    #expect(ModelGrid.bands.map(\.lo) == [20, 80, 250, 2000, 6000])
    #expect(ModelGrid.bands.map(\.hi) == [80, 250, 2000, 6000, 16000])
    #expect(ModelGrid.maxBars == 1024 && ModelGrid.specCap == 2048)
  }

  @Test func theBinEdgesAreLogSpacedFrom30To16000() {
    let e = ModelGrid.specEdges
    #expect(e.count == 29)
    #expect(e[0] == 30)
    #expect(close(e[28], 16000, rel: 1e-12))
    // 30·(16000/30)^(i/28): a constant ratio between neighbours
    let ratio = pow(16000.0 / 30, 1.0 / 28)
    for i in 0..<28 { #expect(close(e[i + 1] / e[i], ratio, rel: 1e-12)) }
    // and the full table of rows is what node computes
    #expect(ModelGrid.edges.count == ModelOracle.edges.count)
    for (got, want) in zip(ModelGrid.edges, ModelOracle.edges) {
      #expect(close(got.lo, want.0, rel: 1e-12) && close(got.hi, want.1, rel: 1e-12))
    }
    // rows 0...4 are the bands, row 5 + j is bin j
    #expect(ModelGrid.edges[2].lo == 250 && ModelGrid.edges[2].hi == 2000)
    #expect(ModelGrid.edges[5].lo == e[0] && ModelGrid.edges[5].hi == e[1])
    #expect(ModelGrid.edges[32].hi == e[28])
  }

  @Test func fourLogSpacedProbesPerRow() {
    let f = ModelGrid.probeFrequencies
    #expect(f.count == 33 * 4)
    // lo·(hi/lo)^((p + .5)/4): row 0 is 20...80, a ratio of 4
    for p in 0..<4 { #expect(close(f[p], 20 * pow(4.0, (Double(p) + 0.5) / 4), rel: 1e-12)) }
    // against node, at the first four, the first of the bins, and the last
    let pick = [0, 1, 2, 3, 4 * 5, 4 * 5 + 3, 4 * 32 + 3].map { f[$0] }
    for (got, want) in zip(pick, ModelOracle.probeSubset) { #expect(close(got, want, rel: 1e-12)) }
    // strictly inside the row, ascending
    for j in 0..<33 {
      let e = ModelGrid.edges[j]
      for p in 0..<4 {
        #expect(f[j * 4 + p] > e.lo && f[j * 4 + p] < e.hi)
        if p > 0 { #expect(f[j * 4 + p] > f[j * 4 + p - 1]) }
      }
    }
  }
}

struct ModelAnalyseHitTests {
  @Test func aDecayingSineAgainstTheClosedForm() {
    let k = ModelKernels.analyseHit(sigSine(), sampleRate: sr)
    // energy-centroid time = the 20 ms head + T/2 for an amplitude e^{-t/T} (T = 50 ms)
    #expect(close(k.tau, 0.02 + 0.05 / 2, rel: 1e-4), "tau \(k.tau)")
    // Parseval: all the energy of a 1 kHz tone lands in 'lomid' (250-2000 Hz)
    let energy = ModelOracle.sineEnergy
    #expect(close(Double(k.r[2]), energy, rel: 0.01), "lomid \(k.r[2]) vs Σx² \(energy)")
    for b in [0, 1, 3, 4] { #expect(Double(k.r[b]) < 1e-3 * energy, "band \(b) = \(k.r[b])") }
    // and in the one spectrogram bin that holds 1 kHz
    let bin = ModelGrid.edges.dropFirst(5).firstIndex { $0.lo <= 1000 && 1000 < $0.hi }!
    #expect(close(Double(k.r[bin]), energy, rel: 0.02), "bin \(bin - 5)")
    var others = 0.0
    for j in 5..<33 where j != bin { others += Double(k.r[j]) }
    #expect(others < 0.02 * energy)
  }

  @Test func theWholeSpectrumMatchesTheJavaScriptFFT() {
    for (name, x, tau, r) in [
      ("sine", sigSine(), ModelOracle.sineTau, ModelOracle.sineR),
      ("noise", sigNoise(), ModelOracle.noiseTau, ModelOracle.noiseR),
    ] {
      let k = ModelKernels.analyseHit(x, sampleRate: sr)
      #expect(close(k.tau, tau, rel: 1e-9), "\(name) tau \(k.tau) vs \(tau)")
      #expect(k.r.count == 33)
      for j in 0..<33 {
        #expect(
          close(Double(k.r[j]), r[j], rel: 1e-4, abs: 1e-5),
          "\(name) row \(j): \(k.r[j]) vs \(r[j])")
      }
    }
  }

  @Test func theWindowStartMovesTheCentroid() {
    let k = ModelKernels.analyseHit(sigNoise(), start: 100, sampleRate: sr)
    #expect(close(k.tau, ModelOracle.noiseShiftedTau, rel: 1e-9))
    for j in 0..<33 {
      #expect(close(Double(k.r[j]), ModelOracle.noiseShiftedR[j], rel: 1e-3, abs: 1e-4), "row \(j)")
    }
    // data shorter than the window is read as zero past its end
    let short = Array(sigSine()[0..<20_000])
    let a = ModelKernels.analyseHit(short, sampleRate: sr)
    var padded = short
    padded.append(contentsOf: [Float](repeating: 0, count: n - 20_000))
    let b = ModelKernels.analyseHit(padded, sampleRate: sr)
    #expect(a == b)
  }

  @Test func silenceIsTauOneTenthAndNoEnergy() {
    let k = ModelKernels.analyseHit([Float](repeating: 0, count: n), sampleRate: sr)
    #expect(k.tau == ModelOracle.silentTau && k.tau == 0.1)
    #expect(k.r.allSatisfy { $0 == 0 })
  }

  @Test func tauHasAFloorOfTwentyMilliseconds() {
    var x = [Float](repeating: 0, count: n)
    x[0] = 1  // the centroid is at 0 s
    #expect(ModelKernels.analyseHit(x, sampleRate: sr).tau == 0.02)
    x[0] = 0
    x[44_100 / 10] = 1  // 100 ms
    #expect(close(ModelKernels.analyseHit(x, sampleRate: sr).tau, 0.1, rel: 1e-9))
  }

  @Test func aBurstLightsTheRightBandAndTheRightBin() {
    // A constant-amplitude 100 Hz tone, then a 10 kHz one: 'low' (80-250) and 'high' (6-16 kHz).
    for (f, band) in [(100.0, 1), (10_000.0, 4), (50.0, 0), (4_000.0, 3), (500.0, 2)] {
      var x = [Float](repeating: 0, count: n)
      for i in 0..<30_000 { x[i] = Float(0.5 * sin(2 * Double.pi * f * Double(i) / sr)) }
      let k = ModelKernels.analyseHit(x, sampleRate: sr)
      let total = (0..<5).reduce(0.0) { $0 + Double(k.r[$1]) }
      #expect(
        Double(k.r[band]) > 0.95 * total, "\(f) Hz: band \(band) has \(k.r[band]) of \(total)")
      let bin = ModelGrid.edges.dropFirst(5).firstIndex { $0.lo <= f && f < $0.hi }! - 5
      let spec = (0..<28).map { Double(k.r[5 + $0]) }
      #expect(spec.firstIndex(of: spec.max()!) == bin, "\(f) Hz in bin \(bin)")
    }
  }
}

struct ModelLaneSpecTests {
  @Test func notesAndLengthsFollowTheJavaScriptRules() {
    for (notes, durs, drum, reps, dur) in ModelOracle.specs {
      let specs = ModelKernels.laneKernelSpecs(for: lane(notes: notes, durs: durs, drum: drum))
      if drum {
        // The JS takes the 8 lowest kit notes; here a note is its drum VOICE (`drumKind`), so
        // notes that share one share a kernel: the JS answer, one note per voice. A lane with no
        // notes (JS: kick 36) is read by its range, which `lane(...)` makes 48...72.
        var voices = Set<String>()
        let perVoice = reps.filter { voices.insert(drumKind($0)).inserted }
        if !notes.isEmpty { #expect(specs.map(\.note) == perVoice, "notes \(notes)") }
      } else {
        #expect(specs.map(\.note) == reps, "notes \(notes) drum \(drum)")
      }
      #expect(specs.allSatisfy { $0.durMs == dur }, "durs \(durs) -> \(dur)")
      #expect(specs.allSatisfy { $0.drum == drum })
    }
  }

  @Test func anAbsurdLengthCannotTrapTheConversion() {
    // Int(Double) traps outside Int's range: the median is clamped to 40...700 as a Double first
    func dur(_ durs: [Double]) -> Int {
      ModelKernels.laneKernelSpecs(for: lane(notes: [60], durs: durs))[0].durMs
    }
    #expect(
      dur([1e22]) == 700 && dur([.infinity]) == 700 && dur([Double.greatestFiniteMagnitude]) == 700)
    #expect(dur([-1e22]) == 40 && dur([-.infinity]) == 40 && dur([0]) == 40)
    #expect(dur([.nan]) == 200, "not a length: the default")
    #expect(dur([.nan, 100, 100]) >= 40, "and a stray NaN among real lengths does not trap")
    // the way it happens in the app: a project whose steps are absurdly long, or a tiny tempo
    let huge = ScopeLaneSet.durMs(
      of: MidiBinding(note: 60, channel: 1, velocity: 100, duration: 0, durationSteps: Int.max / 4),
      tempo: 120)
    #expect(huge > 1e17)
    #expect(dur([huge]) == 700)
    let slow = ScopeLaneSet.durMs(
      of: MidiBinding(note: 60, channel: 1, velocity: 100, duration: 0, durationSteps: 4),
      tempo: 1e-320)
    #expect(slow.isInfinite && dur([slow]) == 700)
  }

  @Test func theLengthIsTheMedianRoundedToTenAndClamped() {
    func dur(_ durs: [Double]) -> Int {
      ModelKernels.laneKernelSpecs(for: lane(notes: [60], durs: durs))[0].durMs
    }
    #expect(dur([]) == 200, "no lengths: 200")
    #expect(dur([100, 120, 400]) == 120, "the median, not the mean")
    #expect(dur([10, 12, 14]) == 40, "clamped up to 40")
    #expect(dur([5000, 6000, 7000]) == 700, "clamped down to 700")
    #expect(dur([144]) == 140 && dur([145]) == 150 && dur([146]) == 150, "round to 10 ms")
    #expect(dur([142.5, 143, 144]) == 140)
    #expect(dur([3, 1, 2, 9_000]) == 40, "sorted first: the median of 4 is index 2")
  }

  @Test func drumsTakeOneKernelPerVoiceTonalLowMedianHigh() {
    // 36 kick; 37 and 38 snare; 39 clap; 42, 44 and 46 hat; 49 open hat; 51 and 56: the engine's
    // fallback, a kick (`drumKind`). The lowest note of each voice stands for it.
    let kit = [51, 36, 38, 42, 46, 49, 39, 44, 56, 37]
    let d = ModelKernels.laneKernelSpecs(for: lane(notes: kit, drum: true, instrument: "drums"))
    #expect(d.map(\.note) == [36, 37, 39, 42, 49])
    #expect(d.map { drumKind($0.note) } == ["kick", "snare", "clap", "hat", "openhat"])
    // the JS would cut a long kit at its 8 lowest notes and lose the open hat that is the 9th
    let long = [36, 38, 39, 41, 42, 43, 44, 45, 46, 49]
    let lost = ModelKernels.laneKernelSpecs(for: lane(notes: long, drum: true))
    #expect(lost.map(\.note) == [36, 38, 39, 42, 49], "49 is the open hat, whatever its rank")
    let t = ModelKernels.laneKernelSpecs(for: lane(notes: [67, 48, 55, 60, 72]))
    #expect(t.map(\.note) == [48, 60, 72], "lowest, middle (index n>>1), highest")
    #expect(ModelKernels.laneKernelSpecs(for: lane(notes: [60, 60])).map(\.note) == [60])
    #expect(ModelKernels.laneKernelSpecs(for: lane(notes: [48, 50])).map(\.note) == [48, 50])
    // a lane with neither notes nor a range (lo > hi, which `ScopeLaneSet` never reports): the
    // JS default, kick 36 / middle C 60
    var none = lane(notes: [], drum: true)
    none.lo = 127
    none.hi = 0
    #expect(ModelKernels.laneKernelSpecs(for: none).map(\.note) == [36])
    none.drum = false
    #expect(ModelKernels.laneKernelSpecs(for: none).map(\.note) == [60])
  }

  @Test func aLaneKnownOnlyByItsRangeUsesTheRangeNotTheDefault() {
    // lanes built from the engine's layout have no note list but a range (lo/hi)
    var hat = lane(notes: [], drum: true, instrument: "drums")
    hat.lo = 42
    hat.hi = 46
    #expect(ModelKernels.laneKernelSpecs(for: hat).map(\.note) == [42], "42...46 is one voice")
    hat.hi = 42
    #expect(ModelKernels.laneKernelSpecs(for: hat).map(\.note) == [42])
    // a drum range plays every voice inside it: a snare in 36...42 must not be a kick
    var kit = lane(notes: [], drum: true, instrument: "drums")
    kit.lo = 36
    kit.hi = 42
    let voices = ModelKernels.laneKernelSpecs(for: kit).map(\.note)
    #expect(voices == [36, 37, 39, 42], "kick, snare, clap, hat; 41 is a kick again")
    // and a wild range is held to the MIDI notes
    kit.lo = -5
    kit.hi = 100_000
    #expect(ModelKernels.laneKernelSpecs(for: kit).map(\.note) == [0, 37, 39, 42, 49])
    var bass = lane(notes: [])
    bass.lo = 36
    bass.hi = 48
    #expect(ModelKernels.laneKernelSpecs(for: bass).map(\.note) == [36, 48])
    // 48...72 is what `ScopeLaneSet` reports for a lane with no notes at all. That lane never
    // fires, whereas a layout lane that really spans 48...72 does: it is read as a range
    bass.lo = 48
    bass.hi = 72
    #expect(ModelKernels.laneKernelSpecs(for: bass).map(\.note) == [48, 72])
  }

  @Test func keysNameTheInstrumentNoteLengthAndThePatch() {
    let a = ModelKernels.laneKernelSpecs(for: lane(notes: [36], drum: true, instrument: "drums"))[0]
    let parts = a.key.split(separator: "|", omittingEmptySubsequences: false)
    #expect(parts.count == 4 && parts[0] == "drums" && parts[1] == "36" && parts[2] == "200")
    #expect(!parts[3].isEmpty && parts[3].allSatisfy { $0.isNumber || ("a"..."z").contains($0) })
    // stable: these literals pin the fingerprint of the voice and of the render recipe; a
    // change to either (or to a voice) must change the keys, so cached kernels are not reused
    #expect(a.key == "drums|36|200|wdxd27")
    #expect(
      ModelKernels.kernelKey(instrument: "bass", group: "bass", channel: 6, note: 48, durMs: 120)
        == "bass|48|120|15ppu4y")
    // the patch is the voice: a different kit, a different hash; another kick note, the same
    let k808 = ModelKernels.kernelKey(
      instrument: "drums-808", group: "main", channel: 10, note: 36, durMs: 200)
    let k35 = ModelKernels.kernelKey(
      instrument: "drums", group: "main", channel: 10, note: 35, durMs: 200)
    func hash(_ k: String) -> String { String(k.split(separator: "|").last!) }
    #expect(hash(k808) != hash(a.key))
    #expect(hash(k35) == hash(a.key), "notes 35 and 36 are both the kick voice")
    let snare = ModelKernels.kernelKey(
      instrument: "drums", group: "main", channel: 10, note: 38, durMs: 200)
    #expect(hash(snare) != hash(a.key))
    // tonal: the group shapes the voice (pad/harmony/bass), so it is in the hash
    let pad = ModelKernels.kernelKey(
      instrument: "x", group: "pad", channel: 1, note: 60, durMs: 200)
    let main = ModelKernels.kernelKey(
      instrument: "x", group: "main", channel: 1, note: 60, durMs: 200)
    #expect(hash(pad) != hash(main))
    #expect(
      hash(main)
        == hash(
          ModelKernels.kernelKey(
            instrument: "x", group: "stinger", channel: 1, note: 60, durMs: 200)),
      "main and stinger are no group: the same voice")
    // and the length is in the key, as in the JS
    #expect(
      ModelKernels.kernelKey(instrument: "x", group: "main", channel: 1, note: 60, durMs: 300)
        != main)
  }
}

struct ModelKernelTableTests {
  /// Kernels `base · (1 + j)` with the given taus, notes ascending: the oracle's.
  private func table(drum: Bool, notes: [Int], cache: ModelKernelCache = ModelKernelCache())
    -> ModelKernelTable?
  {
    let bases: [Float] = [1, 4, 16, 64]
    let taus = [0.1, 0.2, 0.3, 0.4]
    var specs: [ModelKernelSpec] = []
    for (i, note) in notes.enumerated() {
      let key = "k\(drum ? "d" : "t")\(i)"
      cache.insert(
        ModelKernel(r: (0..<33).map { bases[i] * Float(1 + $0) }, tau: taus[i]), for: key)
      specs.append(
        ModelKernelSpec(
          key: key, instrument: "x", group: "main", channel: drum ? 10 : 1, note: note, durMs: 200))
    }
    return ModelKernels.laneKernelTable(specs, drum: drum, cache: cache)
  }

  private func sample(_ t: ModelKernelTable, _ note: Int) -> [Double] {
    var out = [Float](repeating: 0, count: 33)
    t.kernelFor(note: note, into: &out)
    return [out[0], out[1], out[5], out[32]].map(Double.init)
  }

  @Test func theTableIsLogEnergyAndTheMeanTau() throws {
    let t = try #require(table(drum: false, notes: [40, 60, 80]))
    #expect(t.notes == [40, 60, 80] && t.n == 3 && !t.drum && t.durMs == 200)
    #expect(close(t.tau, ModelOracle.tonalTau, rel: 1e-12) && close(t.tau, 0.2, rel: 1e-12))
    #expect(t.logR.count == 3 * 33)
    #expect(close(Double(t.logR[0]), 0, abs: 1e-6) && close(Double(t.logR[1]), log(2.0), rel: 1e-6))
    // missing kernel: nil. A table of tiny kernels is floored at ln 1e-20, and tau at 0.03
    let cache = ModelKernelCache()
    let spec = ModelKernelSpec(
      key: "none", instrument: "", group: "", channel: 1, note: 60, durMs: 200)
    #expect(ModelKernels.laneKernelTable([spec], drum: false, cache: cache) == nil)
    cache.insert(ModelKernel(r: [Float](repeating: 0, count: 33), tau: 0.02), for: "none")
    let quiet = try #require(ModelKernels.laneKernelTable([spec], drum: false, cache: cache))
    #expect(quiet.logR.allSatisfy { close(Double($0), log(1e-20), rel: 1e-6) })
    #expect(quiet.tau == 0.03, "max(0.03, mean tau)")
  }

  @Test func tonalKernelsInterpolateInLogEnergyAndClampOutside() throws {
    let t = try #require(table(drum: false, notes: [40, 60, 80]))
    for (note, want) in ModelOracle.tonalKernelFor {
      let got = sample(t, note)
      for (g, w) in zip(got, want) { #expect(close(g, w, rel: 1e-5), "note \(note): \(g) vs \(w)") }
    }
    // clamped: below the lowest and above the highest note
    #expect(sample(t, 0) == sample(t, 40) && sample(t, 127) == sample(t, 80))
    // the knots are exact, and the energy between them is the geometric mean at the middle
    #expect(close(sample(t, 60)[0], 4, rel: 1e-5))
    #expect(close(sample(t, 50)[0], 2, rel: 1e-5), "√(1·4) halfway between 40 and 60")
    #expect(close(sample(t, 70)[0], 8, rel: 1e-5), "√(4·16) halfway between 60 and 80")
    // monotone with pitch (the kernels grow with pitch here)
    let rising = (30...90).map { sample(t, $0)[0] }
    #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 })
    // a single kernel is the same for every note
    let one = try #require(table(drum: false, notes: [60]))
    #expect(sample(one, 5) == sample(one, 60) && sample(one, 99) == sample(one, 60))
  }

  @Test func drumsPickTheirOwnVoiceElseTheNearestNoteAndNeverBlend() throws {
    let t = try #require(table(drum: true, notes: [36, 38, 42]))  // kick, snare, hat
    #expect(t.kinds == ["kick", "snare", "hat"])
    let at36 = sample(t, 36)
    let at38 = sample(t, 38)
    let at42 = sample(t, 42)
    // The JS (nearest note) values, where the voice of the note and the nearest note agree
    for (note, want) in ModelOracle.drumKernelFor where [30, 36, 38, 39, 40, 42].contains(note) {
      let got = sample(t, note)
      for (g, w) in zip(got, want) { #expect(close(g, w, rel: 1e-5), "note \(note): \(g) vs \(w)") }
    }
    // Where they do not, the voice wins: the engine plays 37 as a snare and 41 and 60 as the
    // fallback kick (JS: 36, 42, 42)
    #expect(sample(t, 37) == at38, "37 is a snare, not the kick next to it")
    #expect(sample(t, 41) == at36 && sample(t, 60) == at36, "kick is the engine's fallback voice")
    #expect(sample(t, 39) == at38, "a clap has no kernel here: the nearest note, 38")
    // every answer is exactly one of the three kernels
    for note in 30...50 { #expect([at36, at38, at42].contains(sample(t, note))) }
  }

  @Test func aDrumKeepsItsVoiceEvenWhenAnotherVoiceIsNearer() throws {
    let t = try #require(table(drum: true, notes: [36, 38, 42, 49]))  // + open hat
    let at42 = sample(t, 42)
    let at49 = sample(t, 49)
    #expect(at42 != at49)
    // 46 is a hat; the open hat at 49 is nearer in pitch (3 against 4) and a different sound
    #expect(sample(t, 46) == at42 && sample(t, 44) == at42 && sample(t, 43) == at42)
    #expect(sample(t, 57) == at49, "57 is the other open-hat note")
    // no rep of the voice at all: the nearest note, the lower on a tie
    let k = try #require(table(drum: true, notes: [36, 42]))
    #expect(sample(k, 38) == sample(k, 36), "a snare with no snare kernel: nearer the kick")
    #expect(sample(k, 40) == sample(k, 42), "nearer the hat")
    #expect(sample(k, 39) == sample(k, 36), "a tie goes to the lower note")
  }

  @Test func kernelForDoesNotAllocateTheOutput() throws {
    // The buffer is the caller's; filling it must not reallocate (a unique array stays put).
    let t = try #require(table(drum: false, notes: [40, 60, 80]))
    var out = [Float](repeating: 0, count: 33)
    let before = out.withUnsafeBufferPointer { $0.baseAddress }
    for note in 30...90 { t.kernelFor(note: note, into: &out) }
    #expect(out.withUnsafeBufferPointer { $0.baseAddress } == before)
  }
}

struct ModelKernelCacheTests {
  private func kernel(_ i: Int) -> ModelKernel {
    ModelKernel(r: [Float](repeating: Float(i), count: 33), tau: 0.05)
  }

  @Test func holdsFourHundredAndEvictsTheOldest() {
    let c = ModelKernelCache()
    #expect(c.capacity == 400 && ModelKernelCache.defaultCapacity == 400)
    for i in 0..<450 { c.insert(kernel(i), for: "k\(i)") }
    #expect(c.count == 400)
    #expect(!c.contains("k0") && !c.contains("k49") && c.contains("k50") && c.contains("k449"))
    #expect(c.keys.first == "k50" && c.keys.last == "k449")
    #expect(c.kernel(for: "k449") == kernel(449) && c.kernel(for: "k0") == nil)
  }

  @Test func replacingAKeyKeepsItsAgeLikeAMap() {
    let c = ModelKernelCache(capacity: 3)
    c.insert(kernel(1), for: "a")
    c.insert(kernel(2), for: "b")
    c.insert(kernel(3), for: "c")
    c.insert(kernel(9), for: "a")  // replaced, not renewed
    #expect(c.kernel(for: "a") == kernel(9) && c.count == 3)
    c.insert(kernel(4), for: "d")  // evicts the oldest, which is still "a"
    #expect(c.keys == ["b", "c", "d"])
    c.removeAll()
    #expect(c.count == 0 && c.keys.isEmpty)
  }

  @Test func theBackgroundWriterAndTheMainThreadMayShareIt() {
    let c = ModelKernelCache(capacity: 64)
    #expect(hammer(c) == 0, "no read saw a torn or foreign kernel")
    #expect(c.count <= 64 && c.count > 0)
    // the map and the age list stayed one and the same set
    #expect(c.keys.count == c.count && Set(c.keys).count == c.count)
    #expect(c.keys.allSatisfy { c.contains($0) })
  }

  @Test func oneLaneSetAlwaysFitsInTheCache() {
    // A drum lane needs one kernel per voice, a tonal lane at most three, whatever its notes:
    // 2 decks x 32 lanes x 5 = 320 < 400, so the cap never evicts the lanes being shown.
    let every = Array(0...127)
    let drum = ModelKernels.laneKernelSpecs(for: lane(notes: every, drum: true))
    let tonal = ModelKernels.laneKernelSpecs(for: lane(notes: every))
    #expect(drum.count == 5 && tonal.count == 3)
    #expect(2 * ScopeLaneSet.maxLanes * drum.count <= ModelKernelCache.defaultCapacity)
  }

  @Test func renderKernelsSkipsWhatIsCachedAndDuplicates() {
    let c = ModelKernelCache()
    let kick = ModelKernelSpec(
      key: "kick", instrument: "drums", group: "main", channel: 10, note: 36, durMs: 200)
    let hat = ModelKernelSpec(
      key: "hat", instrument: "drums", group: "main", channel: 10, note: 42, durMs: 200)
    c.insert(ModelKernel(r: [Float](repeating: 1, count: 33), tau: 0.5), for: "hat")
    #expect(ModelKernels.renderKernels([kick, hat, kick], into: c) == 1, "hat cached, kick twice")
    #expect(c.kernel(for: "hat")?.tau == 0.5, "a cached kernel is not replaced")
    #expect(c.contains("kick"))
    #expect(ModelKernels.renderKernels([kick, hat], into: c) == 0)
    // cancelled before the first: nothing rendered
    let c2 = ModelKernelCache()
    #expect(ModelKernels.renderKernels([kick], into: c2, isCancelled: { true }) == 0)
    #expect(c2.count == 0)
  }
}
