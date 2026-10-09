import DJCore
import SwiftUI

// SPEC mode 23: the rolling timeline dots of a net deck (audio-io.js `vizDrawTimeline`). A thin
// strip under the section bar: every fire of the deck slides in at the right edge, coloured by
// its part, and drifts left over the adaptive window, fading out in the last 15 %.
//
// The numbers are `TimelineDots` (DJCore); the dots are the deck feed's fire log, the same
// fires the scopes draw. The strip holds its own acquire on the feed only while the deck's
// transport runs (so the fire log, and with it the deck tap, runs only then), paced and pumped
// by `ScopeCanvas` like every scope: 30 fps, down to 4 at the lowest viz level. A stopped deck
// holds nothing and draws nothing: no tap, no pump, no timeline.

/// Paints dots as `vizDrawTimeline` does: a gradient streak behind a round head, both at the
/// dot's alpha, oldest first.
enum TimelineDotsPainter {
  static func paint(_ ctx: inout GraphicsContext, _ draws: [TimelineDotDraw]) {
    for d in draws {
      let color = d.color.withAlpha(1).color
      var layer = ctx
      layer.opacity = d.alpha
      if d.streakLength > 0 {
        let rect = CGRect(
          x: d.x - d.streakLength, y: TimelineGeometry.streakY, width: d.streakLength,
          height: TimelineGeometry.streakHeight)
        // createLinearGradient(x - streakLen, 0, x, 0): 'transparent' (black, alpha 0) → colour
        layer.fill(
          Path(rect),
          with: .linearGradient(
            Gradient(colors: [Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0), color]),
            startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
      }
      let r = TimelineGeometry.headRadius
      layer.fill(
        Path(
          ellipseIn: CGRect(
            x: d.x - r, y: TimelineGeometry.headY - r, width: 2 * r, height: 2 * r)),
        with: .color(color))
    }
  }
}

/// The strip of one net deck. Hand it the deck's feed (`hub.feed(.deck(name))`), the hub, and
/// whether the deck's transport is running (playing or scrubbing: the viz loop of the JS).
struct TimelineDotsView: View {
  let feed: ScopeFeed
  let hub: ScopeHub
  let active: Bool
  @State private var model: TimelineDotsModel
  @State private var subscription = ScopeSubscription()

  init(feed: ScopeFeed, hub: ScopeHub, active: Bool) {
    self.feed = feed
    self.hub = hub
    self.active = active
    _model = State(initialValue: TimelineDotsModel(feed: feed))
  }

  var body: some View {
    // On the window, not on the scope's own background: the JS canvas is transparent over the
    // page. While the transport runs a dark track sits behind it (it keeps the dots readable
    // in a light window too); stopped, the strip is just empty space.
    Group {
      if active {
        ScopeCanvas(hub: hub, kind: .timeline, fillsBackground: false) { ctx, size in
          model.update(from: feed)
          let t = feed.clock
          guard t.transport == .playing || t.transport == .scrubbing else { return }
          let now = feed.nowTime
          TimelineDotsPainter.paint(
            &ctx, model.history.layout(now: now, width: size.width, tempo: t.tempo))
          model.prune(now: now, tempo: t.tempo)
        }
      } else {
        Color.clear
      }
    }
    .frame(height: TimelineGeometry.stripHeight)
    .background(
      active ? Color.black.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 3)
    )
    .onAppear { subscription.follow(feed, while: active) }
    .onChange(of: active) { subscription.follow(feed, while: active) }
    .onDisappear { subscription.release() }
    .accessibilityLabel("fire timeline")
  }
}
