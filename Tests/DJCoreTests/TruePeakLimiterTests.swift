import Darwin
import Testing

@testable import DJCore

// The net deck's limiter holds a true-peak ceiling (PeakLimiter.swift): BS.1770's 4× FIR finds
// the peaks between samples, the lookahead grows by the FIR's reach, and the delay that adds is
// fixed and small. Measured with the same `TruePeak` that `djctl measure` prints.

struct TruePeakLimiterTests {
  let sr = 48_000.0

  private func run(_ lim: PeakLimiter, _ l: inout [Float], _ r: inout [Float]) {
    let n = l.count
    var done = 0
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        while done < n {
          let k = min(512, n - done)
          lim.process(lp.baseAddress! + done, rp.baseAddress! + done, frames: k)
          done += k
        }
      }
    }
  }

  /// An fs/4 sine at 45°: every sample sits 3 dB under the wave's crest, so a sample-peak
  /// limiter at −1 dBFS lets +2 dBTP through. This one brings it to the ceiling.
  @Test func interSamplePeaksAreHeldUnderTheCeiling() {
    let n = 48_000
    // samples at ±0.85 (−1.4 dBFS, under a sample ceiling), true peak 1.2 (+1.6 dBTP)
    let x = (0..<n).map { Float(1.2 * sin(Double.pi / 2 * Double($0) + Double.pi / 4)) }
    #expect(TruePeak.dbtp(left: x, right: nil) > 1)
    #expect((x.map(abs).max() ?? 0) < Float(pow(10, PeakLimiter.ceilingDB / 20)))
    let lim = PeakLimiter(sampleRate: sr)
    var l = x
    var r = x
    run(lim, &l, &r)
    let tp = TruePeak.dbtp(left: l, right: r)
    #expect(tp <= PeakLimiter.ceilingDB, "output \(tp) dBTP")
    #expect(tp > PeakLimiter.ceilingDB - 0.5, "held \(tp) dBTP: no deeper than it needs")
    let st = lim.statistics()
    #expect(st.truePeakDBTP <= PeakLimiter.ceilingDB)
    #expect(abs(st.truePeakDBTP - tp) < 0.05, "meter \(st.truePeakDBTP), offline \(tp)")
    #expect(lim.gainReductionDB > 2)
  }

  /// Hot, transient-heavy material in both channels — clicks, a square-ish bass, noise bursts —
  /// never crosses the ceiling between samples either.
  @Test(arguments: [0.0, 6.0, 12.0])
  func hotMaterialStaysUnderTheCeiling(driveDB: Double) {
    let n = 96_000
    let gain = pow(10, driveDB / 20)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func noise() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(Int64(bitPattern: seed >> 1) % 2_000_000) / 1_000_000 - 1
    }
    var l = [Float](repeating: 0, count: n)
    var r = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let t = Double(i) / sr
      let bass = tanh(4 * sin(2 * Double.pi * 55 * t)) * 0.6
      let click = i % 6000 < 3 ? (i % 2 == 0 ? 1.0 : -1.0) : 0
      let burst = (i / 4800) % 4 == 1 ? noise() * 0.7 : 0
      let hat = sin(2 * Double.pi * 11_900 * t) * ((i % 3000) < 400 ? 0.5 : 0)
      l[i] = Float(gain * (bass + click + burst + hat))
      r[i] = Float(gain * (bass - click + 0.5 * burst - hat))
    }
    let lim = PeakLimiter(sampleRate: sr)
    run(lim, &l, &r)
    let tp = TruePeak.dbtp(left: l, right: r)
    #expect(tp <= PeakLimiter.ceilingDB, "drive \(driveDB) dB: \(tp) dBTP")
    #expect(lim.statistics().truePeakDBTP <= PeakLimiter.ceilingDB)
  }

  /// The delay is the lookahead plus the FIR's reach on both sides, fixed: an impulse under the
  /// ceiling comes out exactly `lookahead` samples late and unchanged, and that is under 2 ms
  /// (a net deck's audio against its transport and a sample deck's: well under a flam).
  @Test func theDelayIsFixedAndSmall() {
    for rate in [44_100.0, 48_000.0, 96_000.0] {
      let lim = PeakLimiter(sampleRate: rate)
      let window = Int((PeakLimiter.lookaheadSeconds * rate).rounded())
      #expect(lim.lookahead == window + 2 * TruePeak.delay)
      #expect(lim.latencySeconds < 0.002, "\(rate): \(lim.latencySeconds) s")
      var l = [Float](repeating: 0, count: 1024)
      l[100] = 0.25
      var r = l
      run(lim, &l, &r)
      #expect(l.firstIndex { $0 != 0 } == 100 + lim.lookahead)
      #expect(l[100 + lim.lookahead] == 0.25)
      #expect(lim.statistics().limitedShare == 0)
    }
  }

  /// The gain dips into a peak and out of it without a step: the change between neighbouring
  /// samples stays small even for a peak 12 dB over.
  @Test func theGainMovesSmoothly() {
    let n = 24_000
    var l = (0..<n).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / sr)) }
    for i in 12_000..<12_048 { l[i] *= 16 }  // a 1 ms burst, +12 dB over the ceiling
    let ref = l
    var r = l
    let lim = PeakLimiter(sampleRate: sr)
    run(lim, &l, &r)
    var biggest = 0.0
    var last = 1.0
    for i in lim.lookahead..<n {
      let x = Double(ref[i - lim.lookahead])
      guard abs(x) > 0.05 else { continue }
      let g = Double(l[i]) / x
      if i > lim.lookahead { biggest = max(biggest, abs(g - last)) }
      last = g
    }
    #expect(biggest < 0.2, "largest gain step \(biggest)")
    #expect(TruePeak.dbtp(left: l, right: r) <= PeakLimiter.ceilingDB)
  }

  /// Whole songs on the app's path, synth voices and sampled ones (what this Mac has
  /// installed): true peak ≤ −1 dBTP after the limiter, and it works rarely (P95 GR ≤ 2 dB).
  @Test(
    arguments: [
      "techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz",
      "ambient", "trap", "funk",
    ], [false, true])
  func everyGenreReadsUnderTheCeiling(genre: String, sampled: Bool) throws {
    let rate = 24_000.0
    let source = WaveDeckSource(sampleRate: rate, opts: .extended)
    let opts = WaveOptions.extended(samplers: sampled ? source.samplers : nil)
    let track = PreparedTrack(
      spec: TrackSpec(genre: genre, seed: 4242, structure: "standard"), sampleRate: rate,
      opts: opts)
    let r = OfflineRender(track: track, source: source, seconds: 240)
    let st = try #require(source.limiter).statistics()
    let path = sampled ? "sampled" : "synth"
    #expect(st.truePeakDBTP <= PeakLimiter.ceilingDB, "\(genre) \(path): \(st.truePeakDBTP) dBTP")
    #expect(st.percentilesDB[1] <= 2, "\(genre) \(path): GR P95 \(st.percentilesDB[1]) dB")
    // the deck after the limiter (EQ flat, fader up) reads the same
    let tp = TruePeak.dbtp(left: r.left, right: r.right)
    #expect(tp <= PeakLimiter.ceilingDB + 0.01, "\(genre) \(path): rendered \(tp) dBTP")
  }

  /// `djctl render`'s `limiter` block carries the true peak and the GR percentiles.
  @Test func theReportCarriesTruePeakAndP95() {
    let lim = PeakLimiter(sampleRate: sr)
    var l = (0..<4800).map { Float(2 * sin(Double($0) * 0.1)) }
    var r = l
    run(lim, &l, &r)
    let d = lim.statistics().dictionary
    #expect((d["truePeakDBTP"] as? Double).map { $0 <= PeakLimiter.ceilingDB } == true)
    #expect(d["grP95DB"] is Double)
    lim.resetStatistics()
    #expect(lim.statistics() == GainReductionStats())
  }
}
