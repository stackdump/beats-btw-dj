// dj's `vinyl-brake` on a net deck (`WaveOptions.turntableBrake`, on in `.extended`): the deck's
// platter spins down to a stop, then the record drops back in where it would have been.
//
// beats' catalog makes vinyl-brake a compound of tape-stop (0 ms) and octave-down (60 ms), but
// beats' `runCompound` skips tempo-sweep steps, so all it plays is an octave-down hold: an instant
// grainy octave drop for a bar. dj keeps that on the parity path (`FxAutomation`, what
// `WaveOptions()` and the fixtures run) and plays a real brake here (GO-DIVERGENCE.md §5).
//
// Varispeed on the whole deck: while braking, the runner renders its net in *source time* at rate
// r(t) ≤ 1. Each output frame moves a read head r source frames on; the runner renders just the
// source frames the head reaches (at most one per output frame), and a 4-point cubic (Catmull-Rom)
// reads between them. The net's tick clock counts source frames, so tempo and pitch fall together
// for everything the runner plays: synth voices, drums, the samplers it renders in the deck's
// callback, its room and echo. The master chain runs after this, on the output (real time): it
// is the mixer's insert, not the record's — a filter sweep fired with the brake keeps its time.
//
// The curve, from the frame the macro is applied (block start; sample-accurate from there, so a
// session replays it exactly): the macro's duration D (bars × 16 ticks at the tempo when fired;
// default 1 bar, the catalog's options 1 or 2) is three quarters spin-down and a quarter stopped.
// The spin-down is a constant deceleration (a deck's motor brake: constant friction torque),
// r = 1 − t / (0.75 D), with the level following r over its last tenth (a stopping record falls
// below hearing; holding the last sample would leave DC). Then silence until D.
//
// Release (at D, or 5 ms after a panic, faded down over them): the runner's tick clock is put on
// by the ticks a deck that never braked would have run since the fire (`WaveRunner.catchUp`: the
// deficit, accumulated per chunk at the tempo in effect), so the deck lands on the beat and bar
// it would be on — still locked with the other deck, the loops and the grid — and comes in over
// a 5 ms fade. A transport stop or a hand on the platter (freeze) cancels the brake where it is.
//
// Real-time: buffers are allocated in `init`; nothing on the render path allocates or locks
// (`turntableBrakeDoesNotAllocate`). A chunk takes at most `maxChunk` output frames, so the runner
// never gets a block bigger than its scratch (4096, as the sampler bank's).

final class TurntableBrake {
  /// Output frames per braked chunk: with the onset's three look-ahead pulls the runner is
  /// asked for at most 4095 source frames (its own scratch and the samplers' hold 4096).
  static let maxChunk = 4092
  /// The share of the duration spent spinning down (the rest is the stop).
  static let spinDown = 0.75
  /// Below this rate the level follows the rate down to 0.
  static let tailRate = 0.1

  let sampleRate: Double
  let fadeFrames: Int
  private let srcL: UnsafeMutablePointer<Float>
  private let srcR: UnsafeMutablePointer<Float>

  /// Braking (or stopped, waiting for the release).
  private(set) var isOn = false
  /// Output frames since the fire, counted while the transport runs.
  private(set) var elapsed = 0
  /// Frames from the fire to the stop (r = 0) and to the release.
  private(set) var stopFrames = 1.0
  private(set) var releaseFrame = 0
  /// Ticks a deck that never braked would be ahead of this one's source clock.
  private(set) var deficitTicks = 0.0
  // The read head: between window samples 1 and 2, `phase` of the way.
  private var phase = 0.0
  private var l0: Float = 0, l1: Float = 0, l2: Float = 0, l3: Float = 0
  private var r0: Float = 0, r1: Float = 0, r2: Float = 0, r3: Float = 0
  /// Window samples still to pull before the first output (the onset's look-ahead).
  private var fill = 0
  /// > 0: a panic is releasing the brake, the output fading out over these frames.
  private var panicLeft = 0
  /// > 0: the direct output fading in after a release.
  private var fadeInLeft = 0
  // The last frame the direct path played (before the master chain): the window's first sample.
  private var lastL: Float = 0
  private var lastR: Float = 0

  init(sampleRate: Double) {
    self.sampleRate = sampleRate
    fadeFrames = max(1, Int((0.005 * sampleRate).rounded()))
    srcL = .allocate(capacity: Self.maxChunk + 4)
    srcR = .allocate(capacity: Self.maxChunk + 4)
    srcL.initialize(repeating: 0, count: Self.maxChunk + 4)
    srcR.initialize(repeating: 0, count: Self.maxChunk + 4)
  }

  deinit {
    srcL.deallocate()
    srcR.deallocate()
  }

  /// The rate `e` output frames after the fire (1 → 0, then 0).
  @inline(__always)
  func rate(at e: Int) -> Double { max(0, 1 - Double(e) / stopFrames) }

  /// The level at rate `r`.
  @inline(__always)
  static func level(_ r: Double) -> Double { min(1, r / tailRate) }

  /// Start a brake lasting `durationFrames` (spin-down and stop) from the next frame. False
  /// (nothing changes) while one is already running.
  @discardableResult
  func start(durationFrames: Int) -> Bool {
    guard !isOn else { return false }
    isOn = true
    elapsed = 0
    releaseFrame = max(1, durationFrames)
    stopFrames = max(1, Self.spinDown * Double(releaseFrame))
    deficitTicks = 0
    phase = 0
    l0 = lastL
    r0 = lastR
    fill = 3
    panicLeft = 0
    fadeInLeft = 0
    return true
  }

  /// Release now: fade out over 5 ms, then drop back in time.
  func panic() {
    if isOn && panicLeft == 0 { panicLeft = fadeFrames }
  }

  /// Drop the brake where it is, without putting the clock on (a transport stop, a scratch).
  func cancel() {
    guard isOn else { return }
    isOn = false
    panicLeft = 0
    fadeInLeft = fadeFrames
  }

  /// Render `frames` of the deck's runner into `left` (`right`), braked while a brake runs.
  /// Real-time safe. `startFrame` stamps the runner's events (braked chunks stamp theirs from the
  /// chunk's first output frame).
  func render(
    _ runner: WaveRunner, _ left: UnsafeMutablePointer<Float>,
    _ right: UnsafeMutablePointer<Float>?, frames: Int, startFrame: Int
  ) {
    var off = 0
    while off < frames {
      let r = right.map { $0 + off }
      if !isOn {
        let n = frames - off
        runner.process(left + off, r, frames: n, startFrame: startFrame + off)
        fadeIn(left + off, r, n)
        break
      }
      let playing = runner.playing
      let panicking = panicLeft > 0
      var n = min(frames - off, Self.maxChunk)
      if panicking {
        n = min(n, panicLeft)
      } else if playing {
        n = min(n, releaseFrame - elapsed)
      }
      if n > 0 {
        braked(runner, left + off, r, n, startFrame + off, playing)
        off += n
      }
      if (panicking && panicLeft == 0) || (!panicking && playing && elapsed >= releaseFrame) {
        isOn = false
        panicLeft = 0
        runner.catchUp(ticks: deficitTicks)
        fadeInLeft = fadeFrames
      }
    }
    if frames > 0 {
      lastL = left[frames - 1]
      lastR = right?[frames - 1] ?? lastL
    }
  }

  private func fadeIn(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ n: Int
  ) {
    var i = 0
    while i < n && fadeInLeft > 0 {
      let g = Float(fadeFrames - fadeInLeft) / Float(fadeFrames)
      left[i] *= g
      right?[i] *= g
      fadeInLeft -= 1
      i += 1
    }
  }

  @inline(__always)
  private static func cubic(_ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float, _ t: Float)
    -> Float
  {
    let c1 = 0.5 * (x2 - x0)
    let c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3
    let c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2)
    return ((c3 * t + c2) * t + c1) * t + x1
  }

  @inline(__always)
  private func push(_ k: Int) {
    l0 = l1
    l1 = l2
    l2 = l3
    l3 = srcL[k]
    r0 = r1
    r1 = r2
    r2 = r3
    r3 = srcR[k]
  }

  /// `n` braked output frames.
  private func braked(
    _ runner: WaveRunner, _ left: UnsafeMutablePointer<Float>,
    _ right: UnsafeMutablePointer<Float>?, _ n: Int, _ startFrame: Int, _ playing: Bool
  ) {
    // how many source frames the head reaches (the same arithmetic as the loop below)
    var pulls = fill
    var ph = phase
    var e = elapsed
    for _ in 0..<n {
      ph += rate(at: e)
      if ph >= 1 {
        ph -= 1
        pulls += 1
      }  // r ≤ 1 and ph < 1: at most one a frame
      if playing { e += 1 }
    }
    let ticksPerFrame = runner.tempo * 4 / (60 * sampleRate)  // before a bar's hand-over
    if pulls > 0 {
      runner.process(srcL, right == nil ? nil : srcR, frames: pulls, startFrame: startFrame)
      if right == nil { srcR.update(from: srcL, count: pulls) }
    }
    if playing {
      // the shadow deck ran n frames, this one's clock `pulls`
      deficitTicks += Double(n - pulls) * ticksPerFrame
    }
    var k = 0
    while fill > 0 {
      push(k)
      k += 1
      fill -= 1
    }
    for j in 0..<n {
      let rt = rate(at: elapsed)
      var g = Self.level(rt)
      if panicLeft > 0 {
        g *= Double(panicLeft) / Double(fadeFrames)
        panicLeft -= 1
      }
      let t = Float(phase)
      left[j] = Float(g) * Self.cubic(l0, l1, l2, l3, t)
      right?[j] = Float(g) * Self.cubic(r0, r1, r2, r3, t)
      phase += rt
      if phase >= 1 {
        phase -= 1
        push(k)
        k += 1
      }
      if playing { elapsed += 1 }
    }
  }
}
