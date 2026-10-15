import SwiftUI

/// The main window's shared look: one spacing scale, one card shape, the deck tints. Views
/// take sizes from here instead of literals, so the deck columns, the mixer and their rows
/// line up.
enum DJStyle {
  /// Spacing scale (pt).
  static let xs: CGFloat = 4
  static let s: CGFloat = 8
  static let m: CGFloat = 12
  static let l: CGFloat = 16
  static let xl: CGFloat = 24

  static let cardRadius: CGFloat = 12
  static let cardPadding: CGFloat = 14

  /// Deck tints, bright enough to read as text and dots on the dark window.
  static let deckA = Color(red: 1.0, green: 0.62, blue: 0.22)
  static let deckB = Color(red: 0.30, green: 0.82, blue: 1.0)

  /// Small caps label over a group ("MIXER", "PERFORM").
  static let sectionLabel = Font.caption2.weight(.semibold)
  /// The numbers a DJ reads at a glance: position, tempo.
  static let readout = Font.system(.title3, design: .rounded).monospacedDigit().weight(.semibold)
}

/// A rounded card behind a panel, with a thin accent line in its tint along the top.
struct DJCard: ViewModifier {
  var tint: Color?

  func body(content: Content) -> some View {
    content
      .padding(DJStyle.cardPadding)
      .background {
        RoundedRectangle(cornerRadius: DJStyle.cardRadius, style: .continuous)
          .fill(Color.primary.opacity(0.045))
      }
      .overlay {
        RoundedRectangle(cornerRadius: DJStyle.cardRadius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
      }
      .overlay(alignment: .top) {
        if let tint {
          Capsule().fill(tint).frame(height: 3).padding(.horizontal, DJStyle.cardRadius)
        }
      }
  }
}

extension View {
  func djCard(tint: Color? = nil) -> some View { modifier(DJCard(tint: tint)) }
}

/// "MIXER", "PERFORM": the small label over a group of controls.
struct SectionLabel: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased()).font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The deck's letter in a filled circle of its tint.
struct DeckBadge: View {
  let name: String
  let tint: Color

  var body: some View {
    Text(name).font(.system(.headline, design: .rounded).weight(.bold)).foregroundStyle(.black)
      .frame(width: 28, height: 28).background(Circle().fill(tint))
      .accessibilityLabel("Deck \(name)")
  }
}

/// The transport's play / pause: a round button, filled in the deck's tint while playing.
struct TransportButtonStyle: ButtonStyle {
  var tint: Color
  var active: Bool
  var size: CGFloat = 40

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size * 0.38, weight: .bold))
      .foregroundStyle(active ? .black : tint)
      .frame(width: size, height: size)
      .background(Circle().fill(active ? tint : tint.opacity(0.14)))
      .overlay(Circle().strokeBorder(tint.opacity(active ? 0 : 0.6), lineWidth: 1.5))
      .scaleEffect(configuration.isPressed ? 0.93 : 1)
      .animation(.snappy(duration: 0.15), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.2), value: active)
      .contentShape(Circle())
  }
}

/// The window's root: fills whatever size it is given and reports a fixed minimum (and no
/// alignment guides) without measuring its content. AppKit asks the root for the window's
/// minimum size, and its alignment, on every display cycle; answered by the content, that measured the whole window (both deck layouts, the scroll
/// fallback, every button row) each frame, which took most of the main thread and made the
/// visuals stutter.
public struct WindowRoot: Layout {
  public var minSize: CGSize
  public var idealSize: CGSize

  public init(minSize: CGSize, idealSize: CGSize) {
    self.minSize = minSize
    self.idealSize = idealSize
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ())
    -> CGSize
  {
    func side(_ p: CGFloat?, _ lo: CGFloat, _ ideal: CGFloat) -> CGFloat {
      guard let p else { return ideal }
      return p.isFinite ? max(lo, p) : .greatestFiniteMagnitude
    }
    return CGSize(
      width: side(proposal.width, minSize.width, idealSize.width),
      height: side(proposal.height, minSize.height, idealSize.height))
  }

  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for s in subviews { s.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
  }

  // The window asks its root for alignment guides every frame too, and the default answer lays
  // the content out to find its children's: the root has none of its own.
  public func explicitAlignment(
    of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()
  ) -> CGFloat? { nil }

  public func explicitAlignment(
    of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()
  ) -> CGFloat? { nil }
}
