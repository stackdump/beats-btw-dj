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
    case perform, masterfx, reverb, track, favorites, generate, load
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
    case .reverb: return state.reverb.isOn ? "Reverb ●" : "Reverb"
    case .track: return "Instruments"
    case .favorites: return model.favorites.isEmpty ? "★ Favorites" : "★ \(model.favorites.count)"
    case .generate: return "Generate"
    case .load: return "Load"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      FlowRow(spacing: DJStyle.xs) {
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
          .padding(.horizontal, DJStyle.s).padding(.vertical, DJStyle.xs)
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
    case .reverb: ReverbPanel(name: name, reverb: state.reverb, model: model, tint: tint)
    case .track: TrackPanel(name: name, state: state, model: model, tint: tint)
    case .favorites: FavoritesPanel(name: name, model: model, current: state.sourceCID)
    case .generate: GeneratePanel(name: name, model: model, tint: tint)
    case .load: LoadPanel(name: name, model: model, tint: tint, importFile: importFile)
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
  let tint: Color
  let importFile: () -> Void
  @State private var query = ""
  @State private var category = ""
  /// The list, recomputed only when what it depends on changes (`Filter`), off the main thread:
  /// filtering and sorting ~15k loops on every poll would cost the main thread again.
  @State private var hits: [StockLoop] = []

  struct Filter: Equatable {
    var category: String
    var query: String
    var tempo: Int?
    var count: Int
  }

  /// How many matches the list shows at first, and adds per "Show more" (the nearest in tempo
  /// first, then A–Z): enough to browse, few enough to lay out at once.
  static let shown = 150
  /// How many it shows now; back to `shown` whenever the filter changes.
  @State private var limit = LoadPanel.shown

  var body: some View {
    VStack(alignment: .leading, spacing: DJStyle.s) {
      FlowRow(spacing: DJStyle.xs) {
        Button("Audio file…", action: importFile)
        Button("Demo loop") { model.loadDemo(name) }
        Button("Paste share link") {
          model.loadShare(name, NSPasteboard.general.string(forType: .string) ?? "")
        }
        .help("A beats share link (or envelope JSON) from the clipboard")
      }
      .controlSize(.small)
      stockLoops
    }
    .task { await model.loadStockLoops() }
  }

  @ViewBuilder private var stockLoops: some View {
    let all = model.stockLoops
    let tempo = model.loopTempo(for: name)
    let filter = Filter(
      category: category, query: query, tempo: tempo.map { Int($0.rounded()) }, count: all.count)
    HStack(spacing: DJStyle.xs) {
      SectionLabel("Stock loops")
      Spacer()
      Text(
        model.stockLoopsLoading
          ? "scanning…"
          : all.isEmpty
            ? "none installed"
            : tempo.map { String(format: "%d · nearest %.0f BPM", hits.count, $0) }
              ?? "\(hits.count)"
      )
      .font(.caption2).foregroundStyle(.secondary)
    }
    if !all.isEmpty {
      TextField("Search loops (name, pack, genre)", text: $query)
        .textFieldStyle(.roundedBorder).controlSize(.small)
      FlowRow(spacing: DJStyle.xs) {
        ChoiceButton(label: "All", selected: category.isEmpty, tint: tint) { category = "" }
        ForEach(all.categories, id: \.self) { c in
          ChoiceButton(label: c, selected: category == c, tint: tint) {
            category = category == c ? "" : c
          }
        }
      }
      .arrowKeys([""] + all.categories, current: category) { category = $0 }
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(hits.prefix(limit), id: \.path) { loop in
            StockLoopRow(loop: loop, tint: tint) {
              Task { await model.loadStockLoop(name, loop) }
            }
          }
          // never a silent cut: say what is left and let it be shown
          if hits.count > limit {
            HStack(spacing: DJStyle.s) {
              Text("\(hits.count - limit) more")
                .font(.caption2).foregroundStyle(.secondary)
              Button("Show \(min(Self.shown, hits.count - limit)) more") { limit += Self.shown }
                .controlSize(.small)
              Text("or search / pick a category").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, DJStyle.xs)
          }
        }
      }
      .frame(height: 220)
      // over the list, the arrows load the loop before / after the one on the deck: audition
      // through the list without clicking
      .arrowKeys(
        Array(hits.prefix(limit)).map(\.path),
        current: hits.first { $0.name == model.decks[name]?.title }?.path
      ) { path in
        if let loop = hits.first(where: { $0.path == path }) {
          Task { await model.loadStockLoop(name, loop) }
        }
      }
      .task(id: filter) {
        limit = Self.shown
        let near = filter.tempo.map(Double.init)
        hits = await Task.detached(priority: .userInitiated) {
          all.matching(category: filter.category, query: filter.query, near: near)
        }.value
      }
    }
  }
}

/// One loop in the list: its name, then tempo, key and what it is. Pressing it loads the loop.
struct StockLoopRow: View {
  let loop: StockLoop
  let tint: Color
  let load: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: load) {
      HStack(spacing: DJStyle.s) {
        Text(loop.name).font(.caption).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: DJStyle.xs)
        Text(String(format: "%.0f", loop.bpm)).font(.caption.monospacedDigit())
          .foregroundStyle(tint)
        if let key = loop.key {
          Text(key).font(.caption2).foregroundStyle(.secondary)
        }
        Text(loop.subcategory.isEmpty ? loop.category : loop.subcategory)
          .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
      }
      .padding(.horizontal, DJStyle.xs).padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 4).fill(hover ? tint.opacity(0.18) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help("\(loop.pack) · \(loop.genre) · \(loop.beats) beats — load onto this deck")
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
  static let structures = ["loop", "minimal", "standard", "extended"]

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
      .arrowKeys(BeatsTables.shared.genreIDs, current: genre) { genre = $0 }
      FlowRow(spacing: 4) {
        ForEach(Self.structures, id: \.self) { s in
          ChoiceButton(label: s, selected: structure == s, tint: tint) { structure = s }
        }
      }
      .arrowKeys(Self.structures, current: structure) { structure = $0 }
      HStack(spacing: 4) {
        HStack(spacing: 4) {
          ChoiceButton(label: "v2 motif", selected: cohesion == "v2", tint: tint) {
            cohesion = "v2"
          }
          .help("Cohesion v2: motif + harmony")
          ChoiceButton(label: "v1 legacy", selected: cohesion == "v1", tint: tint) {
            cohesion = "v1"
          }
        }
        .arrowKeys(["v2", "v1"], current: cohesion) { cohesion = $0 }
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
    let tags = model.favorites.allTags
    let shown = model.favorites.tagged(model.favoriteTag)
    VStack(alignment: .leading, spacing: 6) {
      if model.favorites.isEmpty {
        Text("Star what a deck plays (☆ by its title) — a track or a sample — to keep it here.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !tags.isEmpty {
        FlowRow(spacing: 4) {
          ChoiceButton(label: "All", selected: model.favoriteTag == nil, tint: .yellow) {
            model.favoriteTag = nil
          }
          ForEach(tags, id: \.self) { t in
            ChoiceButton(label: "#\(t)", selected: model.favoriteTag == t, tint: .yellow) {
              model.favoriteTag = model.favoriteTag == t ? nil : t
            }
          }
        }
        .arrowKeys([nil] + tags.map { Optional($0) }, current: model.favoriteTag) {
          model.favoriteTag = $0
        }
      }
      FlowRow(spacing: 4) {
        ForEach(shown, id: \.cid) { f in
          FavoriteChip(favorite: f, deck: name, model: model, isCurrent: f.cid == current)
        }
      }
      .arrowKeys(shown.map(\.cid), current: current) { cid in
        if let f = shown.first(where: { $0.cid == cid }) { model.loadFavorite(name, f) }
      }
    }
  }
}

/// One favorite: press to load it; its tags beside it; right-click to tag or remove it.
struct FavoriteChip: View {
  let favorite: Favorite
  let deck: String
  let model: AppModel
  let isCurrent: Bool
  @State private var tagging = false

  var body: some View {
    Button {
      model.loadFavorite(deck, favorite)
    } label: {
      HStack(spacing: 3) {
        Image(systemName: favorite.isSample ? "waveform" : "point.3.connected.trianglepath.dotted")
          .font(.caption2)
        Text(favorite.title)
        ForEach(favorite.tags, id: \.self) { t in
          Text("#\(t)").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .controlSize(.small)
    .tint(isCurrent ? .yellow : nil)
    .contextMenu {
      Button("Tags…") { tagging = true }
      Button("Remove from favorites") { model.removeFavorite(cid: favorite.cid) }
    }
    .popover(isPresented: $tagging) {
      TagEditor(tags: favorite.tags, known: model.favorites.allTags) {
        model.setFavoriteTags(favorite.cid, $0)
      }
    }
    .help(
      (favorite.isSample ? "Sample: \(favorite.file ?? "")" : "Net track")
        + " — load onto deck \(deck) (right-click: tags, remove)")
  }
}

/// Add and remove a favorite's tags: the ones it has (click to drop), the ones used
/// elsewhere (click to add), and a field for a new one.
struct TagEditor: View {
  let tags: [String]
  let known: [String]
  let set: ([String]) -> Void
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tags").font(.headline)
      if !tags.isEmpty {
        FlowRow(spacing: 4) {
          ForEach(tags, id: \.self) { t in
            Button("#\(t) ✕") { set(tags.filter { $0 != t }) }.controlSize(.small)
              .help("Remove this tag")
          }
        }
      }
      let others = known.filter { !tags.contains($0) }
      if !others.isEmpty {
        Text("Used elsewhere").font(.caption2).foregroundStyle(.secondary)
        FlowRow(spacing: 4) {
          ForEach(others, id: \.self) { t in
            Button("+ #\(t)") { set(tags + [t]) }.controlSize(.small)
          }
        }
      }
      TextField("New tag (Return to add)", text: $draft)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          let t = draft.trimmingCharacters(in: .whitespaces)
          if !t.isEmpty { set(tags + [t]) }
          draft = ""
        }
    }
    .padding(12).frame(width: 260)
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
          .arrowKeys(v.options, current: v.instrument) { i in
            Task { await model.setInstrument(name, channel: v.channel, i) }
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
/// The channel's reverb (`DeckReverb`): a few starting points, then the three knobs.
struct ReverbPanel: View {
  let name: String
  let reverb: ReverbState
  let model: AppModel
  let tint: Color

  static let presets: [(label: String, value: ReverbState)] = [
    ("Off", ReverbState(wet: 0, size: 0.5, tone: 0.5)),
    ("Room", ReverbState(wet: 0.2, size: 0.25, tone: 0.5)),
    ("Plate", ReverbState(wet: 0.25, size: 0.45, tone: 0.85)),
    ("Hall", ReverbState(wet: 0.3, size: 0.7, tone: 0.6)),
    ("Wash", ReverbState(wet: 0.55, size: 0.95, tone: 0.4)),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 4) {
        ForEach(Self.presets, id: \.label) { p in
          ChoiceButton(
            label: p.label, selected: p.value.isOn == reverb.isOn && p.value.near(reverb),
            tint: tint
          ) { model.setReverb(name, p.value) }
        }
      }
      .arrowKeys(
        Self.presets.map(\.label),
        current: Self.presets.first { $0.value.isOn == reverb.isOn && $0.value.near(reverb) }?.label
      ) { label in
        if let p = Self.presets.first(where: { $0.label == label }) {
          model.setReverb(name, p.value)
        }
      }
      LabeledSlider(
        label: String(format: "Wet %.0f%%", reverb.wet * 100),
        value: Binding(get: { reverb.wet }, set: { model.setReverb(name, "reverbWet", $0) }),
        range: 0...1)
      LabeledSlider(
        label: String(format: "Size %.1f s", reverb.decaySeconds),
        value: Binding(get: { reverb.size }, set: { model.setReverb(name, "reverbSize", $0) }),
        range: 0...1)
      LabeledSlider(
        label: reverb.tone < 0.35 ? "Tone dark" : (reverb.tone > 0.65 ? "Tone bright" : "Tone"),
        value: Binding(get: { reverb.tone }, set: { model.setReverb(name, "reverbTone", $0) }),
        range: 0...1)
      Text("After the EQ, before the fader. LOOP record takes stay dry.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }
}

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
              .lockable(DJActionKind.lockKey(deck: name, .macro, param: m.id), model)
            }
          }
        }
      }
    }
  }
}
