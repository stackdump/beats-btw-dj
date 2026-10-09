import DJCore
import SwiftUI

// SPEC mode 26 on screen: the chase over a deck's role toggles and the running state of the
// macro buttons. The state is `MacroPulseState` (DJCore); this file only draws it, in beats'
// numbers (`MacroPulseStyle`).

extension ScopeColor {
  fileprivate var pulseColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// A CSS `box-shadow: 0 0 <blur>px <spread>px rgba(233, 69, 96, <alpha>)` behind a control: the
/// control's rounded rectangle grown by `spread`, filled, and blurred (a CSS blur of `B` px is a
/// Gaussian of sigma `B / 2`).
struct PulseGlow: View {
  var glow: MacroPulseStyle.Glow
  var cornerRadius: CGFloat = 5

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .inset(by: -CGFloat(glow.spread))
      .fill(MacroPulseStyle.color.withAlpha(glow.alpha).pulseColor)
      .blur(radius: CGFloat(glow.blur) / 2)
  }
}

/// `.pn-pulsing` / `.pn-pulsing-hot` on a control; eased over 120 ms as `transition: box-shadow
/// 0.12s ease-out` does.
struct MacroPulseGlowModifier: ViewModifier {
  var level: MacroPulseLevel

  func body(content: Content) -> some View {
    content
      .background {
        if let g = MacroPulseStyle.glow(level) { PulseGlow(glow: g) }
      }
      .animation(.easeOut(duration: 0.12), value: level)
  }
}

extension View {
  /// Light a control as a running macro's chase does.
  func macroPulseGlow(_ level: MacroPulseLevel) -> some View {
    modifier(MacroPulseGlowModifier(level: level))
  }
}

/// A macro's button: an ordinary small button, and while the engine says the macro is in effect
/// the `.pn-macro-btn.running` look: `#e94560` fill, white text, a pale border, and a glow that
/// breathes on a 1 s ease-in-out cycle. `time` pins the cycle for a snapshot; nil follows the
/// clock (a timeline runs only while the macro does).
struct MacroButton: View {
  let macro: NetMacro
  let running: Bool
  var time: Double?
  let fire: () -> Void
  /// The glow breathes at 30 fps, never faster than the visual level allows (SPEC mode 27).
  @Environment(\.scopeHub) private var hub

  init(macro: NetMacro, running: Bool, time: Double? = nil, fire: @escaping () -> Void) {
    self.macro = macro
    self.running = running
    self.time = time
    self.fire = fire
  }

  var body: some View {
    if running {
      if let time {
        runningButton(at: time)
      } else {
        TimelineView(.animation(minimumInterval: hub?.interval(cappedAt: 1.0 / 30) ?? 1.0 / 30)) {
          tl in
          runningButton(at: tl.date.timeIntervalSinceReferenceDate)
        }
      }
    } else {
      Button(macro.label, action: fire).controlSize(.small)
    }
  }

  private func runningButton(at t: Double) -> some View {
    Button(macro.label, action: fire)
      .buttonStyle(.borderedProminent)
      .tint(MacroPulseStyle.runningFill.pulseColor)
      .controlSize(.small)
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(MacroPulseStyle.runningBorder.pulseColor, lineWidth: 1)
      )
      .background { PulseGlow(glow: MacroPulseStyle.runningGlow(at: t)) }
  }
}
