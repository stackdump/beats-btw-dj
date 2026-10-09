import Testing

@testable import DJCore

// The Scope/Live auto-gain and the Bands residual against what beats' scope.js computes (095d030),
// run in node by scripts/scope-live-oracle.mjs on the inputs below and checked in as
// LiveBandsOracleData.swift (regenerate: `node scripts/scope-live-oracle.mjs --swift > …` and
// `make fmt`). LiveScopeGainTests and BandsModelTests pin hand-picked literals; these replay whole
// scripts (stalls past the 50 ms clamp, attacks between frames, the 6 dB floor and the 24 dB
// ceiling of the residual scale, exact ties of the colour index) so a drift anywhere shows.

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
  abs(a - b) <= tol * max(1, abs(b))
}

struct LiveGainOracleTests {
  @Test func everyScriptedFrameOfTheGainMatchesScopeJs() {
    #expect(LiveBandsOracle.gain.map(\.name) == ["step", "release", "stall", "floor"])
    for run in LiveBandsOracle.gain {
      var g = LiveScopeGain(peak: run.start[0], disp: run.start[1], vel: run.start[2])
      let attacks = Dictionary(uniqueKeysWithValues: run.attacks.map { (Int($0[0]), $0[1]) })
      var next = 0
      for (i, dt) in run.dts.enumerated() {
        if let pk = attacks[i] { g.attack(pk) }
        g.step(dt: dt)
        guard next < run.samples.count, Int(run.samples[next][0]) == i else { continue }
        let want = run.samples[next]
        next += 1
        #expect(close(g.peak, want[1]), "\(run.name) frame \(i): peak \(g.peak) vs \(want[1])")
        #expect(close(g.disp, want[2]), "\(run.name) frame \(i): disp \(g.disp) vs \(want[2])")
        #expect(close(g.vel, want[3]), "\(run.name) frame \(i): vel \(g.vel) vs \(want[3])")
      }
      #expect(next == run.samples.count, "\(run.name): every sampled frame was compared")
    }
  }

  @Test func theScriptsReachTheRegimesTheyAreThereFor() {
    func run(_ name: String) -> GainOracleRun { LiveBandsOracle.gain.first { $0.name == name }! }
    // the step bounces: disp passes the peak it chases and comes back under it
    let step = run("step").samples
    #expect(step.contains { $0[2] > $0[1] * 1.1 } && step.contains { $0[2] < $0[1] })
    // the release floors at 0.05, both of them
    let release = run("release").samples
    #expect(release.last![1] == 0.05 && release.last![2] == 0.05)
    // the stall script has frames past the clamp and frames of no time at all
    let stall = run("stall")
    #expect(stall.dts.contains { $0 > 0.05 } && stall.dts.contains { $0 == 0 })
    #expect(stall.attacks.count >= 10)
  }
}

@MainActor
struct BandsResidualOracleTests {
  private func kind(_ name: String) -> BandsOracleData.Kind {
    switch name {
    case "same": .same
    case "inverted": .inverted
    default: .main
    }
  }

  @Test func theResidualItsScaleAndItsColourIndexMatchScopeJs() {
    for run in LiveBandsOracle.residual {
      let tag = "\(run.kind) from \(run.measFrom)"
      let d = BandsOracleData.make(
        kind(run.kind), modelFrom: run.modelFrom, measFrom: run.measFrom, measAt: run.measAt)
      let ag = d.agreement()
      // the scale: 6 dB, or the largest |D| over the bars on screen, at most 24
      for l in run.limits {
        let got = d.residualLimit(bars: Int(l[0])..<Int(l[1]), agreement: ag)
        #expect(close(got, l[2]), "\(tag): bars \(Int(l[0]))..<\(Int(l[1])): \(got) vs \(l[2])")
      }
      let lim = run.limits[0][2]
      var seen = 0
      for c in run.cells {
        let bar = Int(c[0])
        let row = Int(c[1])
        let got = d.residual(bar: bar, row: row, agreement: ag)
        if c[2].isNaN {
          #expect(got == nil, "\(tag): bar \(bar) row \(row) has no residual")
          continue
        }
        seen += 1
        guard let got else {
          Issue.record("\(tag): bar \(bar) row \(row): nil, JS has \(c[2])")
          continue
        }
        #expect(close(got, c[2]), "\(tag): D(\(bar), \(row)) \(got) vs \(c[2])")
        #expect(
          BandsModel.residualIndex(got, limit: lim) == Int(c[3]),
          "\(tag): index of D(\(bar), \(row))")
      }
      #expect(seen > 20, "\(tag): the run has residual cells to compare (\(seen))")
    }
  }

  @Test func theScaleIsClampedAtBothEndsInTheOracleRuns() {
    func limit(_ kind: String, _ measFrom: Double = 5) -> Double {
      LiveBandsOracle.residual.first { $0.kind == kind && $0.measFrom == measFrom }!.limits[0][2]
    }
    #expect(limit("inverted") == 24, "a mirrored shape hits the ceiling")
    #expect(limit("main") > 6 && limit("main") < 24, "an imperfect agreement sits between")
    let main = LiveBandsOracle.residual[0]
    #expect(main.limits[2][2] == 6 && main.limits[3][2] == 6, "one bar or none: the 6 dB floor")
  }

  @Test func theColourIndexRoundsHalfUpLikeMathRoundAndClamps() {
    #expect(LiveBandsOracle.ties.count == 37)
    for t in LiveBandsOracle.ties {
      #expect(BandsModel.residualIndex(t[0], limit: t[1]) == Int(t[2]), "D \(t[0]) / \(t[1])")
    }
    #expect(
      LiveBandsOracle.ties.contains { $0[2] == 0 } && LiveBandsOracle.ties.contains { $0[2] == 32 })
  }
}
