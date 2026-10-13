import DJCore
import SwiftUI

/// The song as a bar of sections: each coloured by its name, the current one lit, a
/// playhead across them. Click a section to launch it.
///
/// SPEC mode 24 (canvas.js `renderTimeline`): the five names beats colours keep its colours
/// (`SectionTimeline.color`); a section cut into several phrases prints its phrase letters after
/// the name (if the whole label fits its block) and is divided at `i / phraseCount`. Blocks are
/// sized by `steps / total`, and a label never leaves its block.
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
        // blocks first, then the playhead, then the labels: the line never cuts a name
        var labels: [(rect: CGRect, seg: SectionTimeline.Segment)] = []
        for seg in t.segments {
          let rect = CGRect(
            x: seg.start * size.width + 0.5, y: 0, width: max(1, seg.width * size.width - 1),
            height: size.height)
          let c = SectionTimeline.color(seg.name, isCurrent: seg.isCurrent).color
          ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(c))
          // `.pn-timeline-phrase-divider`: 1 px, white at 25 %, the block's full height
          for f in seg.dividers {
            let x = rect.minX + CGFloat(f) * rect.width
            ctx.fill(
              Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
              with: .color(.white.opacity(0.25)))
          }
          labels.append((rect, seg))
        }
        let x = t.playhead * size.width
        var head = Path()
        head.move(to: CGPoint(x: x, y: 0))
        head.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(head, with: .color(.black.opacity(0.45)), lineWidth: 4)
        ctx.stroke(head, with: .color(.white), lineWidth: 2)
        // caps, so the position reads even over a pale block
        for (y, dy) in [(0.0, 4.0), (size.height, -4.0)] {
          var cap = Path()
          cap.move(to: CGPoint(x: x - 4, y: y))
          cap.addLine(to: CGPoint(x: x + 4, y: y))
          cap.addLine(to: CGPoint(x: x, y: y + dy))
          cap.closeSubpath()
          ctx.fill(cap, with: .color(.white))
        }
        for (rect, seg) in labels {
          if rect.width > 10 && rect.width <= 28 {
            // too narrow for the name (a 4-bar intro): its initial
            var inside = ctx
            inside.clip(to: Path(roundedRect: rect, cornerRadius: 3))
            inside.draw(
              Text(String(seg.name.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.85)),
              at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
          }
          if rect.width > 28 {
            // `.pn-timeline-section { overflow: hidden }`: a label wider than its block is cut
            // at the block's edges, not spilled over its neighbours
            var inside = ctx
            inside.clip(to: Path(roundedRect: rect, cornerRadius: 3))
            let name = inside.resolve(
              Text(seg.name).font(.system(size: 9, weight: seg.isCurrent ? .bold : .regular))
                .foregroundColor(.white))
            // `.pn-timeline-phrases`: 8 px, 0.7 opacity, letter-spacing 1 px
            let letters = seg.phraseLabel.map {
              inside.resolve(
                Text($0).font(.system(size: 8)).tracking(1).foregroundColor(.white.opacity(0.7)))
            }
            let wide = CGSize(width: 10_000, height: size.height)
            let nameW = Double(name.measure(in: wide).width)
            let lettersW = letters.map { Double($0.measure(in: wide).width) }
            let run = SectionTimeline.LabelLayout.run(
              blockWidth: Double(rect.width), nameWidth: nameW, lettersWidth: lettersW)
            inside.draw(
              name, at: CGPoint(x: rect.minX + CGFloat(run.nameX), y: rect.midY), anchor: .leading)
            if let letters, let lx = run.lettersX {
              inside.draw(
                letters, at: CGPoint(x: rect.minX + CGFloat(lx), y: rect.midY), anchor: .leading)
            }
          }
        }
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
