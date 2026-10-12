import Darwin
import Testing

@testable import DJCore

// Closed forms for the master chain (MasterChain.swift): Tone's Param ramps, the Web Audio
// biquads, Tone's distortion curve, the crusher's quantiser, the equal-power wet, the pitch
// shifter's ratio, and bit-exact bypass. The behaviour of beats' macros on top of it is
// MasterFxParityTests' job.

private let sr = 48_000.0

/// Run `seconds` of `signal(t)` (mono) through `chain`, ops applied before the first sample.
private func run(
  _ chain: MasterChain, seconds: Double, block: Int = 128, _ signal: (Int) -> Float
) -> [Float] {
  let n = Int(seconds * sr)
  var out = [Float](repeating: 0, count: n)
  var buf = [Float](repeating: 0, count: block)
  var i = 0
  while i < n {
    let m = min(block, n - i)
    for k in 0..<m { buf[k] = signal(i + k) }
    buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, nil, from: 0, to: m) }
    chain.finish(frames: m)
    for k in 0..<m { out[i + k] = buf[k] }
    i += m
  }
  return out
}

private func stereo(
  _ chain: MasterChain, seconds: Double, block: Int = 128, _ signal: (Int) -> (Float, Float)
) -> (l: [Float], r: [Float]) {
  let n = Int(seconds * sr)
  var outL = [Float](repeating: 0, count: n)
  var outR = [Float](repeating: 0, count: n)
  var l = [Float](repeating: 0, count: block)
  var r = [Float](repeating: 0, count: block)
  var i = 0
  while i < n {
    let m = min(block, n - i)
    for k in 0..<m { (l[k], r[k]) = signal(i + k) }
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        chain.process(lp.baseAddress!, rp.baseAddress!, from: 0, to: m)
      }
    }
    chain.finish(frames: m)
    for k in 0..<m {
      outL[i + k] = l[k]
      outR[i + k] = r[k]
    }
    i += m
  }
  return (outL, outR)
}

private func sine(_ f: Double, _ amp: Double = 0.5) -> (Int) -> Float {
  { Float(amp * sin(2 * Double.pi * f * Double($0) / sr)) }
}

private func rms(_ x: ArraySlice<Float>) -> Double {
  (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
}

struct ToneParamTests {
  @Test func exponentialRampIsWebAudios() {
    var p = ToneParam(value: 20000, exponentialRamps: true, sampleRate: sr)
    p.cancelScheduledValues(1)
    p.rampTo(500, duration: 0.1, at: 1)
    #expect(p.value(at: 0.5) == 20000)
    #expect(p.value(at: 1) == 20000)
    // V0 (V1/V0)^((t - T0) / (T1 - T0))
    for f in [0.1, 0.25, 0.5, 0.9] {
      let want = 20000 * pow(500.0 / 20000, f)
      #expect(abs(p.value(at: 1 + 0.1 * f) - want) <= 1e-9 * want)
    }
    #expect(p.value(at: 1.1) == 500)
    #expect(p.value(at: 3) == 500)
    #expect(p.isSettled(at: 1.1) && !p.isSettled(at: 1.05))
  }

  @Test func linearRampStartsFromMinOutputNotZero() {
    // Param.js setRampPoint: a ramp point of exactly 0 becomes 1e-7
    var w = ToneParam(value: 0, exponentialRamps: false, sampleRate: sr)
    w.rampTo(1, duration: 0.05, at: 2)
    #expect(w.value(at: 2) == 1e-7)
    #expect(abs(w.value(at: 2.025) - (1e-7 + (1 - 1e-7) * 0.5)) < 1e-15)
    w.rampTo(0, duration: 0.05, at: 3)
    #expect(w.value(at: 3.05) == 0, "a linear ramp TO 0 ends at 0")
  }

  @Test func cancelThenRampJumpsBackToTheCutRampsStart() {
    // tone-engine.js setLowpassFreq: cancelScheduledValues(now) then rampTo(f, 0.1). Cut 50 ms
    // into a 20 kHz → 1 kHz ramp, Tone's timeline (and the native param) restart from 20 kHz.
    var p = ToneParam(value: 20000, exponentialRamps: true, sampleRate: sr)
    p.cancelScheduledValues(1)
    p.rampTo(1000, duration: 0.1, at: 1)
    let mid = p.value(at: 1.05)
    #expect(abs(mid - 20000 * pow(0.05, 0.5)) < 1e-6)
    p.cancelScheduledValues(1.05)
    p.rampTo(200, duration: 0.1, at: 1.05)
    #expect(p.value(at: 1.05) == 20000)
    #expect(abs(p.value(at: 1.1) - 20000 * pow(0.01, 0.5)) < 1e-6)
  }

  @Test func rampWithoutCancelHoldsTheCurrentValue() {
    // phaser frequency: rampTo with no cancel → cancelAndHold at the current value
    var p = ToneParam(value: 1, exponentialRamps: true, sampleRate: sr)
    p.rampTo(4, duration: 0.1, at: 1)
    let at = p.value(at: 1.05)
    p.rampTo(0.1, duration: 0.1, at: 1.05)
    #expect(abs(p.value(at: 1.05) - at) < 1e-12)
    #expect(abs(p.value(at: 1.1) - at * pow(0.1 / at, 0.5)) < 1e-12)
  }

  @Test func pruningKeepsWhatTheFutureNeeds() {
    var p = ToneParam(value: 20000, exponentialRamps: true, sampleRate: sr)
    var t = 1.0
    for i in 0..<500 {
      p.cancelScheduledValues(t)
      p.rampTo(i % 2 == 0 ? 500 : 5000, duration: 0.1, at: t)
      let before = p.value(at: t + 0.05)
      p.prune(before: t + 0.05)
      #expect(p.value(at: t + 0.05) == before)
      #expect(p.count <= 6)
      t += 0.12
    }
  }
}

struct MasterChainTests {
  @Test func aNeutralChainIsBitTransparent() {
    let chain = MasterChain(sampleRate: sr)
    var seed: UInt64 = 7
    let sig: (Int) -> Float = { _ in
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000
    }
    var copy: [Float] = []
    var seed2: UInt64 = 7
    for _ in 0..<Int(0.5 * sr) {
      seed2 = seed2 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      copy.append(Float(Int64(bitPattern: seed2 >> 11) % 2_000_000) / 1_000_000)
    }
    #expect(chain.isIdle())
    #expect(run(chain, seconds: 0.5, sig) == copy)
  }

  @Test func filtersMatchTheWebAudioResponseCubed() {
    // Tone.Filter rolloff -48 = 3 cascaded Web Audio biquads, Q 1 dB: the steady-state gain on
    // a sine is |H(f)|³
    for (key, slider, kind) in [
      (MasterFxKey.lpFreq, 50, ModelPassKind.lowpass), (.hpFreq, 60, .highpass),
    ] {
      let fc =
        key == .lpFreq ? MasterParams.lpFreq(Double(slider)) : MasterParams.hpFreq(Double(slider))
      for f in [200.0, 700, 1414, 3000, 6000] {
        let chain = MasterChain(sampleRate: sr)
        chain.apply(key, slider, at: 0)
        let y = run(chain, seconds: 0.6, sine(f))
        let x = (0..<y.count).map { sine(f)($0) }
        let got = rms(y[Int(0.4 * sr)...]) / rms(x[Int(0.4 * sr)...])
        let h2 = BiquadCoefficients.pass(kind, fc: fc, qDb: 1, sampleRate: sr)!
          .magnitude2(at: f, sampleRate: sr)
        let want = pow(h2, Double(MasterChain.filterStages) / 2)  // |H|³
        #expect(
          abs(got - want) <= 2e-3 * max(want, 1e-3),
          "\(key) \(slider) at \(f) Hz: \(got) vs \(want)")
      }
    }
  }

  @Test func distortionCurveIsTonesOver1024Points() {
    let chain = MasterChain(sampleRate: sr)
    chain.apply(.distortion, 20, at: 0)
    let k = 20.0
    let deg = Double.pi / 180
    func tone(_ x: Double) -> Double {
      abs(x) < 0.001 ? 0 : Double(Float(((3 + k) * x * 20 * deg) / (Double.pi + k * abs(x))))
    }
    // grid points are the curve, in between is linear interpolation, beyond ±1 the ends
    for i in [0, 1, 300, 511, 512, 700, 1022, 1023] {
      let x = Double(i) / 1023 * 2 - 1
      #expect(abs(chain.shape(Float(x)) - tone(x)) < 1e-6, "point \(i)")
    }
    let i = 800
    let xa = Double(i) / 1023 * 2 - 1
    let xb = Double(i + 1) / 1023 * 2 - 1
    let mid = Float((xa + xb) / 2)
    #expect(abs(chain.shape(mid) - (tone(xa) + tone(xb)) / 2) < 1e-6)
    #expect(chain.shape(1.5) == tone(1))
    #expect(chain.shape(-3) == tone(-1))
    // fully wet once the 50 ms ramp is over: y = curve(x)
    let y = run(chain, seconds: 0.2, sine(330, 0.8))
    for n in [Int(0.1 * sr), Int(0.15 * sr) + 17] {
      #expect(abs(Double(y[n]) - chain.shape(sine(330, 0.8)(n))) < 1e-6)
    }
  }

  @Test func crusherQuantisesToTheBitStep() {
    // slider 80 → amount 0.8 → bits max(1, round(16 − 12)) = 4 → step 1/8
    let chain = MasterChain(sampleRate: sr)
    chain.apply(.crushBits, 80, at: 0)
    let y = run(chain, seconds: 0.2, sine(97, 0.9))
    let step = pow(0.5, 3.0)
    for n in stride(from: Int(0.1 * sr), to: y.count, by: 37) {
      let x = Double(sine(97, 0.9)(n))
      let want = step * (x / step + 0.5).rounded(.down)
      #expect(abs(Double(y[n]) - want) < 1e-6, "sample \(n): \(y[n]) vs \(want)")
    }
  }

  @Test func wetIsEqualPower() {
    // crusher at 1 bit (step 1): a small signal crushes to 0, so the output is the dry part,
    // x·cos(w·π/2), along the wet's linear ramp 1e-7 → 1 over 50 ms
    let chain = MasterChain(sampleRate: sr)
    chain.apply(.crushBits, 100, at: 0)  // bits max(1, round(16 − 15)) = 1
    let y = run(chain, seconds: 0.06) { _ in 0.25 }
    for n in [0, 300, 1200, 1800, 2399] {
      let t = Double(n) / sr
      let w = 1e-7 + (1 - 1e-7) * (t / 0.05)
      #expect(abs(Double(y[n]) - 0.25 * cos(w * Double.pi / 2)) < 1e-6, "sample \(n)")
    }
    #expect(abs(y[2500]) < 1e-6)
  }

  @Test func phaserAllpassesKeepTheLevel() {
    // fully wet (slider 100: wet 1), the phaser is ten allpasses: the level of a tone is kept
    let chain = MasterChain(sampleRate: sr)
    chain.apply(.phaserWet, 100, at: 0)
    chain.apply(.phaserDepth, 100, at: 0)
    let (l, r) = stereo(chain, seconds: 1) { n in (sine(523)(n), sine(523)(n)) }
    let ref = rms((0..<Int(sr)).map { sine(523)($0) }[Int(0.2 * sr)...])
    #expect(abs(rms(l[Int(0.2 * sr)...]) / ref - 1) < 0.01)
    #expect(abs(rms(r[Int(0.2 * sr)...]) / ref - 1) < 0.01)
    // the two channels' LFOs are half a cycle apart: the outputs differ
    #expect(zip(l, r).contains { abs($0 - $1) > 0.01 })
  }

  @Test func pitchShiftMovesASineByTonesRatio() {
    // A tap reads x(t − d(t)) with d a sawtooth: the tone comes out at 440·(1 − d′) during each
    // grain, and as the two taps' grains repeat at the LFO rate Ω the spectrum is lines at
    // 440 + 2kΩ (signed: a rising delay plays backwards). The strongest line is the one nearest
    // the grain frequency. d′ = ∓1.2·factor / sawPeak (Chrome's table normalisation), so this
    // pins both the rate (the line spacing) and the slope (which line wins).
    for p in [12.0, 7, -12] {
      let factor = p < 0 ? pow(2, (p - 1) / 12) + 1 : pow(2, p / 12) - 1
      let omega = factor * 1.2 / MasterChain.window
      let slope = (p < 0 ? 1 : -1) * 1.2 * factor / MasterChain.sawPeak
      let grain = 440 * (1 - slope)  // signed
      let chain = MasterChain(sampleRate: sr)
      chain.apply(.masterPitch, Int(p), at: 0)
      let y = Array(run(chain, seconds: 1, sine(440))[Int(0.1 * sr)...])
      func level(_ f: Double) -> Double {
        var re = 0.0
        var im = 0.0
        let w = 2 * Double.pi * abs(f) / sr
        for (i, v) in y.enumerated() {
          let h = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(y.count))
          re += Double(v) * h * cos(w * Double(i))
          im -= Double(v) * h * sin(w * Double(i))
        }
        return (re * re + im * im).squareRoot()
      }
      var lines: [Double] = []
      for k in -12...12 {
        let f: Double = 440 + 2 * Double(k) * omega
        if abs(f) > 60 && abs(f) < 1500 { lines.append(f) }
      }
      let levels = lines.map { level($0) }
      let nearest = lines.min { abs($0 - grain) < abs($1 - grain) }!
      let loudest = lines[levels.indices.max { levels[$0] < levels[$1] }!]
      #expect(
        loudest == nearest,
        "pitch \(p): loudest line \(abs(loudest)) Hz, want \(abs(nearest)) (grain \(abs(grain)))")
      // and the lines are the spectrum: off-grid frequencies are far below them
      #expect(level(nearest + omega) < 0.2 * level(nearest), "pitch \(p)")
    }
  }

  @Test func stagesFadeInAndOutOfBypass() {
    // HP engages over 5 ms (no step at the first sample), then settles back to bypass:
    // bit-transparent again once its 100 ms ramp home and the 5 ms fade are over
    let chain = MasterChain(sampleRate: sr)
    chain.apply(.hpFreq, 50, at: 0)
    let y1 = run(chain, seconds: 0.3, sine(1000))
    #expect(abs(y1[0] - sine(1000)(0)) < 1e-6)
    #expect(!chain.isIdle())
    chain.apply(.hpFreq, 0, at: chain.time(at: 0))
    _ = run(chain, seconds: 0.2) { sine(1000)($0 + Int(0.3 * sr)) }
    #expect(chain.isIdle())
    let x = (0..<4800).map { sine(1000)($0 + Int(0.5 * sr)) }
    #expect(run(chain, seconds: 0.1) { sine(1000)($0 + Int(0.5 * sr)) } == x)
  }

  @Test func silenceDecaysToExactZero() {
    // an impulse through every stage, then a long silence: no denormal tail survives
    let chain = MasterChain(sampleRate: sr)
    for (k, v) in [(MasterFxKey.hpFreq, 40), (.lpFreq, 30), (.phaserWet, 100), (.masterPitch, 5)] {
      chain.apply(k, v, at: 0)
    }
    let y = run(chain, seconds: 4) { $0 == 100 ? 1 : 0 }
    #expect(!y.contains { $0.isSubnormal })
    #expect(y[(y.count - 4800)...].allSatisfy { $0 == 0 })
  }
}
