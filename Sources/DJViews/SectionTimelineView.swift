import DJCore
import SwiftUI

/// The song as a bar of sections: each coloured by its name, the current one lit, a
/// playhead across them. Click a section to launch it.
public struct SectionTimelineView: View {
  public var timeline: SectionTimeline?
  public var onSelect: (Int) -> Void

  public init(timeline: SectionTimeline?, onSelect: @escaping (Int) -> Void = { _ in }) {
    self.timeline = timeline
    self.onSelect = onSelect
  }

  public var body: some View {
    GeometryReader { g in
      Canvas { ctx, size in
        guard let t = timeline else { return }
        for seg in t.segments {
          let rect = CGRect(
            x: seg.start * size.width + 0.5, y: 0, width: max(1, seg.width * size.width - 1),
            height: size.height)
          let c = Color(
            hue: SectionTimeline.hue(seg.name), saturation: 0.55,
            brightness: seg.isCurrent ? 0.95 : 0.45)
          ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(c))
          if rect.width > 28 {
            ctx.draw(
              Text(seg.name).font(.system(size: 9, weight: seg.isCurrent ? .bold : .regular))
                .foregroundColor(.white),
              at: CGPoint(x: rect.midX, y: rect.midY))
          }
        }
        var head = Path()
        head.move(to: CGPoint(x: t.playhead * size.width, y: 0))
        head.addLine(to: CGPoint(x: t.playhead * size.width, y: size.height))
        ctx.stroke(head, with: .color(.white), lineWidth: 2)
      }
      .contentShape(Rectangle())
      .gesture(
        SpatialTapGesture().onEnded { tap in
          if let i = timeline?.index(atFraction: tap.location.x / max(g.size.width, 1)) {
            onSelect(i)
          }
        })
    }
    .accessibilityLabel("section timeline")
  }
}
