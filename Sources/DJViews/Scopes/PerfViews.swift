import DJCore
import SwiftUI

// The views of the adaptive visual level (SPEC mode 27): the quality menu, the notice raised when
// auto mode steps down, the environment that hands the hub to the drivers that have none of their
// own (the rings, the small animations), and the span helper that times a draw for the monitor.
//
//   VizQualityMenu(perf:)   Auto / Full / Reduced / Minimal / Paused. In the scope panel's header
//                           (a small pill, see `vizQualityBadge`) and the Stage's toolbar (a glyph).
//   VizNoticeView(perf:)    "Visuals reduced (reduced) to keep playback smooth · Keep full visuals"
//                           while `perf.notice` is up (8 s): a toast over the foot of the main window
//                           and of the Stage, where it takes room from nothing.
//   \.scopeHub              set on the main window by `ContentView`; `RingNetView`, `MacroButton` and
//                           `DeviceMapView` read it. Nil outside the app (tests, previews): they draw
//                           as before and report nothing.
//   VizSpan                 `let span = VizSpan(hub, .ring); defer { span.end() }` around a Canvas draw.
//   StageCanvas             the Stage layers' Canvas, booked as the `stage` path.
//
// Pinned beats sources: monitor.js `notify` (the toast and its "keep full visuals" link) and the
// bench modal's quality select (`.pn-bench-vizq`).

private struct ScopeHubKey: EnvironmentKey {
  static let defaultValue: ScopeHub? = nil
}

extension EnvironmentValues {
  /// The app's scope hub, for drivers that pace themselves by the visual level.
  var scopeHub: ScopeHub? {
    get { self[ScopeHubKey.self] }
    set { self[ScopeHubKey.self] = newValue }
  }
}

/// Times one draw for the perf monitor from a Canvas closure (which is not main-actor isolated in
/// the type system, though it runs on the main thread). A nil hub times nothing.
struct VizSpan {
  private let hub: ScopeHub?
  private let kind: VizKind
  private let t0: Double

  init(_ hub: ScopeHub?, _ kind: VizKind) {
    self.hub = hub
    self.kind = kind
    t0 = MainActor.assumeIsolated { hub?.perf.vizBegin() ?? 0 }
  }

  func end() {
    MainActor.assumeIsolated { hub?.perf.vizEnd(kind, t0) }
  }
}

/// A Stage layer's `Canvas`: the same canvas, with its draw booked to the monitor as the `stage`
/// path (stage.js times the whole tick, drawing included). The hub comes from the environment,
/// which `StageScene` sets; a canvas outside it draws as before and reports nothing. Layers
/// say `StageCanvas { gc, size in ... }` where they would say `Canvas { ... }`.
struct StageCanvas: View {
  @Environment(\.scopeHub) private var hub
  private let draw: @MainActor (inout GraphicsContext, CGSize) -> Void

  init(draw: @escaping @MainActor (inout GraphicsContext, CGSize) -> Void) { self.draw = draw }

  var body: some View {
    let hub = hub
    let draw = draw
    Canvas { ctx, size in
      MainActor.assumeIsolated {
        let span = VizSpan(hub, .stage)
        defer { span.end() }
        draw(&ctx, size)
      }
    }
  }
}

/// The preference menu's label: the choice, and for Auto the level it is at. Also the tooltip.
@MainActor func vizQualityTitle(_ perf: PerfMonitor) -> String {
  if perf.preference == .auto {
    return "Visuals: auto · \(VizLevels.name(perf.level))"
  }
  return "Visuals: \(perf.preference.title.lowercased())"
}

/// The panel header's face of the menu: just the glyph while everything is as usual (auto, at full),
/// the level when auto mode has stepped down, and the choice marked as pinned when the user made
/// one. The header has little room at the window's minimum width, so it only spends it when there
/// is something to tell; the full wording is the tooltip (`vizQualityTitle`).
@MainActor func vizQualityBadge(_ perf: PerfMonitor) -> String {
  switch perf.preference {
  case .auto: perf.level == 0 ? "◐" : "◐ \(VizLevels.name(perf.level))"
  default: "◐ \(perf.preference.title.lowercased()) (pinned)"
  }
}

/// Pick the visual quality: Auto lets the monitor step the level, the others pin it. Plain
/// SwiftUI `Menu`; reads the monitor's observable state, so its title follows the level.
struct VizQualityMenu: View {
  let perf: PerfMonitor
  /// The look: a small pill for the panel header, or the Stage toolbar's round glyph.
  var onDark = false

  var body: some View {
    Menu {
      ForEach(VizPreference.allCases, id: \.self) { p in
        Button {
          perf.setPreference(p)
        } label: {
          if p == perf.preference {
            Label(menuTitle(p), systemImage: "checkmark")
          } else {
            Text(menuTitle(p))
          }
        }
      }
    } label: {
      pill
    }
    .menuStyle(.button)
    .menuIndicator(.visible)
    .buttonStyle(.plain)
    .fixedSize()
    .help(
      vizQualityTitle(perf)
        + ". Auto reduces the visuals when drawing slows the app down. " + perf.summary)
  }

  /// The menu's face: a small pill in the panel header, a round 32 pt glyph button in the Stage's
  /// toolbar (a titled capsule would not fit the toolbar at the window's minimum width).
  @ViewBuilder private var pill: some View {
    if onDark {
      // lit while the visuals are not at full (pinned or stepped down), like the toolbar's toggles
      let lit = perf.level > 0 || perf.preference != .auto
      Text("◐")
        .font(.system(size: 18))
        .foregroundStyle(lit ? Color.white : Color.white.opacity(0.55))
        .frame(width: 32, height: 32)
        .background(Circle().fill(lit ? StagePalette.arc.withAlpha(0.22).color : .clear))
        .overlay(
          Circle().stroke(lit ? StagePalette.arc.withAlpha(0.55).color : .clear, lineWidth: 1))
    } else {
      Text(vizQualityBadge(perf))
        .font(.system(size: 11))
        .foregroundStyle(ScopeColors.text.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(ScopeColors.grid.color))
    }
  }

  private func menuTitle(_ p: VizPreference) -> String {
    switch p {
    case .auto: "Auto — reduce when the app lags"
    case .full: "Full"
    case .reduced: "Reduced — 15 fps scopes"
    case .minimal: "Minimal — 8 fps, no flashes"
    case .paused: "Paused — 4 fps"
    }
  }
}

/// monitor.js' toast: what happened, and the way back. A dark capsule with light text, to sit over
/// whatever is behind it; empty while there is no notice.
struct VizNoticeView: View {
  let perf: PerfMonitor

  var body: some View {
    if let n = perf.notice {
      HStack(spacing: 6) {
        Text(n.text).foregroundStyle(Color(white: 0.93))
        // a plain-SwiftUI button, so it also renders offscreen (the AppKit link style does not)
        Button {
          perf.keepFullVisuals()
        } label: {
          Text("Keep full visuals").underline()
            .foregroundStyle(Color(red: 0.49, green: 0.77, blue: 1))
        }
        .buttonStyle(.plain)
        .help("Pin the visuals to Full")
      }
      .font(.system(size: 11))
      .lineLimit(1)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Capsule().fill(Color.black.opacity(0.45)))
      .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
      .accessibilityElement(children: .combine)
    }
  }
}
