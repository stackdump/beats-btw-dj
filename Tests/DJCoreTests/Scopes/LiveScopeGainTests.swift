import Darwin
import Testing

@testable import DJCore

// The 095d030 auto-gain (scope.js drawLive). The expected numbers were produced by running the
// pinned statements themselves in node:
//
//   s.peak = Math.max(0.05, s.peak * Math.exp(-dt / 7));
//   const a = 120 * (s.peak - s.disp) - 9 * s.vel;  s.vel += a * dt;
//   s.disp = Math.max(0.05, s.disp + s.vel * dt);
//
// from peak = disp = 0.1 after an attack to 1.0, dt = 1/60 (frame i is the (i+1)-th step).
struct LiveScopeGainTests {
  private let dt = 1.0 / 60

  private func stepResponse(frames: Int) -> [LiveScopeGain] {
    var g = LiveScopeGain()
    g.attack(1.0)
    var out: [LiveScopeGain] = []
    for _ in 0..<frames {
      g.step(dt: dt)
      out.append(g)
    }
    return out
  }

  @Test func theConstantsAreTheSpecs() {
    #expect(LiveScopeGain.springK == 120 && LiveScopeGain.springC == 9)
    #expect(LiveScopeGain.releaseSeconds == 7 && LiveScopeGain.floor == 0.05)
    #expect(LiveScopeGain.maxDt == 0.05 && LiveScopeGain.initial == 0.1)
    let g = LiveScopeGain()
    #expect(g.peak == 0.1 && g.disp == 0.1 && g.vel == 0)
  }

  @Test func theStepResponseFollowsThePinnedTrajectory() {
    let r = stepResponse(frames: 600)
    func near(_ i: Int, _ peak: Double, _ disp: Double, _ vel: Double) {
      #expect(abs(r[i].peak - peak) < 1e-12, "peak at frame \(i): \(r[i].peak)")
      #expect(abs(r[i].disp - disp) < 1e-12, "disp at frame \(i): \(r[i].disp)")
      #expect(abs(r[i].vel - vel) < 1e-12, "vel at frame \(i): \(r[i].vel)")
    }
    near(0, 0.9976218798379292, 0.12992072932793097, 1.7952437596758584)
    near(1, 0.9952494151313636, 0.18419763878345338, 3.2566145673313445)
    near(2, 0.9928825924309505, 0.25728917694223064, 4.385492289526637)
    near(9, 0.9764716866522437, 0.9033499268693493, 4.873405920630859)
    near(19, 0.9534969548334776, 1.1509810088982888, -0.8321224048010889)
    near(29, 0.9310627797040242, 0.9295519576309188, -1.029147929655779)
    near(59, 0.8668778997501839, 0.8802734554363524, -0.1942389359056367)
    near(119, 0.7514772930752898, 0.7576830167131231, -0.10772336548266283)
    near(299, 0.4895416595569594, 0.49358827358664437, -0.07059662046882652)
    near(599, 0.23965103644178196, 0.24163202259578906, -0.034559986885834136)
  }

  @Test func theDisplayedScaleOvershootsAboutAQuarterAndSettles() {
    let r = stepResponse(frames: 600)
    let top = r.enumerated().max { $0.element.disp < $1.element.disp }!
    #expect(top.offset == 16, "the first peak of the bounce is the 17th frame")
    #expect(abs(top.element.disp - 1.1738079232957304) < 1e-12)
    // against the step 0.1 -> 1.0: (1.1738 - 1) / 0.9 = 19.3 %
    let ofStep = (top.element.disp - 1.0) / 0.9
    #expect(ofStep > 0.19 && ofStep < 0.25, "overshoot of the step \(ofStep)")
    // against the target it is chasing at that frame (the peak has released a little): 24.8 %
    let ofTarget = (top.element.disp - top.element.peak) / (top.element.peak - 0.1)
    #expect(ofTarget > 0.19 && ofTarget < 0.25, "overshoot of the moving target \(ofTarget)")
    // the analytic value for k = 120, c = 9: zeta = c / (2 sqrt k) = 0.411, exp(-pi z / sqrt(1 - z^2))
    let z = 9 / (2 * 120.0.squareRoot())
    let analytic = exp(-Double.pi * z / (1 - z * z).squareRoot())
    #expect(abs(z - 0.41079191812887456) < 1e-12 && abs(analytic - 0.24280729855561348) < 1e-12)
    #expect(abs(ofTarget - analytic) < 0.01, "the discrete spring is within 1 % of the analytic")
    // it bounces (one undershoot below the target) and settles on the releasing peak
    #expect(r[29].disp < r[29].peak, "the undershoot")
    #expect(abs(r[599].disp - r[599].peak) < 0.01 && abs(r[599].vel) < 0.1)
  }

  @Test func theWaveformIsNotClippedSoTheScaleOvershootsTheSignal() {
    // scale = (hTop/2 - 3) / disp: while disp is above the peak the waveform is drawn SMALLER,
    // while it is below (the first frames after a loud block) it is drawn larger than the band
    var g = LiveScopeGain()
    g.attack(1.0)
    #expect(abs(g.scale(hTop: 144) - 69 / 0.1) < 1e-9, "disp 0.1, signal 1.0: 10x too big")
    g.step(dt: dt)
    #expect(abs(g.scale(hTop: 144) - 69 / 0.12992072932793097) < 1e-9)
    #expect(abs(LiveScopeGain(peak: 1, disp: 1).scale(hTop: 144) - 69) < 1e-12)
    #expect(abs(LiveScopeGain(peak: 1, disp: 0.5).scale(hTop: 100) - 94) < 1e-12)
  }

  @Test func attackIsInstantAndOnlyEverRaises() {
    var g = LiveScopeGain()
    g.attack(0.9)
    #expect(g.peak == 0.9, "no smoothing")
    g.attack(0.3)
    #expect(g.peak == 0.9, "a smaller block changes nothing")
    g.attack(.nan)
    #expect(g.peak == 0.9, "and neither does a NaN")
    g.attack(-1)
    #expect(g.peak == 0.9)
  }

  @Test func theReleaseIsSevenSecondsAndFloorsAtFiveHundredths() {
    var g = LiveScopeGain(peak: 1.0, disp: 1.0)
    for _ in 0..<140 { g.step(dt: 0.05) }  // 7 s
    #expect(abs(g.peak - 0.3678794411714421) < 1e-12, "exp(-1): \(g.peak)")
    #expect(abs(g.peak - exp(-1.0)) < 1e-12)
    var q = LiveScopeGain()
    for _ in 0..<100_000 { q.step(dt: 0.05) }
    #expect(q.peak == 0.05 && q.disp == 0.05, "both floor at 0.05")
    // the release alone does not need the spring to be quiet: from peak 0.1 one frame
    var r = LiveScopeGain()
    r.step(dt: 0.05)
    #expect(abs(r.peak - max(0.05, 0.1 * exp(-0.05 / 7))) < 1e-15)
  }

  @Test func theFrameStepIsClampedToFiftyMilliseconds() {
    var a = LiveScopeGain()
    a.attack(1)
    var b = a
    a.step(dt: 10)
    b.step(dt: 0.05)
    #expect(a == b, "a long stall steps like 50 ms")
    // pinned: one 50 ms step from peak 1, disp 0.1
    #expect(abs(a.peak - 0.9928825924309503) < 1e-12)
    #expect(abs(a.disp - 0.36786477772928516) < 1e-12)
    #expect(abs(a.vel - 5.357295554585702) < 1e-12)
    var z = LiveScopeGain()
    z.attack(1)
    var n = z
    var inf = z
    z.step(dt: 0)
    n.step(dt: -1)
    inf.step(dt: .infinity)
    #expect(z.disp == 0.1 && z.vel == 0, "no time, no movement")
    #expect(n == z, "time never runs backwards")
    #expect(inf == b, "infinity clamps like any long stall")
    var nan = LiveScopeGain()
    nan.step(dt: .nan)
    #expect(nan == LiveScopeGain(), "a NaN step is no step")
  }
}
