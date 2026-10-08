import DJCore
import SwiftUI

/// The whole-track strip: peaks, played part brighter, playhead, loop, hot cues, bar lines.
public struct WaveformStrip: View {
  public var overview: WaveformOverview?
  public var overlay: WaveformOverlay?
  public var tint: Color

  public init(overview: WaveformOverview?, overlay: WaveformOverlay?, tint: Color) {
    self.overview = overview
    self.overlay = overlay
    self.tint = tint
  }

  public var body: some View {
    Canvas { ctx, size in
      Self.draw(&ctx, size: size, overview: overview, overlay: overlay, tint: tint)
    }
    .background(Color.black.opacity(0.85))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityLabel("waveform")
  }

  static func draw(
    _ ctx: inout GraphicsContext, size: CGSize, overview: WaveformOverview?,
    overlay: WaveformOverlay?, tint: Color
  ) {
    let mid = size.height / 2
    let play = overlay?.playhead ?? 0
    if let loop = overlay?.loop {
      let r = CGRect(
        x: loop.lowerBound * size.width, y: 0,
        width: max(1, (loop.upperBound - loop.lowerBound) * size.width), height: size.height)
      ctx.fill(Path(r), with: .color(tint.opacity((overlay?.loopActive ?? false) ? 0.30 : 0.12)))
    }
    for x in overlay?.barLines ?? [] {
      var p = Path()
      p.move(to: CGPoint(x: x * size.width, y: 0))
      p.addLine(to: CGPoint(x: x * size.width, y: size.height))
      ctx.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 1)
    }
    if let o = overview {
      let w = size.width / CGFloat(o.columns)
      for c in 0..<o.columns {
        let (lo, hi) = o.peak(c)
        let x = CGFloat(c) * w
        let top = mid - CGFloat(max(0, hi)) * mid
        let bottom = mid - CGFloat(min(0, lo)) * mid
        let r = CGRect(x: x, y: top, width: max(1, w), height: max(1, bottom - top))
        let played = Double(c) / Double(o.columns) < play
        ctx.fill(Path(r), with: .color(played ? tint : tint.opacity(0.45)))
      }
    }
    for (_, f) in overlay?.cues ?? [:] {
      var p = Path()
      p.move(to: CGPoint(x: f * size.width, y: 0))
      p.addLine(to: CGPoint(x: f * size.width, y: size.height))
      ctx.stroke(p, with: .color(.yellow), lineWidth: 2)
    }
    var head = Path()
    head.move(to: CGPoint(x: play * size.width, y: 0))
    head.addLine(to: CGPoint(x: play * size.width, y: size.height))
    ctx.stroke(head, with: .color(.white), lineWidth: 2)
  }
}
