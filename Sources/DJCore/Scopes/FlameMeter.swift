// FlameMeter: the master level / spectrum "flame" (SPEC mode 28), a port of the visualizer on
// beats' feed page (`feed.html` ~1305-1465: `ensureFlame`, `drawFlame`, `flameIdle`), pinned at
// beats-bitwrap-io 095d030.
//
// THE JS, AND THIS
//   * An `AnalyserNode` with `fftSize` 256 (128 bins) and `smoothingTimeConstant` 0.78 listens to
//     the page's one audio element; here `AnalyserFFT` (the same node, emulated) listens to the
//     MASTER tap of the engine (`ScopeFeed` of `.master`): the feed flame's analyser is a plain
//     `AnalyserNode`, i.e. the (L+R)/2 downmix that the master tap carries, so the channel is right.
//   * Once per frame `getByteFrequencyData` (dB -100...-30 scaled onto 0...255). Bins 2 ..< 96 are
//     drawn ("skip the lowest 2 bins (DC + sub-bass rumble) ... keep up through ~half the
//     spectrum"): 94 bars, bar i of width `W / 94` at `x = i * W / 94`, filled
//     `(x + 0.5, H - h, W / 94 - 1, h)` with `h = max(2, v * H)`, `v = byte / 255`, in
//     `hsl(200 - 160 v, 70 + 30 v %, 35 + 25 v %)`.
//   * Idle (nothing playing): a flat `#1a2a3a` line, 2 px, centred. While something plays and the
//     analyser reads nothing the bars sit at their 2 px minimum, as in the JS.
//   * Unit: W and H are CANVAS PIXELS (`resizeFlame` sizes the backing store to the CSS size times
//     devicePixelRatio), so the 1 px gap and the 0.5 px offset are device pixels. The model lays
//     out in pixels; the view scales the context by 1 / displayScale.
//
// CADENCE. `AnalyserFFT` smooths once per `analyse`, and τ = 0.78 is a time constant of a 60 Hz
// rAF loop (see the AnalyserFFT header). The app draws the meter at whatever the viz level
// allows (30 fps at full, 4 when paused) and on displays that are not 60 Hz, so the model
// compensates for the real interval between analyses: `τ_eff = 0.78 ^ (dt * 60)`. At exactly
// 1/60 s that is 0.78, so a 60 Hz loop is the JS to the digit; at 30 fps it is 0.78², the same decay
// per second.
//
// The same goes for the rate itself: feed.html redraws on every rAF (the display's rate) with no
// cap and no visual level; the meter here is drawn by `ScopeCanvas`, i.e. at the visual level's
// pace (30 fps at full), so its bars update half as often as the JS' at 60 Hz and fall at the
// same speed.
//
// WHAT WAS NOT PORTED. The JS falls back to a synthesized, time-driven animation ("synth mode")
// when the analyser reads silence for 30 frames while the `<audio>` element plays: iOS Safari hands
// out an all-zero analyser for a MediaElementAudioSourceNode. That is a workaround for a broken
// browser analyser, tied to the element's `paused` / `currentTime`; here the tap is the engine's own
// and a dead one is reported by the feed (`masterTapSilent`). Faking motion over it would lie to a
// DJ, so there is no synth mode, no `flameSilentFrames` counter, and silence is drawn as silence.
// The `<audio>` play / pause / ended events become the host's `active` flag (any deck playing).

import Foundation

public enum FlameSpec {
  /// `flameAnalyser.fftSize`.
  public static let fftSize = 256
  /// `flameAnalyser.smoothingTimeConstant`.
  public static let smoothing: Float = 0.78
  /// `start`: the lowest two bins are skipped.
  public static let firstBin = 2
  /// `Math.min(flameBuf.length, 96)`: one past the last bin drawn.
  public static let lastBin = 96
  /// `realN`: bars drawn.
  public static let barCount = lastBin - firstBin
  /// `Math.max(2, v * H)`.
  public static let minBarHeight = 2.0
  /// The rAF rate τ = 0.78 was tuned at.
  public static let referenceRate = 60.0
  /// The rate assumed for the first analysis, when there is no previous one to measure.
  public static let firstInterval = 1.0 / referenceRate
  /// The idle line: `#1a2a3a`, 2 px tall, centred (`fillRect(0, H / 2 - 1, W, 2)`).
  public static let idleColor = ScopeColor(r8: 0x1a, g8: 0x2a, b8: 0x3a)
  public static let idleHeight = 2.0
  /// `canvas { height: 38px }` in feed.html's CSS.
  public static let cssHeight = 38.0
}

/// A rectangle in canvas pixels, y down.
public struct FlameRect: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
}

public struct FlameBar: Equatable, Sendable {
  public var rect: FlameRect
  public var color: ScopeColor
  /// The byte the bar shows (0...255).
  public var value: UInt8
}

/// One frame of the meter, laid out in canvas pixels.
public struct FlameFrame: Equatable, Sendable {
  public var width: Double
  public var height: Double
  /// Nothing plays: the flat line and no bars.
  public var idle: Bool
  public var bars: [FlameBar]
  /// The line drawn while idle.
  public var idleLine: FlameRect
}

public enum FlameLayout {
  /// `hsl(${200 - v*160}, ${70 + v*30}%, ${35 + v*25}%)` for `v` in 0...1.
  public static func color(forValue v: Double) -> ScopeColor {
    ScopeColor.hsla(200 - v * 160, 70 + v * 30, 35 + v * 25)
  }

  /// The bars for the 128 bytes of `getByteFrequencyData`, on a `width` x `height` canvas. Bytes
  /// that are not there read 0.
  public static func bars(bytes: [UInt8], width: Double, height: Double) -> [FlameBar] {
    let n = FlameSpec.barCount
    let barW = width / Double(n)
    var out: [FlameBar] = []
    out.reserveCapacity(n)
    for i in 0..<n {
      let b = FlameSpec.firstBin + i < bytes.count ? bytes[FlameSpec.firstBin + i] : 0
      let v = Double(b) / 255
      let h = max(FlameSpec.minBarHeight, v * height)
      let x = Double(i) * barW
      out.append(
        FlameBar(
          rect: FlameRect(x: x + 0.5, y: height - h, width: barW - 1, height: h),
          color: color(forValue: v), value: b))
    }
    return out
  }

  public static func idleLine(width: Double, height: Double) -> FlameRect {
    FlameRect(x: 0, y: height / 2 - 1, width: width, height: FlameSpec.idleHeight)
  }

  public static func frame(bytes: [UInt8], width: Double, height: Double, idle: Bool)
    -> FlameFrame
  {
    FlameFrame(
      width: width, height: height, idle: idle,
      bars: idle ? [] : bars(bytes: bytes, width: width, height: height),
      idleLine: idleLine(width: width, height: height))
  }

  /// The effective smoothing constant for an analysis `dt` seconds after the previous one.
  public static func smoothing(forInterval dt: Double) -> Float {
    let d = dt.isFinite && dt >= 0 ? dt : FlameSpec.firstInterval
    return Float(pow(Double(FlameSpec.smoothing), d * FlameSpec.referenceRate))
  }
}

/// The analyser and its last reading. One per meter; main thread.
@MainActor
public final class FlameMeterModel {
  public let analyser = AnalyserFFT(
    fftSize: FlameSpec.fftSize, smoothingTimeConstant: FlameSpec.smoothing)
  /// `getByteFrequencyData` of the last analysis (128 bytes).
  public private(set) var bytes = [UInt8](repeating: 0, count: FlameSpec.fftSize / 2)
  /// Analyses done.
  public private(set) var reads = 0

  private var window = [Float](repeating: 0, count: FlameSpec.fftSize)
  private var lastEngineFrame = -1
  private var lastTime: Double?
  private var lastHeld = 0

  /// Models built, process-wide. A view that holds one must not build a new one every time its
  /// parent is evaluated (an `AnalyserFFT` is an FFT plan and several buffers).
  public private(set) static var built = 0

  public init() { Self.built += 1 }

  /// One drawn frame: if the engine has moved since the last read, analyse the newest 256 master
  /// samples, `time` being a steady wall clock in seconds (for the smoothing's cadence). A second
  /// call in the same engine block changes nothing, as a second `getByteFrequencyData` in one
  /// render quantum does not.
  ///
  /// The smoothed state is forgotten when the feed's sample history was restarted (a re-acquire
  /// empties it, so the analyser would be smoothing over a different stream). It is NOT
  /// forgotten on a new `feed.generation`: that also bumps when a track is loaded on an idle
  /// deck or a deck starts, while the master audio goes on without a break, and feed.html's
  /// analyser keeps its state across a track change.
  public func update(feed: ScopeFeed, at time: Double) {
    let held = feed.history.count
    if held < lastHeld { reset() }
    lastHeld = held
    let end = feed.nowFrame
    guard end != lastEngineFrame else { return }
    lastEngineFrame = end
    window.withUnsafeMutableBufferPointer { feed.history.copyWindow(into: $0, endingAt: end) }
    analyse(window, at: time)
  }

  /// Analyse `samples` (the newest 256 are used) `time` seconds on a steady clock. The smoothing
  /// constant follows the interval since the previous analysis (see CADENCE).
  public func analyse(_ samples: [Float], at time: Double) {
    let dt = lastTime.map { time - $0 } ?? FlameSpec.firstInterval
    lastTime = time
    analyser.smoothingTimeConstant = FlameLayout.smoothing(forInterval: dt)
    analyser.analyse(samples)
    bytes.withUnsafeMutableBufferPointer { analyser.byteFrequencyData(into: $0) }
    reads += 1
  }

  /// Back to silence: the smoothed magnitudes, the bytes and the cadence.
  public func reset() {
    analyser.reset()
    for i in bytes.indices { bytes[i] = 0 }
    lastEngineFrame = -1
    lastTime = nil
    lastHeld = 0
  }

  /// The frame to draw on a `width` x `height` canvas (pixels). `active`: something is playing.
  public func frame(width: Double, height: Double, active: Bool) -> FlameFrame {
    FlameLayout.frame(bytes: bytes, width: width, height: height, idle: !active)
  }
}
