import SwiftUI

// The djandroid design system's tokens (djandroid-vevr-se docs/DESIGN.md §5, ui/Theme.kt), so
// the Apple port reads the same. No raw colours outside this file.

public enum DJTheme {
  /// djrust orange: active, selected, primary buttons, live indicators, the wordmark.
  public static let accent = Color(rgb: 0xF08A3C)
  /// The app background.
  public static let surface0 = Color(rgb: 0x141416)
  /// Cards, sheets.
  public static let surface1 = Color(rgb: 0x1E1E22)
  /// Pads at rest, tracks, chips, selected tab, dividers.
  public static let surface2 = Color(rgb: 0x2A2A30)
  /// Secondary text, captions, card titles, inactive icons.
  public static let dim = Color(rgb: 0x8A8A94)
  /// Locked roles, muted, failed.
  public static let danger = Color(rgb: 0xE5484D)

  /// One colour per section kind, so the ring reads at a glance.
  public static func sectionColor(_ name: String) -> Color {
    switch true {
    case name.hasPrefix("intro"), name.hasPrefix("outro"): Color(rgb: 0x5B7DB1)
    case name.hasPrefix("verse"): Color(rgb: 0x6E9E7A)
    case name.hasPrefix("chorus"): accent
    case name.hasPrefix("drop"): Color(rgb: 0xE0554F)
    case name.hasPrefix("build"): Color(rgb: 0xD9B44A)
    case name.hasPrefix("break"): Color(rgb: 0x9A7BC8)
    default: Color(rgb: 0x7A7A85)
    }
  }
}

extension Color {
  init(rgb: UInt32) {
    self.init(
      red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255)
  }
}

/// The card every performance-screen control lives in (DESIGN §5.3): Surface1, radius 20,
/// padding 16, 12 between rows, an uppercase Dim title and an optional trailing slot.
struct Card<Trailing: View, Content: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
    self.title = title
    self.trailing = trailing()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title.uppercased()).font(.system(size: 12)).tracking(1.2).foregroundStyle(DJTheme.dim)
        Spacer()
        trailing
      }
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DJTheme.surface1, in: RoundedRectangle(cornerRadius: 20))
  }
}

extension Card where Trailing == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, trailing: { EmptyView() }, content: content)
  }
}

/// One of a few (FilterChip): Accent with a black label when selected, Surface2 otherwise.
struct Chip: View {
  let label: String
  var selected: Bool
  var enabled = true
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label).font(.system(size: 14)).lineLimit(1)
        .padding(.horizontal, 14).frame(minHeight: 36)
        .foregroundStyle(selected ? Color.black : (enabled ? Color.white : DJTheme.dim))
        .background(selected ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// djrust's switch: Accent when on, named for VoiceOver.
struct DJToggle: View {
  let label: String
  @Binding var isOn: Bool
  var body: some View {
    Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(DJTheme.accent)
      .accessibilityLabel(label)
  }
}

/// A slider's taper (djandroid ui/Taper.kt): thumb position 0…1 ↔ value.
enum Fader {
  /// A volume fader's gain 0…1 by square law: ½ is −12 dB, the fade spread over the travel.
  static func toPos(_ v: Double) -> Double { max(0, min(1, v)).squareRoot() }
  static func fromPos(_ p: Double) -> Double { let c = max(0, min(1, p)); return c * c }
}

/// A fine slider under a primary one whose useful values sit at one end (DESIGN §2, "Fine
/// sliders"): spans only that end; outside it the thumb waits, dimmed, at its near end.
struct FineSlider: View {
  let description: String
  let value: Double
  let range: ClosedRange<Double>
  let caption: String
  /// Labels under points of the track (the sync slider's doublings).
  var marks: [(Double, String)] = []
  var enabled = true
  /// The thumb let go.
  var onDone: (() -> Void)?
  var onChange: (Double) -> Void

  var body: some View {
    let inside = enabled && range.contains(value)
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 0) {
        Text("fine").font(.system(size: 11)).foregroundStyle(DJTheme.dim).frame(width: 32, alignment: .leading)
        Slider(
          value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: onChange),
          in: range,
          onEditingChanged: { if !$0 { onDone?() } }
        )
        .tint(inside ? DJTheme.accent : DJTheme.dim)
        .disabled(!enabled)
        .accessibilityLabel("\(description), fine")
      }
      if !marks.isEmpty {
        // each label centred under its point on the track (inset by about half the thumb)
        GeometryReader { g in
          let inset: CGFloat = 12
          ForEach(marks.indices, id: \.self) { i in
            let f = (marks[i].0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            Text(marks[i].1).font(.system(size: 11)).foregroundStyle(DJTheme.dim).fixedSize()
              .position(x: inset + (g.size.width - 2 * inset) * f, y: g.size.height / 2)
          }
        }
        .frame(height: 14).padding(.leading, 32)
      }
      Text(caption).font(.system(size: 11)).foregroundStyle(DJTheme.dim).padding(.leading, 32)
    }
  }
}

/// Chips and pads that wrap onto the next line (Compose's FlowRow).
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews)
    let h = rows.last.map { $0.y + $0.height } ?? 0
    let w = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? w, height: h)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for row in arrange(width: bounds.width, subviews) {
      var x = bounds.minX
      for i in row.items {
        let s = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
        x += s.width + spacing
      }
    }
  }

  private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var cur = Row()
    for (i, v) in subviews.enumerated() {
      let s = v.sizeThatFits(.unspecified)
      if !cur.items.isEmpty && cur.width + spacing + s.width > width {
        let y = cur.y + cur.height + spacing
        rows.append(cur)
        cur = Row(y: y)
      }
      cur.width += (cur.items.isEmpty ? 0 : spacing) + s.width
      cur.height = max(cur.height, s.height)
      cur.items.append(i)
    }
    if !cur.items.isEmpty { rows.append(cur) }
    return rows
  }
}
