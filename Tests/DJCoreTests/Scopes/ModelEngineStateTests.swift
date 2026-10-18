import Darwin
import Testing

@testable import DJCore

// The deposit arithmetic and the spectrogram state: scope.js `modelDeposit`, `specAdvance`,
// `resetHistory`. Two kinds of expectation: literals worked out by hand (readable tables with
// round numbers), and the JS itself run by node on a longer scenario (ModelOracle.deposit*).

private func close(_ a: Double, _ b: Double, rel: Double = 1e-5, abs floor: Double = 1e-9) -> Bool {
  Swift.abs(a - b) <= rel * Swift.abs(b) + floor
}

private func floats(_ a: [Float]) -> [Double] { a.map(Double.init) }

private func laneOf(_ channel: Int, deck: String, key: String = "k") -> ScopeLane {
  ScopeLane(
    key: key, ids: [key], channel: channel, group: "main", drum: isDrumChannel(channel),
    instrument: "x", notes: [60], durationsMs: [200], lo: 60, hi: 60,
    color: ScopeColors.defaultLaneColor, deck: deck)
}

/// One kernel per note: `r[j] = scale·(1 + j)` unless `shape` says otherwise.
private func table(
  drum: Bool, notes: [Int] = [60], tau: Double = 0.1, durMs: Int = 200,
  shape: (Int, Int) -> Float = { _, j in Float(1 + j) }
) -> ModelKernelTable {
  let cache = ModelKernelCache()
  var specs: [ModelKernelSpec] = []
  for (i, note) in notes.enumerated() {
    let key = "n\(i)"
    cache.insert(ModelKernel(r: (0..<33).map { shape(i, $0) }, tau: tau), for: key)
    specs.append(
      ModelKernelSpec(
        key: key, instrument: "x", group: "main", channel: drum ? 10 : 1, note: note, durMs: durMs))
  }
  return ModelKernels.laneKernelTable(specs, drum: drum, cache: cache)!
}

/// A model with one lane (drum or tonal) on deck "A", kernel r = 1, 2, 3, ..., tau 0.1.
@MainActor
private func oneLane(drum: Bool = false, tau: Double = 0.1) -> ModelEngine {
  let m = ModelEngine(engine: nil, cache: ModelKernelCache())
  m.setLanes([laneOf(drum ? 10 : 1, deck: "A")], tables: [table(drum: drum, tau: tau)])
  return m
}

@MainActor
struct ModelDepositTests {
  @Test func aDepositIsVelocitySquaredTimesTheKernelPerBand() {
    let m = oneLane()
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    // bands carry 1, 2, 3, 4, 5; E is their sum
    for (b, want) in [1.0, 2, 3, 4, 5, 15].enumerated() {
      #expect(close(m.modelBars[b], want), "band \(b): \(m.modelBars[b])")
    }
    #expect(m.maxBar == 0 && m.modelFrom == 0)
    // velocity 50 -> (50/100)² = 0.25; velocity 127 -> 1.6129
    let h = oneLane()
    h.deposit(lane: 0, note: 60, velocity: 50, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(h.modelBars[5], 15 * 0.25))
    let l = oneLane()
    l.deposit(lane: 0, note: 60, velocity: 127, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(l.modelBars[5], 15 * 1.6129))
    // and two deposits in one bar add up
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 7, tickSec: 0.1)
    #expect(close(m.modelBars[5], 30) && close(m.modelBars[0], 2))
    #expect(m.modelFrom == 0, "the first step stays the smallest")
  }

  @Test func aTonalNoteScalesByItsLengthClampedToAQuarterAndFour() {
    // kernel length 200 ms: factor = clamp(durMs/200, 0.25, 4)
    for (dur, factor) in [
      (200.0, 1.0), (400, 2), (800, 4), (2000, 4), (100, 0.5), (50, 0.25), (10, 0.25), (300, 1.5),
    ] {
      let m = oneLane(drum: false)
      m.deposit(lane: 0, note: 60, velocity: 100, durMs: dur, step: 0, tickSec: 0.1)
      #expect(close(m.modelBars[5], 15 * factor), "\(dur) ms: \(m.modelBars[5]) vs \(15 * factor)")
    }
  }

  @Test func aDrumHitIgnoresItsLength() {
    for dur in [10.0, 200, 5000] {
      let m = oneLane(drum: true)
      m.deposit(lane: 0, note: 60, velocity: 100, durMs: dur, step: 0, tickSec: 0.1)
      #expect(close(m.modelBars[5], 15), "\(dur) ms")
    }
  }

  @Test func theBarIsTheStepOverSixteenAndOnlyBars0To1023Count() {
    let m = oneLane()
    func add(_ step: Int) {
      m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: step, tickSec: 0.1)
    }
    add(15)
    #expect(m.maxBar == 0 && close(m.modelBars[5], 15) && close(m.modelBars[11], 0))
    add(16)
    #expect(m.maxBar == 1 && close(m.modelBars[11], 15))
    add(31)
    #expect(close(m.modelBars[11], 30), "step 31 is still bar 1")
    add(1023 * 16 + 15)
    #expect(m.maxBar == 1023 && close(m.modelBars[1023 * 6 + 5], 15))
    let before = (m.maxBar, m.modelFrom, m.modelBars)
    add(1024 * 16)  // bar 1024: off the end
    add(-1)  // bar -1: before the start
    #expect(m.maxBar == before.0)
    #expect(m.modelFrom == before.1)
    #expect(sameSamples(m.modelBars, before.2) == .identical)
    // the spectrogram state still takes the deposit when the bar is out of range
    let n = oneLane()
    n.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: -1, tickSec: 0.1)
    #expect(n.maxBar == -1 && n.laneState.contains { $0 > 0 })
    #expect(n.modelDb(bar: 0, row: 5) == nil)
  }

  @Test func theFxRowsMultiplyEveryBandAndEveryBin() {
    let m = oneLane()
    m.setFx(deck: "A", rows: (0..<33).map { Float($0 < 5 ? 0.5 : 2) })
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    for (b, k) in [1.0, 2, 3, 4, 5].enumerated() { #expect(close(m.modelBars[b], k * 0.5)) }
    #expect(close(m.modelBars[5], 15 * 0.5))
    // bin j: e·k·fx/τ with k = 6 + j, fx = 2, τ = 0.1
    for j in 0..<28 { #expect(close(Double(m.laneState[j]), Double(6 + j) * 2 / 0.1), "bin \(j)") }
  }

  @Test func aLaneWithoutATableIsSkippedAndABadLaneIgnored() {
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    m.setLanes(
      [laneOf(10, deck: "A"), laneOf(1, deck: "A", key: "t")], tables: [nil, table(drum: false)])
    m.deposit(lane: 0, note: 36, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(m.maxBar == -1 && m.specCur == -1)
    m.deposit(lane: 7, note: 36, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    m.deposit(lane: -1, note: 36, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(m.maxBar == -1)
    #expect(m.hasTables && !m.tablesReady)
    #expect(m.status == "model · 1/2 parts")
    m.deposit(lane: 1, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(m.maxBar == 0)
  }

  @Test func theKernelOfTheNoteIsUsed() {
    // Two representative tonal notes, kernel 1 = 4x kernel 0: a note halfway deposits 2x.
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    let t = table(drum: false, notes: [40, 80]) { i, j in Float(i == 0 ? 1 : 4) * Float(1 + j) }
    m.setLanes([laneOf(1, deck: "A")], tables: [t])
    m.deposit(lane: 0, note: 40, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(m.modelBars[0], 1))
    m.deposit(lane: 0, note: 80, velocity: 100, durMs: 200, step: 16, tickSec: 0.1)
    #expect(close(m.modelBars[6], 4))
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 32, tickSec: 0.1)
    #expect(close(m.modelBars[12], 2), "geometric midpoint in log energy")
  }

  @Test func modelDbIsTenLogTenOfThePowerOrNothing() {
    let m = oneLane()
    #expect(m.modelDb(bar: 0, row: 0) == nil)
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(m.modelDb(bar: 0, row: 4) ?? .nan, 10 * log10(5.0)))
    #expect(close(m.modelDb(bar: 0, row: 5) ?? .nan, 10 * log10(15.0)))
    #expect(m.modelDb(bar: 1, row: 0) == nil && m.modelDb(bar: -1, row: 0) == nil)
    #expect(m.modelDb(bar: 0, row: 6) == nil && m.modelDb(bar: 1024, row: 0) == nil)
  }
}

@MainActor
struct ModelSpectrogramTests {
  @Test func eachColumnIsTheMeanOfTheDecayOverOneStepAndTheStateDecays() {
    let m = oneLane(tau: 0.1)
    let tickSec = 0.1
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: tickSec)
    #expect(
      m.specCur == 0 && m.specStep.allSatisfy { $0 == -1 },
      "the first deposit only starts the clock")
    m.specAdvance(step: 3, tickSec: tickSec)
    #expect(m.specCur == 3)
    let d = exp(-tickSec / 0.1)
    let mean = 0.1 / tickSec * (1 - d)
    #expect(close(Double(m.laneDecay[0]), d) && close(Double(m.laneMean[0]), mean))
    for c in 0..<3 {
      #expect(m.specStep[c] == Int32(c))
      for j in 0..<28 {
        // state0 = e·k/τ with k = 6 + j; column c = state0 · mean · d^c
        let want = Double(6 + j) / 0.1 * mean * pow(d, Double(c))
        #expect(close(Double(m.specCol[c * 28 + j]), want), "col \(c) bin \(j)")
      }
    }
    #expect(m.specStep[3] == -1, "column 3 is not final yet")
    // the state left is state0·d³
    #expect(close(Double(m.laneState[0]), 6 / 0.1 * pow(d, 3)))
  }

  @Test func theColumnsAddUpToTheEnergyOfTheHit() {
    // Σ columns · tickSec = e·k per bin once the hit has rung out: energy is conserved
    for (tau, tickSec) in [(0.1, 0.1), (0.25, 0.05), (0.03, 0.2)] {
      let m = oneLane(tau: tau)
      m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: tickSec)
      m.specAdvance(step: 400, tickSec: tickSec)
      for j in [0, 7, 27] {
        var sum = 0.0
        for c in 0..<400 { sum += Double(m.specCol[c * 28 + j]) }
        #expect(
          close(sum * tickSec, Double(6 + j), rel: 1e-4),
          "tau \(tau) step \(tickSec) bin \(j): \(sum * tickSec)")
      }
    }
  }

  @Test func tauHasAFloorOfThirtyMillisecondsInTheTable() {
    let m = oneLane(tau: 0.001)
    #expect(m.laneTables[0]?.tau == 0.03)
  }

  @Test func theLaneStatesOfAllLanesSumIntoOneColumn() {
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    m.setLanes(
      [laneOf(10, deck: "A", key: "a"), laneOf(1, deck: "A", key: "b")],
      tables: [table(drum: true, tau: 0.1), table(drum: false, tau: 0.2)])
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    m.deposit(lane: 1, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    m.specAdvance(step: 1, tickSec: 0.1)
    let m0 = 0.1 / 0.1 * (1 - exp(-1.0))
    let m1 = 0.2 / 0.1 * (1 - exp(-0.5))
    let want = Double(6) * (1 / 0.1 * m0 + 1 / 0.2 * m1)
    #expect(close(Double(m.specCol[0]), want))
  }

  @Test func stepsMoreThanEightBackOrMoreThanTheRingAheadStartOver() {
    func fresh() -> ModelEngine {
      let m = oneLane()
      m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 10, tickSec: 0.1)
      #expect(m.specCur == 10 && m.laneState.contains { $0 > 0 })
      return m
    }
    let ok = fresh()
    ok.specAdvance(step: 2, tickSec: 0.1)  // 8 back: allowed, nothing to finalise
    #expect(ok.specCur == 10 && ok.laneState.contains { $0 > 0 })
    let back = fresh()
    back.specAdvance(step: 1, tickSec: 0.1)  // 9 back: start over at 1
    #expect(back.specCur == 1 && back.laneState.allSatisfy { $0 == 0 })
    let ahead = fresh()
    ahead.specAdvance(step: 10 + 2048, tickSec: 0.1)  // exactly the ring ahead: allowed
    #expect(ahead.specCur == 2058)
    #expect(ahead.specStep.filter { $0 >= 0 }.count == 2048)
    let past = fresh()
    past.specAdvance(step: 10 + 2049, tickSec: 0.1)  // one more: start over
    #expect(past.specCur == 2059 && past.laneState.allSatisfy { $0 == 0 })
    #expect(past.specStep.allSatisfy { $0 == -1 }, "no column was finalised")
  }

  @Test func theColumnRingWrapsAtTwoThousandFortyEight() {
    let m = oneLane()
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 2046, tickSec: 0.1)
    m.specAdvance(step: 2051, tickSec: 0.1)
    #expect(m.specStep[2046] == 2046 && m.specStep[2047] == 2047)
    #expect(m.specStep[0] == 2048 && m.specStep[1] == 2049 && m.specStep[2] == 2050)
    #expect(m.specStep[3] == -1)
    // slot 0 now holds the column of step 2048, a decayed copy of step 2046's
    let d = exp(-1.0)
    #expect(close(Double(m.specCol[0]), Double(m.specCol[2046 * 28]) * d * d))
  }

  @Test func aNewTickSecondsRecomputesDecayAndMean() {
    let m = oneLane(tau: 0.1)
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(Double(m.laneDecay[0]), exp(-1.0)))
    m.specAdvance(step: 1, tickSec: 0.05)
    #expect(close(Double(m.laneDecay[0]), exp(-0.5)))
    #expect(close(Double(m.laneMean[0]), 0.1 / 0.05 * (1 - exp(-0.5))))
    #expect(m.specTickSec == 0.05)
  }

  @Test func lateTablesAreUsedForTheDecayNotTheOldFallback() {
    // The JS keeps a lane's 0.1 s fallback decay if its table arrives after the first advance.
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    m.setLanes(
      [laneOf(10, deck: "A", key: "a"), laneOf(1, deck: "A", key: "b")],
      tables: [table(drum: true, tau: 0.5), nil])
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 0, tickSec: 0.1)
    #expect(close(Double(m.laneDecay[1]), exp(-1.0)), "lane 1 has no table yet: tau 0.1")
    m.setLanes(m.lanes, tables: [table(drum: true, tau: 0.5), table(drum: false, tau: 0.5)])
    m.deposit(lane: 1, note: 60, velocity: 100, durMs: 200, step: 1, tickSec: 0.1)
    #expect(close(Double(m.laneDecay[1]), exp(-0.2)), "now its own tau")
  }

  @Test func finalisingStopsAtTheSoundingStep() {
    let m = oneLane()
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 60, tickSec: 0.1)
    // anchor: step 100 at t = 10 s, tickSec 0.1; now = 10.55 -> step 105.5 -> sounding 105, final 104
    m.finaliseColumns(now: 10.55, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    #expect(m.specCur == 104)
    m.finaliseColumns(now: 10.55, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    #expect(m.specCur == 104, "idempotent")
    m.finaliseColumns(now: 10.99, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    #expect(m.specCur == 108, "floor(109.9) - 1")
    // 64 or more steps ahead is a jump, not a catch-up: left alone
    m.finaliseColumns(now: 20, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    #expect(m.specCur == 108)
    // nothing before the first deposit
    let empty = oneLane()
    empty.finaliseColumns(now: 10.55, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    #expect(empty.specCur == -1)
    // and a non-finite time is ignored, not trapped on
    m.finaliseColumns(now: .nan, anchorStep: 100, anchorTime: 10, tickSec: 0.1)
    m.finaliseColumns(now: 10, anchorStep: 100, anchorTime: 10, tickSec: 0)
    #expect(m.specCur == 108)
  }

  @Test func resetHistoryEmptiesTheBarsAndTheSpectrogramButKeepsTheTables() {
    let m = oneLane()
    m.deposit(lane: 0, note: 60, velocity: 100, durMs: 200, step: 20, tickSec: 0.1)
    m.specAdvance(step: 30, tickSec: 0.1)
    m.resetHistory()
    #expect(m.maxBar == -1 && m.modelFrom == Int.max && m.specCur == -1)
    #expect(m.modelBars.allSatisfy { $0 == 0 } && m.laneState.allSatisfy { $0 == 0 })
    #expect(m.specStep.allSatisfy { $0 == -1 })
    #expect(m.tablesReady)
  }
}

@MainActor
struct ModelAgainstJavaScriptTests {
  @Test func aLongerScenarioMatchesScopeJsStepForStep() {
    let m = ModelEngine(engine: nil, cache: ModelKernelCache())
    let shapes: [(Bool, [Int], Double, Double)] = [
      (true, [36], 2, 0.12), (false, [48, 72], 1, 0.25),
    ]
    var tables: [ModelKernelTable?] = []
    for (drum, notes, base, tau) in shapes {
      tables.append(
        table(drum: drum, notes: notes, tau: tau) { i, j in
          Float(base * Double(i + 1) * Double(1 + j % 7) * 0.5)
        })
    }
    // the oracle indexes its fx by channel (10 and 1); here the lanes sit on decks A and B
    m.setLanes([laneOf(10, deck: "A", key: "a"), laneOf(1, deck: "B", key: "b")], tables: tables)
    m.setFx(deck: "A", rows: [Float](repeating: 0.5, count: 33))
    m.setFx(deck: "B", rows: (0..<33).map { Float(2 - Double($0) * 0.01) })
    let t = 0.125
    m.deposit(lane: 0, note: 36, velocity: 100, durMs: 200, step: 0, tickSec: t)
    m.deposit(lane: 1, note: 48, velocity: 100, durMs: 200, step: 0, tickSec: t)
    m.deposit(lane: 1, note: 60, velocity: 50, durMs: 800, step: 3, tickSec: t)
    m.deposit(lane: 0, note: 36, velocity: 127, durMs: 200, step: 4, tickSec: t)
    m.deposit(lane: 1, note: 72, velocity: 100, durMs: 10, step: 17, tickSec: t)
    m.deposit(lane: 1, note: 48, velocity: 100, durMs: 200, step: 40, tickSec: t)

    #expect(m.laneTables.compactMap { $0?.tau } == ModelOracle.depositTau)
    #expect(m.maxBar == ModelOracle.depositMaxBar && m.modelFrom == ModelOracle.depositModelFrom)
    #expect(m.specCur == ModelOracle.depositSpecCur)
    for (i, want) in ModelOracle.depositBars.enumerated() {
      #expect(close(m.modelBars[i], want, rel: 1e-5), "bars[\(i)] \(m.modelBars[i]) vs \(want)")
    }
    #expect(
      floats(m.laneDecay).enumerated().allSatisfy {
        close($1, ModelOracle.depositDecay[$0], rel: 1e-6)
      })
    #expect(
      floats(m.laneMean).enumerated().allSatisfy {
        close($1, ModelOracle.depositMean[$0], rel: 1e-6)
      })
    for (c, want) in [
      (0, ModelOracle.depositCol0), (1, ModelOracle.depositCol1), (3, ModelOracle.depositCol3),
      (5, ModelOracle.depositCol5), (20, ModelOracle.depositCol20),
    ] {
      for j in 0..<28 {
        #expect(close(Double(m.specCol[c * 28 + j]), want[j], rel: 1e-5), "col \(c) bin \(j)")
      }
    }
    #expect(m.specStep[0..<45].map { Int($0) } == ModelOracle.depositSteps)
    for (i, want) in ModelOracle.depositLaneState.enumerated() {
      #expect(close(Double(m.laneState[i]), want, rel: 1e-5), "laneState[\(i)]")
    }
  }
}
