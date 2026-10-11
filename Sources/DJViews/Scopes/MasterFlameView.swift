import DJCore
import SwiftUI

// The master flame meter (SPEC mode 28), in the Mixer column: feed.html's equalizer bars, driven by
// an `AnalyserFFT` (fft 256, smoothing 0.78) over the engine's master tap.
//
//   MasterFlameView(hub:active:)   the live meter. `active` (a deck is playing) holds an acquire on
//                                  the master feed and runs the per-frame canvas; otherwise it is
//                                  the idle line and costs nothing (no tap, no pump, no timeline).
//   FlameMeterFrameView(frame:)    one laid-out frame, no timeline (what tests render).
//   FlameMeterPainter              draws a `FlameFrame` (DJCore) into a Canvas.
//
// The numbers (bin range, bar mapping, colours, smoothing and its cadence compensation) are
// `FlameMeterModel` / `FlameLayout` in DJCore; this file only paints them. The box is the CSS
// `.pl-now-flame`: `#050a14`, 38 px high, 2 px radius, a 1 px `#1a2a3a` inner ring and an inner
// shadow (`inset 0 4px 8px rgba(0,0,0,.6)`). In CSS all of that is the canvas element's own box,
// painted UNDER its bitmap, so the painter lays down background, shadow and ring first and the
// bars on top of them (a full-height bar covers the ring where they meet). Not drawn: the 1 px
// black `border` outside the ring; the box here is 38 pt including its ring. Its bars are laid out
// in DEVICE pixels (the JS sizes the canvas' backing store by devicePixelRatio), so the painter
// scales the context by 1 / displayScale.
//
// The meter draws through `ScopeCanvas`, so it is paced by the visual level (30 / 15 / 8 / 4 fps)
// and its draw time is booked as a scope path.

enum FlameMeterPainter {
  /// Colours of the box (`.pl-now-flame`).
  static let background = ScopeColors.background
  static let ring = ScopeColors.grid

  /// The edge of a Gaussian blur of sigma 4 (`blur 8px`) of a shape whose edge is `offset` away,
  /// times the shadow's 0.6, sampled every 2 px: the alpha of `inset 0 4px 8px rgba(0,0,0,.6)`
  /// at the top (offset 4) and, with offset 0, of the sides.
  static func shadowStops(offset: Double, length: Double) -> [Gradient.Stop] {
    (0...8).map { i in
      let d = Double(i) * length / 8
      return Gradient.Stop(
        color: Color.black.opacity(0.6 * normalCDF((offset - d) / 4)), location: d / length)
    }
  }

  /// The standard normal's cumulative distribution (Abramowitz and Stegun 7.1.26).
  static func normalCDF(_ x: Double) -> Double {
    let t = 1 / (1 + 0.3275911 * abs(x) / 2.0.squareRoot())
    let poly =
      t
      * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
    let erf = 1 - poly * exp(-x * x / 2)
    return x >= 0 ? 0.5 * (1 + erf) : 0.5 * (1 - erf)
  }

  /// Paint `frame` (laid out in device pixels for a canvas of `size` points at `scale`): the
  /// box's shadow and ring, then the bars or the idle line over them.
  static func paint(_ ctx: inout GraphicsContext, size: CGSize, scale: CGFloat, frame: FlameFrame) {
    let rect = CGRect(origin: .zero, size: size)
    // `box-shadow: inset 0 4px 8px rgba(0,0,0,.6)`: the top edge is 4 px inside the hole's, the
    // left and right edges on it; the bottom one is outside the box and casts nothing
    let top = min(size.height, 16)
    ctx.fill(
      Path(CGRect(x: 0, y: 0, width: size.width, height: top)),
      with: .linearGradient(
        Gradient(stops: shadowStops(offset: 4, length: Double(top))),
        startPoint: .zero, endPoint: CGPoint(x: 0, y: top)))
    let side = min(size.width / 2, 12)
    ctx.fill(
      Path(CGRect(x: 0, y: 0, width: side, height: size.height)),
      with: .linearGradient(
        Gradient(stops: shadowStops(offset: 0, length: Double(side))),
        startPoint: .zero, endPoint: CGPoint(x: side, y: 0)))
    ctx.fill(
      Path(CGRect(x: size.width - side, y: 0, width: side, height: size.height)),
      with: .linearGradient(
        Gradient(stops: shadowStops(offset: 0, length: Double(side))),
        startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: size.width - side, y: 0)))
    // `inset 0 0 0 1px #1a2a3a`, listed first so it sits on top of the blur
    ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(ring.color), lineWidth: 1)
    // bars, in canvas pixels, over the box
    var px = ctx
    px.scaleBy(x: 1 / scale, y: 1 / scale)
    if frame.idle {
      let r = frame.idleLine
      px.fill(
        Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)),
        with: .color(FlameSpec.idleColor.color))
    } else {
      for bar in frame.bars {
        let r = bar.rect
        px.fill(
          Path(CGRect(x: r.x, y: r.y, width: r.width, height: r.height)),
          with: .color(bar.color.color))
      }
    }
  }
}

/// One frame of the meter laid out for `size` points at `scale` pixels per point; no timeline.
struct FlameMeterFrameView: View {
  let frame: FlameFrame
  var scale: CGFloat = 1

  var body: some View {
    Canvas { ctx, size in
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)), with: .color(FlameMeterPainter.background.color))
      FlameMeterPainter.paint(&ctx, size: size, scale: scale, frame: frame)
    }
    .clipShape(RoundedRectangle(cornerRadius: 2))
    .accessibilityLabel("master level")
  }
}

/// The meter at rest: the box and its flat line, whatever size it is given. No timeline.
struct FlameIdleView: View {
  @Environment(\.displayScale) private var scale

  var body: some View {
    Canvas { ctx, size in
      ctx.fill(
        Path(CGRect(origin: .zero, size: size)), with: .color(FlameMeterPainter.background.color))
      let frame = FlameLayout.frame(
        bytes: [], width: Double(size.width * scale), height: Double(size.height * scale),
        idle: true)
      FlameMeterPainter.paint(&ctx, size: size, scale: scale, frame: frame)
    }
  }
}

/// Holds the meter's model and makes it the first time it is asked for. A `@State` initial value
/// is evaluated every time the parent evaluates its body (and builds a new view value), which would
/// build an FFT plan and its buffers about thirty times a second, and throw each away: so the view
/// holds this empty box, and the model exists once a draw or a reset needs it.
@MainActor
final class FlameModelBox {
  private(set) var made = false
  private var storage: FlameMeterModel?

  var model: FlameMeterModel {
    if let storage { return storage }
    let m = FlameMeterModel()
    storage = m
    made = true
    return m
  }

  /// Back to silence, without building a model just to reset it.
  func reset() { storage?.reset() }
}

struct MasterFlameView: View {
  let hub: ScopeHub
  /// Is a deck playing? The JS draws only while its `<audio>` plays, else the idle line.
  let active: Bool
  @State private var box = FlameModelBox()
  @State private var subscription = ScopeSubscription()
  @Environment(\.displayScale) private var scale

  var body: some View {
    let feed = hub.feed(.master)
    Group {
      if active {
        ScopeCanvas(hub: hub) { ctx, size in
          let model = box.model
          model.update(feed: feed, at: ProcessInfo.processInfo.systemUptime)
          let frame = model.frame(
            width: Double(size.width * scale), height: Double(size.height * scale), active: true)
          FlameMeterPainter.paint(&ctx, size: size, scale: scale, frame: frame)
        }
      } else {
        FlameIdleView()
      }
    }
    .frame(height: CGFloat(FlameSpec.cssHeight))
    .clipShape(RoundedRectangle(cornerRadius: 2))
    .onAppear { subscription.follow(feed, while: active) }
    .onChange(of: active) {
      subscription.follow(feed, while: active)
      if !active { box.reset() }
    }
    .onDisappear {
      subscription.release()
      box.reset()
    }
    .accessibilityLabel("master level")
  }
}
