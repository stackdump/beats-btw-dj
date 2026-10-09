import DJCore
import SwiftUI

/// The one place that maps a `ScopeMode` to its view. **One line per mode**: a port
/// replaces its `ScopePlaceholder` line with its own view (in its own file) and touches
/// nothing else, so ports can land in parallel without conflicts.
enum ScopeRegistry {
  @MainActor @ViewBuilder
  static func view(for mode: ScopeMode, feed: ScopeFeed) -> some View {
    switch mode {
    case .scope: ScopePlaceholder(mode: mode, feed: feed)
    case .spectro: ScopePlaceholder(mode: mode, feed: feed)
    case .bands: ScopePlaceholder(mode: mode, feed: feed)
    case .raster: ScopePlaceholder(mode: mode, feed: feed)
    case .constellation: ScopePlaceholder(mode: mode, feed: feed)
    case .corona: ScopePlaceholder(mode: mode, feed: feed)
    case .sonar: ScopePlaceholder(mode: mode, feed: feed)
    case .petal: ScopePlaceholder(mode: mode, feed: feed)
    }
  }
}

/// Stands in for a mode that has not been ported yet. Says so, and draws the feed's raw
/// min/max columns so the tap can be seen working behind the label.
struct ScopePlaceholder: View {
  let mode: ScopeMode
  let feed: ScopeFeed

  var body: some View {
    let _ = feed.revision
    ZStack {
      Canvas { ctx, size in
        let cols = feed.reader.columns(width: Int(size.width / 2), window: 2)
        let mid = size.height / 2
        let sc = (mid - 3) / CGFloat(max(feed.gain.disp, AutoGain.floor))
        for x in 0..<cols.count.count where cols.count[x] > 0 {
          let top = mid - CGFloat(cols.max[x]) * sc
          let h = max(1, CGFloat(cols.max[x] - cols.min[x]) * sc)
          ctx.fill(
            Path(CGRect(x: CGFloat(x) * 2, y: top, width: 1.5, height: h)),
            with: .color(.blue.opacity(0.6)))
        }
      }
      VStack(spacing: 2) {
        Text(mode.title).font(.callout.bold())
        Text("not ported yet").font(.caption)
        Text(mode.summary).font(.caption2).foregroundStyle(.secondary)
      }
      .padding(6)
      .background(Color.black.opacity(0.55))
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
  }
}
