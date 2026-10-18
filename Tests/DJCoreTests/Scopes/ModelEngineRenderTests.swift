import Darwin
import Testing

@testable import DJCore

// Kernels from the REAL synth: one hit of the wave engine's voice, rendered offline, analysed.
// The orderings asserted are physics the voices have by construction (a kick is low and long,
// a hi-hat is high and short); the margins are wide, the numbers behind them are in the
// comments. The projects are composed ones (techno seed 42 ...), prepared with the cores.

private func spec(
  _ inst: String, ch: Int, note: Int, dur: Int = 200, group: String = "main"
) -> ModelKernelSpec {
  ModelKernelSpec(key: "", instrument: inst, group: group, channel: ch, note: note, durMs: dur)
}

private func band(_ k: ModelKernel, _ b: Int) -> Double { Double(k.r[b]) }

/// The index of the loudest of the 28 spectrogram bins.
private func peakBin(_ k: ModelKernel) -> Int {
  let bins = (0..<28).map { Double(k.r[5 + $0]) }
  return bins.firstIndex(of: bins.max()!)!
}

struct ModelRealKernelTests {
  // 36: kick (sweep 48 -> 288 Hz), 38: snare, 39: clap, 42: closed hat, 49: open hat
  @Test func aKickIsLowAndLongAHatIsHighAndShort() {
    let kick = ModelKernels.renderHit(spec("drums", ch: 10, note: 36))
    let snare = ModelKernels.renderHit(spec("drums", ch: 10, note: 38))
    let hat = ModelKernels.renderHit(spec("drums", ch: 10, note: 42))
    // kick: sub 238, low 378, lomid 32 -> orders of magnitude over himid and high
    #expect(band(kick, 1) > 100 * band(kick, 3) && band(kick, 0) > 100 * band(kick, 4))
    #expect(band(kick, 0) + band(kick, 1) > 10 * (band(kick, 2) + band(kick, 3) + band(kick, 4)))
    // hat: high 4.0, himid 0.16 -> the reverse
    #expect(band(hat, 4) > 10 * band(hat, 3) && band(hat, 4) > 1000 * band(hat, 1))
    #expect(band(hat, 4) + band(hat, 3) > 100 * (band(hat, 0) + band(hat, 1) + band(hat, 2)))
    // snare: noise through a 3 kHz band-pass plus a 180 Hz tone -> low and himid, little sub
    #expect(band(snare, 1) > 10 * band(snare, 0) && band(snare, 3) > band(snare, 0))
    // decay: kick 0.081 s, snare 0.052 s, hat 0.034 s (energy centroid, including the 20 ms head)
    #expect(kick.tau > snare.tau && snare.tau > hat.tau, "\(kick.tau) \(snare.tau) \(hat.tau)")
    #expect(hat.tau >= 0.02 && kick.tau < 0.2)
    // the spectrogram bins agree with the bands: the kick peaks below 300 Hz, the hat above 6 kHz
    #expect(ModelGrid.edges[5 + peakBin(kick)].hi < 400)
    #expect(ModelGrid.edges[5 + peakBin(hat)].lo > 4000)
  }

  @Test func theKitSetsTheKickLengthAndTheOpenHatRingsLonger() {
    let tight = ModelKernels.renderHit(spec("drums-cr78", ch: 10, note: 36))
    let boom = ModelKernels.renderHit(spec("drums-808", ch: 10, note: 36))
    #expect(
      boom.tau > tight.tau, "808 kick decays 0.60 s, cr78 0.25 s: \(boom.tau) vs \(tight.tau)")
    #expect(band(boom, 0) > band(tight, 0), "and carries more sub")
    let closed = ModelKernels.renderHit(spec("drums", ch: 10, note: 42))
    let open = ModelKernels.renderHit(spec("drums", ch: 10, note: 49))
    #expect(open.tau > 1.5 * closed.tau, "\(open.tau) vs \(closed.tau)")
  }

  @Test func notesOfOneVoiceAreOneKernelAndRenderingIsDeterministic() {
    let a = ModelKernels.renderHit(spec("drums", ch: 10, note: 36))
    #expect(a == ModelKernels.renderHit(spec("drums", ch: 10, note: 36)))
    #expect(a == ModelKernels.renderHit(spec("drums", ch: 10, note: 35)), "35 and 36 are the kick")
    let h42 = ModelKernels.renderHit(spec("drums", ch: 10, note: 42))
    #expect(h42 == ModelKernels.renderHit(spec("drums", ch: 10, note: 44)), "42 ... 46 are the hat")
    #expect(a != h42)
  }

  @Test func tonalKernelsFollowThePitchAndTheLength() {
    let low = ModelKernels.renderHit(spec("bass", ch: 6, note: 36, group: "bass"))
    let high = ModelKernels.renderHit(spec("bass", ch: 6, note: 72, group: "bass"))
    #expect(
      peakBin(high) > peakBin(low),
      "an octave pair of octaves up: \(peakBin(low)) -> \(peakBin(high))")
    #expect(band(low, 0) + band(low, 1) > band(low, 3) + band(low, 4))
    #expect(band(high, 2) > band(high, 0) + band(high, 1))
    // a pad rings for as long as it is held: 700 ms against 100 ms
    let held = ModelKernels.renderHit(spec("dark-pad", ch: 7, note: 60, dur: 700, group: "harmony"))
    let tap = ModelKernels.renderHit(spec("dark-pad", ch: 7, note: 60, dur: 100, group: "harmony"))
    #expect(held.tau > 1.5 * tap.tau, "\(held.tau) vs \(tap.tau)")
    // the group shapes the voice: a "harmony" part is the soft pad wave whatever its name
    let soft = ModelKernels.renderHit(spec("keys", ch: 7, note: 60, dur: 100, group: "harmony"))
    let saw = ModelKernels.renderHit(spec("keys", ch: 7, note: 60, dur: 100, group: "main"))
    #expect(soft != saw && soft.tau != saw.tau)
    // (a name containing "pad" is the soft voice in either group, as tonalVoice has it)
    #expect(
      tap == ModelKernels.renderHit(spec("dark-pad", ch: 7, note: 60, dur: 100, group: "main")))
  }

  @Test func theKernelEnergyIsTheEnergyOfTheRenderedHit() {
    // Parseval on real audio: the five bands (20 Hz - 16 kHz) hold the energy of the hit, the
    // 28 bins (30 Hz - 16 kHz) nearly all of it.
    for s in [
      spec("drums", ch: 10, note: 36), spec("drums", ch: 10, note: 38),
      spec("bass", ch: 6, note: 48, group: "bass"),
    ] {
      let x = ModelKernels.renderHitSamples(s)
      let k = ModelKernels.analyseHit(x, sampleRate: ModelKernels.sampleRate)
      let energy = x.reduce(0.0) { $0 + Double($1) * Double($1) }
      let bands = (0..<5).reduce(0.0) { $0 + Double(k.r[$1]) }
      let bins = (5..<33).reduce(0.0) { $0 + Double(k.r[$1]) }
      #expect(
        energy > 0.1 && abs(bands / energy - 1) < 0.05,
        "\(s.instrument) \(s.note): bands \(bands) of \(energy)")
      #expect(bins / energy > 0.9 && bins / energy < 1.05)
    }
  }

  @Test func theHitStartsTwentyMillisecondsIn() {
    let x = ModelKernels.renderHitSamples(spec("drums", ch: 10, note: 36))
    let head = Int(ModelKernels.hitAt * ModelKernels.sampleRate)
    #expect(x[0..<head].allSatisfy { $0 == 0 }, "silence before the hit")
    #expect(x[head..<(head + 400)].contains { abs($0) > 0.1 }, "and the kick right after")
    #expect(x.count == 32768)
  }
}

@MainActor
struct ModelPreparedTests {
  @Test func aTechnoSongGetsATableForEveryLaneInWellUnderASecondOfWork() {
    let project = scopeProject("techno")
    let t0 = wallSeconds()
    let m = ModelEngine.prepared(project: project, tempo: 120, cache: ModelKernelCache())
    let took = wallSeconds() - t0
    #expect(m.tablesReady && m.lanes.count == 10)
    #expect(m.kernelCount == 15)
    #expect(m.status.hasPrefix("model · 15 kernels (") && m.status.hasSuffix(" ms)"), "\(m.status)")
    #expect(took < 10, "\(took) s")
    // lane order is drums first: hihat, kick, snare, then bass ... (scope.js buildLanes)
    let names = m.lanes.map(\.key)
    #expect(names.prefix(3).sorted() == ["hihat", "kick", "snare"])
    func table(_ key: String) -> ModelKernelTable { m.laneTables[names.firstIndex(of: key)!]! }
    var low = [Float](repeating: 0, count: 33)
    var high = [Float](repeating: 0, count: 33)
    let kick = table("kick")
    kick.kernelFor(note: 36, into: &low)
    let hat = table("hihat")
    hat.kernelFor(note: 42, into: &high)
    #expect(low[1] > 100 * low[4], "kick: low over high")
    #expect(high[4] > 100 * high[1], "hat: high over low")
    #expect(kick.tau > hat.tau, "\(kick.tau) vs \(hat.tau)")
    #expect(kick.drum && hat.drum && !table("bass").drum)
    #expect(table("bass").n >= 1 && table("bass").n <= 3)
  }

  @Test func theSecondTimeIsFromTheCache() {
    let cache = ModelKernelCache()
    let project = scopeProject("house")
    let first = ModelEngine.prepared(project: project, cache: cache)
    #expect(first.status.hasSuffix(" ms)"))
    let n = cache.count
    #expect(n > 0 && n == first.kernelCount, "every kernel of this song is distinct")
    let t0 = wallSeconds()
    let again = ModelEngine.prepared(project: project, cache: cache)
    #expect(wallSeconds() - t0 < 0.5)
    #expect(again.status == "model · \(n) kernels", "no render, no timing: \(again.status)")
    #expect(cache.count == n)
    #expect(again.laneTables.map { $0?.tau } == first.laneTables.map { $0?.tau })
  }

  @Test func kernelsRenderOnTheBackgroundQueueAndTheTablesArriveWhenPolled() {
    let project = scopeProject("dnb")
    let lanes = Array(ScopeLaneSet.build(project: project, tempo: 120, deck: "A").lanes.prefix(5))
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    m.setLanes(lanes)  // background
    #expect(
      m.status.hasPrefix("model · rendering ") && m.status.hasSuffix(" kernels…"), "\(m.status)")
    #expect(!m.hasTables, "nothing is deposited until a lane's table is in")
    m.waitForKernels(timeout: coldKernelTimeout)
    #expect(m.tablesReady)
    #expect(m.status.hasPrefix("model · ") && m.status.hasSuffix(" ms)"), "\(m.status)")
    #expect(m.kernelCount >= 5 && m.kernelCount <= 5 * 3)
  }

  @Test func aNewLaneSetCancelsTheOldJobAndAdoptsTheNewOne() {
    let cache = ModelKernelCache()
    let a = ScopeLaneSet.build(project: scopeProject("techno", seed: 1), tempo: 120, deck: "A")
      .lanes
    let b = ScopeLaneSet.build(project: scopeProject("ambient", seed: 2), tempo: 120, deck: "A")
      .lanes
    let m = ModelEngine(engine: nil, cache: cache)
    m.setLanes(a)
    m.setLanes(b)  // the job for `a` is cancelled; its result must never be adopted
    m.waitForKernels(timeout: coldKernelTimeout)
    #expect(m.lanes == b && m.tablesReady)
    for (i, lane) in b.enumerated() {
      let wanted = ModelKernels.laneKernelSpecs(for: lane).map(\.note)
      #expect(m.laneTables[i]?.notes == wanted, "lane \(lane.key)")
    }
  }

  @Test func atableWithoutItsKernelsIsPartial() {
    // a lane whose kernels are not in the cache and are not being rendered: 0 parts, no table
    let lanes = ScopeLaneSet.build(project: scopeProject("techno"), tempo: 120, deck: "A").lanes
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    m.setLanes(lanes, kernels: .none)
    #expect(m.status == "model · 0/10 parts" && !m.hasTables)
    // with an empty lane list there is nothing to model
    m.setLanes([], kernels: .background)
    #expect(m.status == "model idle" && m.kernelCount == 0)
  }
}
