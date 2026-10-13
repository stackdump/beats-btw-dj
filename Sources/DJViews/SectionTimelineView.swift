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
        var labels: [Label] = []
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
          if rect.width > 28 { labels.append(Self.layout(seg, in: rect, ctx: ctx)) }
        }
        let x = t.playhead * size.width
        // the line breaks where it crosses a name (its caps and stubs still mark the position)
        var spans: [ClosedRange<CGFloat>] = []
        var from: CGFloat = 0
        for l in labels.sorted(by: { $0.text.minY < $1.text.minY })
        where l.text.insetBy(dx: -2, dy: 0).contains(CGPoint(x: x, y: l.text.midY)) {
          spans.append(from...max(from, l.text.minY - 1))
          from = l.text.maxY + 1
        }
        spans.append(from...max(from, size.height))
        var head = Path()
        for s in spans where s.upperBound > s.lowerBound {
          head.move(to: CGPoint(x: x, y: s.lowerBound))
          head.addLine(to: CGPoint(x: x, y: s.upperBound))
        }
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
        for l in labels {
          // `.pn-timeline-section { overflow: hidden }`: a label wider than its block is cut
          // at the block's edges, not spilled over its neighbours
          var inside = ctx
          inside.clip(to: Path(roundedRect: l.block, cornerRadius: 3))
          // a soft dark halo: white names read on the pale blocks (a current buildup) too
          inside.addFilter(.shadow(color: .black.opacity(0.55), radius: 1.5))
          inside.draw(l.name, at: CGPoint(x: l.text.minX, y: l.block.midY), anchor: .leading)
          if let letters = l.letters, let lx = l.lettersX {
            inside.draw(letters, at: CGPoint(x: lx, y: l.block.midY), anchor: .leading)
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

  /// A block's label, laid out: its name (and phrase letters), and where the name's text sits.
  struct Label {
    var block: CGRect
    var name: GraphicsContext.ResolvedText
    var letters: GraphicsContext.ResolvedText?
    var lettersX: CGFloat?
    /// The name's text, vertically centred in the block.
    var text: CGRect
  }

  static func layout(_ seg: SectionTimeline.Segment, in rect: CGRect, ctx: GraphicsContext)
    -> Label
  {
    let name = ctx.resolve(
      Text(seg.name).font(.system(size: 9, weight: seg.isCurrent ? .bold : .regular))
        .foregroundColor(.white))
    // `.pn-timeline-phrases`: 8 px, 0.7 opacity, letter-spacing 1 px
    let letters = seg.phraseLabel.map {
      ctx.resolve(Text($0).font(.system(size: 8)).tracking(1).foregroundColor(.white.opacity(0.7)))
    }
    let wide = CGSize(width: 10_000, height: rect.height)
    let nameSize = name.measure(in: wide)
    let lettersW = letters.map { Double($0.measure(in: wide).width) }
    let run = SectionTimeline.LabelLayout.run(
      blockWidth: Double(rect.width), nameWidth: Double(nameSize.width), lettersWidth: lettersW)
    let text = CGRect(
      x: rect.minX + CGFloat(run.nameX), y: rect.midY - nameSize.height / 2,
      width: nameSize.width, height: nameSize.height)
    return Label(
      block: rect, name: name, letters: letters,
      lettersX: run.lettersX.map { rect.minX + CGFloat($0) },
      text: text)
  }
}
