import AppKit
import DJCore
import SwiftUI

// A deck's controls beyond the always-visible core, as buttons in sections that fold. Every
// choice is on screen as a button (no dropdowns).

/// A deck's foldable sections: a strip of toggle buttons, one per section, each folding its
/// panel open or shut below the strip (several can be open). Which are open is remembered per
/// deck across launches (`fold.<deck>` in the app's defaults).
struct DeckSections: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color
  let importFile: () -> Void
  @AppStorage private var openList: String

  init(
    name: String, state: DeckState, model: AppModel, tint: Color,
    importFile: @escaping () -> Void
  ) {
    self.name = name
    self.state = state
    self.model = model
    self.tint = tint
    self.importFile = importFile
    _openList = AppStorage(wrappedValue: "perform", "fold.\(name)")
  }

  enum Section: String, CaseIterable {
    case perform, masterfx, track, favorites, generate, load
    var netOnly: Bool { [.perform, .masterfx, .track].contains(self) }
  }

  private var open: Set<String> { Set(openList.split(separator: ",").map(String.init)) }
  private func toggle(_ s: Section) {
    var o = open
    if o.contains(s.rawValue) { o.remove(s.rawValue) } else { o.insert(s.rawValue) }
    withAnimation(.snappy(duration: 0.15)) {
      openList = Section.allCases.map(\.rawValue).filter(o.contains).joined(separator: ",")
    }
  }

  private var shown: [Section] { Section.allCases.filter { state.isNet || !$0.netOnly } }

  private func label(_ s: Section) -> String {
    switch s {
    case .perform: return "Perform"
    case .masterfx: return state.masterRunning.isEmpty ? "Master FX" : "Master FX ●"
    case .track: return "Instruments"
    case .favorites: return model.favorites.isEmpty ? "★ Favorites" : "★ \(model.favorites.count)"
    case .generate: return "Generate"
    case .load: return "Load"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 4) {
        ForEach(shown, id: \.self) { s in
          Toggle(
            label(s), isOn: Binding(get: { open.contains(s.rawValue) }, set: { _ in toggle(s) })
          )
          .toggleStyle(.button).controlSize(.small)
          .help(open.contains(s.rawValue) ? "Fold \(label(s))" : "Show \(label(s))")
        }
      }
      ForEach(shown.filter { open.contains($0.rawValue) }, id: \.self) { s in
        panel(s)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
      }
    }
  }

  @ViewBuilder private func panel(_ s: Section) -> some View {
    switch s {
    case .perform: NetPanel(name: name, state: state, model: model, tint: tint)
    case .masterfx:
      MasterFxPanel(name: name, running: state.masterRunning, model: model, tint: tint)
    case .track: TrackPanel(name: name, state: state, model: model, tint: tint)
    case .favorites: FavoritesPanel(name: name, model: model, current: state.sourceCID)
    case .generate: GeneratePanel(name: name, model: model, tint: tint)
    case .load: LoadPanel(name: name, model: model, importFile: importFile)
    }
  }
}

/// One of a set of choices, lit while it is the current one.
struct ChoiceButton: View {
  let label: String
  let selected: Bool
  let tint: Color
  let action: () -> Void

  var body: some View {
    Toggle(label, isOn: Binding(get: { selected }, set: { _ in action() }))
      .toggleStyle(.button).controlSize(.small).tint(tint)
  }
}

struct LoadPanel: View {
  let name: String
  let model: AppModel
  let importFile: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 4) {
        Button("Audio file…", action: importFile)
        Button("Demo loop") { model.loadDemo(name) }
        Button("Paste share link") {
          model.loadShare(name, NSPasteboard.general.string(forType: .string) ?? "")
        }
        .help("A beats share link (or envelope JSON) from the clipboard")
      }
      .controlSize(.small)
    }
  }
}

struct GeneratePanel: View {
  let name: String
  let model: AppModel
  let tint: Color
  @State private var genre = "techno"
  @State private var structure = "standard"
  @State private var seed = String(Int.random(in: 1...999_999))
  @State private var cohesion = "v2"
  @State private var autoAdvance = false

  private var spec: TrackSpec {
    TrackSpec(
      genre: genre, seed: Double(seed) ?? 1, structure: structure == "loop" ? nil : structure,
      cohesion: cohesion)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 4) {
        ForEach(BeatsTables.shared.genreIDs, id: \.self) { g in
          ChoiceButton(label: g, selected: genre == g, tint: tint) { genre = g }
        }
      }
      FlowRow(spacing: 4) {
        ForEach(["loop", "minimal", "standard", "extended"], id: \.self) { s in
          ChoiceButton(label: s, selected: structure == s, tint: tint) { structure = s }
        }
      }
      HStack(spacing: 4) {
        ChoiceButton(label: "v2 motif", selected: cohesion == "v2", tint: tint) { cohesion = "v2" }
          .help("Cohesion v2: motif + harmony")
        ChoiceButton(label: "v1 legacy", selected: cohesion == "v1", tint: tint) { cohesion = "v1" }
        Spacer()
        TextField("Seed", text: $seed).frame(width: 70).controlSize(.small)
        Button("Roll") { seed = String(Int.random(in: 1...999_999)) }.controlSize(.small)
      }
      HStack(spacing: 4) {
        ChoiceButton(label: "Auto-next", selected: autoAdvance, tint: tint) { autoAdvance.toggle() }
          .help("Start the next track when this one ends")
        Spacer()
        Button("Queue next") {
          model.queueNext(name, spec)
          model.setAutoAdvance(name, autoAdvance)
        }
        Button("Generate now") {
          model.generate(name, spec)
          model.setAutoAdvance(name, autoAdvance)
        }
        .buttonStyle(.borderedProminent).tint(tint)
      }
      .controlSize(.small)
    }
  }
}

struct FavoritesPanel: View {
  let name: String
  let model: AppModel
  let current: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.favorites.isEmpty {
        Text("Star a playing track (☆ by its title) to keep it here.")
          .font(.caption).foregroundStyle(.secondary)
      }
      FlowRow(spacing: 4) {
        ForEach(model.favorites, id: \.cid) { f in
          Button(f.title) { model.loadFavorite(name, f) }
            .controlSize(.small)
            .tint(f.cid == current ? .yellow : nil)
            .contextMenu { Button("Remove from favorites") { model.removeFavorite(cid: f.cid) } }
            .help("Load onto deck \(name) (right-click to remove)")
        }
      }
    }
  }
}

/// Copy the track to the other deck, and pick each role's instrument.
struct TrackPanel: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  var body: some View {
    let other = name == "A" ? "B" : "A"
    VStack(alignment: .leading, spacing: 6) {
      Button("Copy to deck \(other)") { Task { await model.copyDeck(from: name, to: other) } }
        .controlSize(.small)
        .help("Load this track, with its instrument changes, onto deck \(other)")
      ForEach(state.voices, id: \.channel) { v in
        VStack(alignment: .leading, spacing: 3) {
          Text(v.role).font(.caption2).foregroundStyle(.secondary)
          FlowRow(spacing: 4) {
            ForEach(v.options, id: \.self) { i in
              ChoiceButton(label: i, selected: i == v.instrument, tint: tint) {
                guard i != v.instrument else { return }
                Task { await model.setInstrument(name, channel: v.channel, i) }
              }
            }
          }
        }
      }
      if !state.voices.isEmpty {
        Text("Changing one reloads the track from its start: tweak the deck that isn't live.")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }
}

/// The master chain's macros (beats' FX, Pitch and Feel groups), lit while in effect.
struct MasterFxPanel: View {
  let name: String
  let running: Set<MasterMacro>
  let model: AppModel
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(["FX", "Pitch", "Feel"], id: \.self) { group in
        VStack(alignment: .leading, spacing: 3) {
          Text(group).font(.caption2).foregroundStyle(.secondary)
          FlowRow(spacing: 4) {
            ForEach(MasterMacro.allCases.filter { $0.group == group }, id: \.rawValue) { m in
              ChoiceButton(label: m.label, selected: running.contains(m), tint: tint) {
                model.fire(name, m)
              }
            }
          }
        }
      }
    }
  }
}
