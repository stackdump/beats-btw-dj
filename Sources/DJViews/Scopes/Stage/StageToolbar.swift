import DJCore
import SwiftUI

// StageToolbar: the Stage's controls (stage.js `.pn-stage-menu`), the stats pill and the help
// sheet, drawn above every layer. Part of the stage skeleton: every control exists from the start
// and writes its flag into `StageSettings`, so a layer that is still a placeholder simply has
// nothing to show yet. (A later mode never edits this file; the card button asks the card model
// whether it is usable.)
//
// Left to right, as in stage.js:
//   source A | B | Master      which deck(s) supply the panels (new: stage.js has one project)
//   visualizer select          Constellation, Corona, Sonar, Petal, Shuffle
//   ◌ flow  ◎ pulse  ▼ flame  ⊝ tilt        the four stackable overlays (`data-viz`)
//   ⇄ expand   ■ backs   A labels            panel variants, fills, names
//   ✎ card on change                          (disabled while the card layer is unavailable)
//   ⚡︎ bolts   ? help
//   background select          Void, Stars, Aurora
//   scale select               Fit, S, M, L, XL
//
// While a solo visualizer shows, the controls that only mean something for the constellation are
// hidden, exactly as the CSS `.viz-solo` rules do: the four overlays, expand, backs, labels,
// bolts and scale.
//
// NOT here, on purpose:
//   * the structure select ("Loop, A/B, Drop, ..."): in beats it regenerates the track with a new
//     arrangement; in this app that is the deck's own generator, and the stage window is a
//     read-only view of what the decks play;
//   * the Feel pad button (not a visualization; not part of this port);
//   * fullscreen and close: the window has its own (Esc also closes it).

struct StageChrome: View {
  let model: StageModel
  let context: StageContext
  @Binding var helpOpen: Bool

  var body: some View {
    let settings = model.settings
    ZStack {
      // Clicking the stage while the menu is open folds it again.
      if !settings.menuCollapsed {
        Color.clear.contentShape(Rectangle())
          .onTapGesture { settings.menuCollapsed = true }
      }

      VStack {
        HStack(alignment: .top) {
          if settings.menuCollapsed {
            Button {
              settings.menuCollapsed = false
            } label: {
              Text("•")
                .font(.system(size: 22))
                .foregroundStyle(Color(white: 0.93))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Menu")
            .accessibilityLabel("Open stage menu")
          } else {
            StageToolbar(model: model, context: context, helpOpen: $helpOpen)
          }
          Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        // `.pn-stage-burger` is at top 10px, `.pn-stage-menu` at 12px.
        .padding(.top, settings.menuCollapsed ? 10 : 12)
        Spacer(minLength: 0)
      }

      VStack {
        Spacer(minLength: 0)
        Text(context.stats)
          .font(.system(size: 11))
          .kerning(0.44)
          .foregroundStyle(Color.white.opacity(0.6))
          .lineLimit(1)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .background(Capsule().fill(Color.black.opacity(0.3)))
          .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
          .padding(.bottom, 18)
          .allowsHitTesting(false)
      }

      if helpOpen { StageHelpView(close: { helpOpen = false }) }
    }
  }
}

struct StageToolbar: View {
  let model: StageModel
  let context: StageContext
  @Binding var helpOpen: Bool

  private var solo: Bool { context.isSolo }

  var body: some View {
    let settings = model.settings
    HStack(spacing: 4) {
      // Source.
      ForEach(model.hub.sources, id: \.self) { source in
        StageToolPill(
          title: source == .master
            ? "Master" : source.label.replacingOccurrences(of: "Deck ", with: ""),
          active: settings.source == source, help: "Panels of \(source.label)"
        ) { settings.source = source }
      }
      divider

      StageSelect(
        title: settings.visualizer.title, options: StageVisualizer.allCases,
        label: \.title,
        selection: Binding(get: { settings.visualizer }, set: { settings.visualizer = $0 }),
        help: "Visualizer")

      if !solo {
        ForEach(StageToolAction.beforeCard, id: \.self) { action in
          toolButton(action, settings: settings)
        }
      }

      let cardOK = model.layers.card.isAvailable
      StageToolButton(
        glyph: StageToolAction.card.glyph, active: StageToolAction.card.isOn(settings) && cardOK,
        help: cardOK ? StageToolAction.card.help : model.layers.card.unavailableReason,
        enabled: cardOK
      ) { StageToolAction.card.toggle(settings) }

      if !solo { toolButton(.bolts, settings: settings) }
      StageToolButton(glyph: "?", active: helpOpen, help: "What am I looking at?") {
        helpOpen.toggle()
      }

      StageSelect(
        title: settings.bgMode.title, options: StageBackground.allCases, label: \.title,
        selection: Binding(get: { settings.bgMode }, set: { settings.bgMode = $0 }),
        help: "Background")
      if !solo {
        StageSelect(
          title: settings.scale.title, options: StageScale.allCases, label: \.title,
          selection: Binding(get: { settings.scale }, set: { settings.scale = $0 }),
          help: "Panel scale")
      }
    }
    .padding(4)
    .background(Capsule().fill(Color.black.opacity(0.35)))
    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    .fixedSize()
  }

  /// One of the round toggles; what it shows and does is the `StageToolAction` table.
  private func toolButton(_ action: StageToolAction, settings: StageSettings) -> some View {
    StageToolButton(glyph: action.glyph, active: action.isOn(settings), help: action.help) {
      action.toggle(settings)
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 2)
  }
}

/// A round 32-point toggle: dim glyph, white and blue-tinted while on
/// (`.pn-stage-menu button` / `.active`).
struct StageToolButton: View {
  let glyph: String
  let active: Bool
  let help: String
  var enabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(glyph)
        .font(.system(size: 18))
        .foregroundStyle(active ? Color.white : Color.white.opacity(enabled ? 0.55 : 0.25))
        .frame(width: 32, height: 32)
        .background(Circle().fill(active ? StagePalette.arc.withAlpha(0.22).color : .clear))
        .overlay(
          Circle().stroke(active ? StagePalette.arc.withAlpha(0.55).color : .clear, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A text pill for the source picker.
struct StageToolPill: View {
  let title: String
  let active: Bool
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Capsule().fill(active ? StagePalette.arc.withAlpha(0.22).color : .clear))
        .overlay(
          Capsule().stroke(active ? StagePalette.arc.withAlpha(0.55).color : .clear, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

/// The toolbar's selects (`.pn-stage-visualizer`, `-bgmode`, `-scale`): a pill that opens a menu.
struct StageSelect<Option: Hashable>: View {
  let title: String
  let options: [Option]
  let label: KeyPath<Option, String>
  @Binding var selection: Option
  let help: String

  var body: some View {
    Menu {
      ForEach(options, id: \.self) { option in
        Button(option[keyPath: label]) { selection = option }
      }
    } label: {
      Text(title)
        .font(.system(size: 12))
        .foregroundStyle(Color(white: 0.93))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }
    .menuStyle(.button)
    .menuIndicator(.visible)
    .buttonStyle(.plain)
    .fixedSize()
    .help(help)
  }
}

/// "What am I looking at?" (stage.js `openHelp`), cut to what this port has: a card over a dimmed
/// stage, scrolling when the window is short.
struct StageHelpView: View {
  let close: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.6).contentShape(Rectangle()).onTapGesture(perform: close)
      ScrollView {
        StageHelpContent(close: close).padding(22)
      }
      .frame(maxWidth: 560, maxHeight: 520)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.05, green: 0.05, blue: 0.1)))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
      .padding(24)
    }
  }
}

/// The help text itself (separate from the scroll view, which does not render offscreen).
struct StageHelpContent: View {
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Stage — what you're watching").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button(action: close) { Text("×").font(.system(size: 20)) }.buttonStyle(.plain)
      }
      Text(
        "Every shape on screen is part of one big Petri net — a visual grammar for rhythm. Tokens circulate; each firing is a note. The piece plays itself while you watch."
      )
      .foregroundStyle(Color(white: 0.8))

      section(
        "Reading the composition",
        [
          "Sub-rings (panels) — each is one track's one-bar pattern. Squares are transitions (the notes that fire); circles are places (state between firings); a blue dot in a place is a live token, with a count when there are several. Arrows are the flow of tokens.",
          "Meta-ring — the larger geometry connecting the panels (inner blue circles + radial arrows) is itself a Petri net: the whole Stage reads as N transitions ↔ N places around one giant loop.",
          "Dimmed panels — muted tracks. Arrangement control nets unmute variants over time; that's how a one-bar ring becomes a multi-bar song.",
          "⇄ Expand — shows every riff-group variant at once instead of one panel per logical track.",
        ])
      section(
        "Viz layers (stackable)",
        [
          "◌ Flow — each sub-ring spins at its own slow drift rate, clockwise or counter.",
          "◎ Pulse — every fired transition spawns a particle that falls toward the centre.",
          "▼ Flame — a narrow radial beam per panel, brightened by recent firings.",
          "⊝ Tilt — slow 3D perspective orbit of the whole Stage.",
        ])
      section(
        "Tools",
        [
          "Source — A, B or Master: which deck's nets (Master: both decks') become panels.",
          "■ Backs — panel background fills. A Labels — track names.",
          "Scale — Fit sizes the panels to the ring; S/M/L/XL force a size.",
          "Background — Void, Stars or Aurora.",
          "Track-change spin — the whole meta-diagram turns a quarter-turn on every new track.",
          "Esc — close the Stage.",
        ])
      section(
        "Theory",
        [
          "The dark planet at the centre of the meta-diagram is on purpose. It is the centre object — the piece itself — and the panels around it are all the ways that object reveals itself in play (the Yoneda lemma as ambient music: an object is fully determined by how every other object maps to it)."
        ])
    }
    .font(.system(size: 13))
    .foregroundStyle(Color(white: 0.85))
  }

  private func section(_ title: String, _ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white)
      ForEach(items, id: \.self) { item in
        Text("• " + item).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
