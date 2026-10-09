import Darwin
import Testing

@testable import DJCore

// The model against the real engine, in absolute level. The deck here runs at 44.1 kHz, the rate
// the kernels are rendered at, so the energies compare without a sample-rate factor
// (Σ x² of a signal grows with its rate; at 22.05 kHz the same loop reads half: see
// `ModelEngineFeedTests`). The measured side is the deck's tap, analysed with the model's own
// row layout (`SampleRecorder.rows`).

/// Bar `bar` of the feed's lead deck as engine frames: `[start, end)`.
@MainActor
private func frames(ofBar bar: Int, _ feed: ScopeFeed, rate: Double) -> (Int, Int) {
  let a = Int((feed.timeAt(step: Double(16 * bar)) ?? 0) * rate)
  let b = Int((feed.timeAt(step: Double(16 * (bar + 1))) ?? 0) * rate)
  return (a, b)
}

@MainActor
struct ModelEngineEnergyTests {
  @Test func theModelPredictsTheEnergyOfARealDeckWhenTheRatesMatch() throws {
    let rig = try ModelRig(net: ["A"], genre: "techno", seed: 42, tempo: 120, rate: 44_100)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 120)])
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    let rec = SampleRecorder(feed)
    for _ in 0..<24 {  // 12 s: six bars at 2 s
      rig.render(seconds: 0.5)
      rig.hub.pump()
      model.consume(feed)
      rec.update()
    }
    #expect(model.maxBar >= 5 && model.missedFires == 0)
    // bars 1 ... maxBar-2: whole bars, in steady state (bar 0 starts cold, the last is open)
    var measured = 0.0
    var predicted = 0.0
    var bands = [Double](repeating: 0, count: 5)
    var modelBands = [Double](repeating: 0, count: 5)
    for bar in 1..<(model.maxBar - 1) {
      let (f0, f1) = frames(ofBar: bar, feed, rate: rig.rate)
      let e = rec.energy(from: f0, to: f1)
      let m = model.modelBars[bar * ModelGrid.rows + 5]
      #expect(e / m > 0.85 && e / m < 1.1, "bar \(bar): measured/model = \(e / m)")
      measured += e
      predicted += m
      let rows = rec.rows(from: f0, to: f1, sampleRate: rig.rate)
      for b in 0..<5 {
        bands[b] += rows[b]
        modelBands[b] += model.modelBars[bar * ModelGrid.rows + b]
      }
    }
    // Measured 0.94 (0.93 ... 0.97 per bar). The linear kernel and the 0.8 gain put the level
    // right; a kernel through the soft master's tanh, or the 0.8 applied twice, reads 1.5.
    #expect(measured / predicted > 0.8 && measured / predicted < 1.1, "\(measured / predicted)")
    // and in every band (measured: sub 1.01, low 0.91, lomid 0.87, himid 0.87, high 0.87)
    for b in 0..<5 {
      let r = bands[b] / modelBands[b]
      #expect(r > 0.75 && r < 1.3, "\(ModelGrid.bandLabels[b]): measured/model = \(r)")
    }
  }

  @Test func underAStrongFilterAndEQTheBinsAndTheNarrowBandsAreRightAndTheWideBandReadsLow() throws
  {
    // The master feed of a deck with its DJ filter low-passing at ~900 Hz, the bass shelf and the
    // mid band cut, the faders and the master down: every one of them enters the response.
    let rig = try ModelRig(net: ["A"], genre: "techno", seed: 42, tempo: 120, rate: 44_100)
    defer { rig.stop() }
    let cache = warmedCache([("techno", 42, "loop", 120)])
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let model = ModelEngine(engine: rig.dj, cache: cache)
    let a = try #require(rig.dj["A"])
    rig.dj.crossfader = 0
    a.filter = 0.15
    a.eqLow = 0.8
    a.eqMid = 0.25
    a.volume = 0.6
    a.gain = 0.5 + log2(0.7) / 2  // trim 0.7
    rig.dj.master = 0.7
    let rec = SampleRecorder(feed)
    for _ in 0..<24 {
      rig.render(seconds: 0.5)
      rig.hub.pump()
      model.consume(feed)
      rec.update()
    }
    #expect(model.maxBar >= 5 && feed.leadDeck == "A")
    var bands = [Double](repeating: 0, count: 5)
    var modelBands = [Double](repeating: 0, count: 6)
    var binMeasured = [Double](repeating: 0, count: ModelGrid.ns)
    var binModel = [Double](repeating: 0, count: ModelGrid.ns)
    let tickSec = feed.tickSec
    for bar in 1..<(model.maxBar - 1) {
      let (f0, f1) = frames(ofBar: bar, feed, rate: rig.rate)
      let rows = rec.rows(from: f0, to: f1, sampleRate: rig.rate)
      for b in 0..<5 { bands[b] += rows[b] }
      for j in 0..<ModelGrid.ns { binMeasured[j] += rows[ModelGrid.nb + j] }
      for b in 0..<6 { modelBands[b] += model.modelBars[bar * ModelGrid.rows + b] }
      for step in (16 * bar)..<(16 * (bar + 1)) {
        for j in 0..<ModelGrid.ns {
          binModel[j] +=
            Double(model.specCol[(step % ModelGrid.specCap) * ModelGrid.ns + j]) * tickSec
        }
      }
    }
    // The 5 bands: the narrow ones and the total are within 1.5x (measured: sub 1.00, low 0.92,
    // E 1.02) ...
    func ratio(_ b: Int) -> Double { bands[b] / modelBands[b] }
    #expect(ratio(0) > 0.67 && ratio(0) < 1.5, "sub \(ratio(0))")
    #expect(ratio(1) > 0.67 && ratio(1) < 1.5, "low \(ratio(1))")
    let total = bands.reduce(0, +) / modelBands[5]
    #expect(total > 0.67 && total < 1.5, "E \(total)")
    // ... and so are the spectrogram bins where the sound is (52 ... 494 Hz: bins 2 ... 12;
    // measured 0.88 ... 1.01 each). Below them the 30-41 Hz bins are the measurement's leakage.
    var sumMeasured = 0.0
    var sumModel = 0.0
    for j in 2...12 {
      let r = binMeasured[j] / binModel[j]
      #expect(r > 0.75 && r < 1.3, "bin \(j) (\(Int(ModelGrid.specEdges[j])) Hz): \(r)")
      sumMeasured += binMeasured[j]
      sumModel += binModel[j]
    }
    #expect(sumMeasured / sumModel > 0.85 && sumMeasured / sumModel < 1.15)
    // The wide `lomid` band (250-2000 Hz) is NOT right, and this pins how: the response of a
    // row is the mean of |H|² at 4 probe frequencies (scope-model.js; the spec), the corner of the
    // filter is inside the band and the energy sits at its low edge (the kick and the bass at
    // 250-550 Hz, where the filter does nothing), so the row is attenuated about 3.6 times too
    // much. If the rule changes (the probes weighted by the kernel), this must change with it.
    #expect(ratio(2) > 2.5 && ratio(2) < 6, "lomid measured/model \(ratio(2))")
    model.refreshFx()
    let fx = model.fxRow(forLane: 0)
    let base = fx.startIndex
    let lomid = Double(fx[base + 2])
    var inBand = 0.0  // the bins of 250-554 Hz, which hold the energy
    for j in 9...12 { inBand += Double(fx[base + ModelGrid.nb + j]) }
    inBand /= 4
    #expect(lomid < inBand / 3, "band row \(lomid), bins 250-554 Hz \(inBand)")
  }
}
