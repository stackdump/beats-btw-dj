import DJCore
import SwiftUI

/// What every mode view shows until its agent replaces the file: a labelled "not yet ported"
/// state that also proves the feed is alive (lane count, tempo, samples, fires). Not replaced
/// by mode agents; delete it once the last mode is real.
struct ScopePlaceholder: View {
  let kind: ScopeKind
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  var body: some View {
    ScopeCanvas(hub: hub) { ctx, size in
      let font = Font.system(size: 10, design: .monospaced)
      func line(_ s: String, y: CGFloat, color: Color) {
        ctx.draw(
          ctx.resolve(Text(s).font(font).foregroundColor(color)),
          at: CGPoint(x: size.width / 2, y: y), anchor: .center)
      }
      let c = size.height / 2
      line(
        "\(kind.title) — not yet ported", y: c - 14, color: ScopeColors.sectionLine.color)
      line(
        "\(feed.source.label) · \(feed.statusText)\(measured ? " · measured" : "")", y: c,
        color: ScopeColors.text.color)
      line(
        String(
          format: "now %.2f s · %d samples · %d fires · generation %d", feed.nowTime,
          feed.history.count, feed.fireCount, feed.generation), y: c + 14,
        color: ScopeColors.text.color)
    }
  }
}
