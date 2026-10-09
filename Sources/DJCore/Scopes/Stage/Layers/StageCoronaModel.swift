import Foundation

// StageCoronaModel: SPEC mode 9, the corona (stage.js `renderCorona`). 128 bars radiate from the
// ring's centre, their length and colour keyed to the FFT of the master, cool at the floor to
// warm at the ceiling.
//
// WHAT IT LISTENS TO
// ==================
// beats reads `toneEngine.getMasterAnalyser('fft', 128)`: a cached `Tone.Analyser('fft', 128)`
// (fftSize 256, smoothing 0.4) tapped after the master FX, read with `getValue()` once per
// `requestAnimationFrame`, i.e. the raw `getFloatFrequencyData` dB of 128 bins. Here that is
// `AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0.4)`, analysed ONCE per drawn frame, over
// the source of the stage: the master tap when the source is the master, the deck's tap for a
// deck source (a deck's tap is before its EQ and fader, as every scope's is).
//
// CHANNEL (decided, see the header of AnalyserFFT): Tone 15.1.22's Analyser is
// `Gain -> ChannelSplitter(1) -> AnalyserNode`, which keeps channel 0, so beats' corona hears the
// LEFT channel, not the (L+R)/2 down-mix the shared taps carry. The wave engine is dual-mono
// (L == R) so nothing differs for a net deck, but the DJ master also carries stereo samples,
// where the two spectra differ by tens of dB in some bins. The corona therefore reads the left
// channel from its own taps (`Deck.leftTap`, `DJEngine.masterLeftTap`), switched on through
// `ScopeFeed.setLeftChannelWanted` only while the corona is showing: it asks every frame it
// draws, hands the lease back (`rest()`) when it stops, when the source changes and when the
// Stage closes (`StageModel.detach()`, whatever else keeps the feed open), and the feed ends it
// with its last release. The lease starts empty (a tap that was off keeps its old samples, which
// the first frame must not hear). No deviation from beats there.
//
// CADENCE (decided): `AnalyserFFT`'s smoothing acts once per `analyse` call, and beats calls it
// once per rAF at 60 Hz, so τ = 0.4 is a time constant of a 60 Hz loop. The stage draws at the
// display's rate (or the perf level's cap), so each analysis uses `τ' = τ^(dt·60)` for the real
// frame interval `dt`: two 120 Hz frames smooth exactly like one 60 Hz frame, a 30 Hz frame like
// two. It is never called from anywhere but the stage's own per-frame advance (not the 30 Hz
// AppModel poll).

/// One bar of the corona, in stage coordinates, with the style stage.js draws it with.
public struct CoronaRay: Equatable, Sendable {
  /// Where the bar starts (on the inner circle) and ends.
  public var x0: Double
  public var y0: Double
  public var x1: Double
  public var y1: Double
  /// 0 at -100 dB and below, 1 at 0 dB and above.
  public var norm: Double
  /// `200 - norm * 160`, degrees: cool blue at the floor, warm at the ceiling.
  public var hue: Double
  public var lineWidth: Double
  /// The bar's stroke: `hsla(hue, 90%, 60%, 0.35 + norm * 0.55)`.
  public var stroke: ScopeColor
  /// The glow: `shadowColor hsla(hue, 90%, 55%, 0.6)`, `shadowBlur 6 + norm * 10` (a canvas blur,
  /// whose Gaussian has a standard deviation of half the number).
  public var shadow: ScopeColor
  public var shadowBlur: Double

  /// The bar has no length (a bin at the floor): stage.js still strokes it with round caps,
  /// which leaves a dot as wide as the line.
  public var isDot: Bool { x0 == x1 && y0 == y1 }
}

/// The corona's numbers, ported from `renderCorona` (pure; the drawing is in DJViews).
public enum StageCorona {
  /// `Tone.Analyser('fft', 128)`: 128 bins from a 256-point FFT.
  public static let binCount = 128
  public static let fftSize = 256
  /// `a.smoothing = 0.4` (tone-engine.js `getMasterAnalyser`).
  public static let smoothing: Float = 0.4
  /// The rate beats' analyser read loop runs at (`requestAnimationFrame` on a normal display).
  public static let referenceRate = 60.0
  /// `Math.max(-100, Math.min(0, db))`.
  public static let dbRange: ClosedRange<Float> = -100...0
  /// `innerR = inner + 18`: a gap so the corona does not kiss the dark planet.
  public static let planetGap = 18.0
  /// `maxLen = min(w, h) * 0.32`.
  public static let lengthFraction = 0.32
  /// `inner = session.darkPlanetRadius || min(w, h) * 0.08`.
  public static let fallbackPlanetFraction = 0.08

  /// The radius the bars start at. `planetRadius` is the dark planet's (nil below two panels, as
  /// in stage.js where it is unset); nil, zero and non-finite fall back to 8 % of the short side.
  public static func innerRadius(planetRadius: Double?, width: Double, height: Double) -> Double {
    let inner: Double
    if let r = planetRadius, r.isFinite, r > 0 {
      inner = r
    } else {
      inner = min(width, height) * fallbackPlanetFraction
    }
    return inner + planetGap
  }

  /// The longest a bar can be (at 0 dB).
  public static func maxLength(width: Double, height: Double) -> Double {
    min(width, height) * lengthFraction
  }

  /// `norm = (clamp(db, -100, 0) + 100) / 100`. Silence (-infinity) is 0.
  public static func normalised(decibels db: Float) -> Double {
    (Double(AnalyserFFT.clamped(decibels: db, to: dbRange)) + 100) / 100
  }

  /// Bin `i` of `n` points at `i / n * 2π - π/2`: bin 0 at the top, clockwise.
  public static func angle(index i: Int, count n: Int) -> Double {
    Double(i) / Double(n) * 2 * Double.pi - Double.pi / 2
  }

  /// The bar of bin `i` for a bin level of `db`.
  public static func ray(
    index i: Int, count n: Int, decibels db: Float, center: StagePoint, innerRadius: Double,
    maxLength: Double
  ) -> CoronaRay {
    let norm = normalised(decibels: db)
    let len = norm * maxLength
    let a = angle(index: i, count: n)
    let c = cos(a)
    let s = sin(a)
    let hue = 200 - norm * 160
    return CoronaRay(
      x0: center.x + c * innerRadius, y0: center.y + s * innerRadius,
      x1: center.x + c * (innerRadius + len), y1: center.y + s * (innerRadius + len),
      norm: norm, hue: hue, lineWidth: 2 + norm * 3.5,
      stroke: .hsla(hue, 90, 60, 0.35 + norm * 0.55), shadow: .hsla(hue, 90, 55, 0.6),
      shadowBlur: 6 + norm * 10)
  }

  /// Every bar of a spectrum (`decibels`: one dB value per bin) on a `width` x `height` stage
  /// whose ring is at `center`, round a dark planet of `planetRadius`.
  public static func rays(
    decibels: [Float], center: StagePoint, planetRadius: Double?, width: Double, height: Double
  ) -> [CoronaRay] {
    let inner = innerRadius(planetRadius: planetRadius, width: width, height: height)
    let longest = maxLength(width: width, height: height)
    return decibels.indices.map {
      ray(
        index: $0, count: decibels.count, decibels: decibels[$0], center: center,
        innerRadius: inner, maxLength: longest)
    }
  }

  /// The smoothing constant for a frame `dt` seconds after the last: `τ^(dt·60)`, so that the
  /// smoothing per SECOND is what beats' 60 Hz loop has whatever rate the stage draws at. A first
  /// frame (no interval) counts as one 60 Hz frame; an interval is trusted up to 0.1 s (the
  /// stage clamps there as the rAF loop does).
  public static func smoothingConstant(dt: Double, nominal tau: Float = smoothing) -> Float {
    guard dt.isFinite, dt > 0 else { return tau }
    return Float(pow(Double(tau), min(dt, 0.1) * referenceRate))
  }
}

/// The corona's analyser, fed once per drawn frame while the corona shows.
@MainActor
public final class StageCoronaModel {
  /// The last analysis, one dB value per bin (`-infinity` where a bin is silent), as Tone's
  /// `getValue()` hands it out. All `-infinity` before the first analysis.
  public private(set) var decibels = [Float](repeating: -.infinity, count: StageCorona.binCount)
  /// Analyses since the corona last started (0 while it is not showing).
  public private(set) var analyses = 0
  /// Did the last frame get samples from the tap? False while nothing has arrived (the first
  /// frame, a silent engine, a sample deck that is not loaded).
  public private(set) var heardSamples = false
  /// The feed whose left channel this model asked for.
  public private(set) weak var leasedFeed: ScopeFeed?

  private let analyser = AnalyserFFT(
    fftSize: StageCorona.fftSize, smoothingTimeConstant: StageCorona.smoothing)
  private var window = [Float](repeating: 0, count: StageCorona.fftSize)

  public init() {}

  /// A frame with the corona showing: take the source's newest 256 left-channel samples and
  /// analyse them once. `dt` is the frame's real interval in seconds.
  public func advance(feed: ScopeFeed?, dt: Double) {
    guard let feed else {
      rest()
      return
    }
    if leasedFeed !== feed {
      leasedFeed?.setLeftChannelWanted(false)
      leasedFeed = feed
      restart()
    }
    feed.setLeftChannelWanted(true)
    heardSamples = window.withUnsafeMutableBufferPointer { feed.copyNewestLeftSamples(into: $0) }
    analyse(dt: dt)
  }

  /// One analysis of `window` (the 256 newest samples) at the frame interval `dt`.
  private func analyse(dt: Double) {
    analyser.smoothingTimeConstant = StageCorona.smoothingConstant(dt: dt)
    analyser.analyse(window)
    decibels.withUnsafeMutableBufferPointer { analyser.floatFrequencyData(into: $0) }
    analyses += 1
  }

  /// An analysis of given samples (the newest 256 are used, a shorter window is zero-padded at
  /// the front), for tests and previews that have no engine.
  public func analyse(samples: [Float], dt: Double) {
    window.withUnsafeMutableBufferPointer { w in
      w.update(repeating: 0)
      let have = min(samples.count, w.count)
      for i in 0..<have { w[w.count - have + i] = samples[samples.count - have + i] }
    }
    heardSamples = !samples.isEmpty
    analyse(dt: dt)
  }

  /// The corona is not showing (or has no feed): hand the tap back and forget the spectrum, so
  /// the next time starts from silence.
  public func rest() {
    if let feed = leasedFeed {
      feed.setLeftChannelWanted(false)
      leasedFeed = nil
    }
    if analyses > 0 || heardSamples { restart() }
  }

  private func restart() {
    analyser.reset()
    for i in decibels.indices { decibels[i] = -.infinity }
    analyses = 0
    heardSamples = false
  }

  /// The bars to draw on this frame's stage.
  public func rays(for context: StageContext) -> [CoronaRay] {
    StageCorona.rays(
      decibels: decibels, center: context.ringCenter, planetRadius: context.darkPlanetRadius,
      width: context.width, height: context.height)
  }
}
