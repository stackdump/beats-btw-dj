import DJCore
import SwiftUI

// The per-frame driver every scope mode draws through.
//
//   ScopeCanvas(hub: hub) { ctx, size in
//     // `hub.pump()` has already run; read the feed and draw. The background is filled.
//   }
//
// It is a `TimelineView(.animation)` paced by the hub (`hub.minFrameInterval`, from the viz
// level), whose Canvas calls `hub.pump()` and then fills the scope background and hands over
// the context. Pumping is cheap and safe to repeat, so any number of ScopeCanvases (and the panel
// header) may do it in one frame; with the audio thread running a second pump can move "now" on
// by the render cycles in between (a block, ~10 ms; see the ScopeFeed header), so each canvas
// draws from what it reads in its own draw. A mode never starts its own timeline.
//
// Canvas text: `ctx.resolve(Text("…").font(.system(size: 10, design: .monospaced)))`.

extension ScopeColor {
  /// The same colour for SwiftUI (sRGB).
  var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

struct ScopeCanvas: View {
  let hub: ScopeHub
  /// Fill the scope background (`ScopeColors.background`, #050a14) before drawing.
  var fillsBackground = true
  let draw: @MainActor (inout GraphicsContext, CGSize) -> Void

  init(
    hub: ScopeHub, fillsBackground: Bool = true,
    draw: @escaping @MainActor (inout GraphicsContext, CGSize) -> Void
  ) {
    self.hub = hub
    self.fillsBackground = fillsBackground
    self.draw = draw
  }

  var body: some View {
    TimelineView(.animation(minimumInterval: hub.minFrameInterval)) { timeline in
      let tick = timeline.date.timeIntervalSinceReferenceDate  // a new closure every frame
      Canvas { ctx, size in
        MainActor.assumeIsolated {
          _ = tick
          hub.pump()
          if fillsBackground {
            ctx.fill(
              Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
          }
          draw(&ctx, size)
        }
      }
    }
  }
}
