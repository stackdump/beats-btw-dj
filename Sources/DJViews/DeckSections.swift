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
    case perform, wander, masterfx, reverb, track, favorites, generate, load, notes, history
    var netOnly: Bool { [.perform, .wander, .masterfx, .track].contains(self) }
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
    case .wander:
      return !state.wander.on ? "Wander" : (state.wander.paused ? "Wander ⏸" : "Wander ●")
    case .masterfx: return state.masterRunning.isEmpty ? "Master FX" : "Master FX ●"
    case .reverb: return state.reverb.isOn ? "Reverb ●" : "Reverb"
    case .track: return "Sound"
    case .favorites: return model.favorites.isEmpty ? "★ Favorites" : "★ \(model.favorites.count)"
    case .generate: return "Generate"
    case .load: return "Load"
    case .notes:
      let n = model.deckNotes(name).count
      return n == 0 ? "✎ Notes" : "✎ \(n)"
    case .history: return "History"
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
    case .wander: WanderPanel(name: name, state: state, model: model, tint: tint)
    case .masterfx:
      MasterFxPanel(name: name, running: state.masterRunning, model: model, tint: tint)
    case .reverb: ReverbPanel(name: name, reverb: state.reverb, model: model, tint: tint)
    case .track: TrackPanel(name: name, state: state, model: model, tint: tint)
    case .favorites: FavoritesPanel(name: name, model: model, current: state.sourceCID)
    case .generate: GeneratePanel(name: name, model: model, tint: tint)
    case .load: LoadPanel(name: name, model: model, tint: tint, importFile: importFile)
    case .notes: NotesPanel(name: name, model: model, tint: tint)
    case .history: HistoryPanel(model: model)
    }
  }
}

/// One of a set of choices, lit while it is the current one.
struct ChoiceButton: View {
  let label: String
  let selected: Bool
  let tint: Color
  /// A performance control (Master FX macros): live-button size, one line, never truncated.
  var live = false
  let action: () -> Void

  var body: some View {
    let toggle = Toggle(label, isOn: Binding(get: { selected }, set: { _ in action() }))
      .toggleStyle(.button).tint(tint)
    if live { toggle.liveButton() } else { toggle.controlSize(.small) }
  }
}

struct LoadPanel: View {
  let name: String
  let model: AppModel
  let tint: Color
  let importFile: () -> Void
  @State private var query = ""
  @State private var category = ""
  /// The crate shown instead of the stock loops (nil: the stock loops).
  @State private var crate: String?
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
      CrateBar(model: model, tint: tint, shown: $crate)
      if let crate {
        crateList(crate)
      } else {
        stockLoops
      }
    }
    .task { await model.loadStockLoops() }
  }

  /// A crate's loops: press to load; right-click to take one out.
  @ViewBuilder private func crateList(_ crate: String) -> some View {
    let items = model.favorites.tagged(crate)
    HStack(spacing: DJStyle.xs) {
      SectionLabel("Crate · \(crate)")
      Spacer()
      Text("\(items.count)").font(.caption2).foregroundStyle(.secondary)
    }
    if items.isEmpty {
      Text("Empty: drag stock loops onto the crate's chip.")
        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(items, id: \.cid) { f in
            Group {
              if let file = f.file, let loop = model.stockLoops.first(where: { $0.path == file }) {
                StockLoopRow(loop: loop, tint: tint) { model.loadFavorite(name, f) }
              } else {
                Button(f.title) { model.loadFavorite(name, f) }.buttonStyle(.plain).font(.caption)
                  .padding(.horizontal, DJStyle.xs).padding(.vertical, 3)
              }
            }
            .contextMenu {
              Button("Remove from \(crate)") { model.removeFromCrate(f.cid, crate) }
            }
          }
        }
      }
      .frame(height: 220)
      .arrowKeys(
        items.map(\.cid), current: model.decks[name]?.sourceCID
      ) { cid in
        if let f = items.first(where: { $0.cid == cid }) { model.loadFavorite(name, f) }
      }
    }
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
      // samples and stock loops at the app's one loudness (LevelMatch), or as recorded
      ChoiceButton(label: "Auto level", selected: model.autoGain[name] ?? true, tint: tint) {
        model.setAutoGain(name, !(model.autoGain[name] ?? true))
      }
      .help("Play loaded samples at the same loudness as generated tracks (±12 dB)")
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

/// The crates: a chip each (click to list it, again to go back to the stock loops; drop a
/// stock-loop row on one to add it; right-click to delete), and "+ Crate" for a new one.
struct CrateBar: View {
  let model: AppModel
  let tint: Color
  @Binding var shown: String?
  @State private var naming = false
  @State private var draft = ""
  @State private var target: String?

  var body: some View {
    FlowRow(spacing: DJStyle.xs) {
      Text("Crates").font(.caption2).foregroundStyle(.secondary)
      ForEach(model.crates, id: \.self) { c in
        ChoiceButton(
          label: "\(c) \(model.favorites.tagged(c).count)", selected: shown == c, tint: tint
        ) { shown = shown == c ? nil : c }
        .overlay(
          RoundedRectangle(cornerRadius: 6).strokeBorder(
            tint, lineWidth: target == c ? 2 : 0)
        )
        .dropDestination(for: String.self) { paths, _ in
          for p in paths { model.addToCrate(p, c) }
          return !paths.isEmpty
        } isTargeted: { on in
          target = on ? c : (target == c ? nil : target)
        }
        .contextMenu {
          Button("Delete crate \(c)") {
            if shown == c { shown = nil }
            model.deleteCrate(c)
          }
        }
        .help("Drop stock loops here; click to list them")
      }
      Button("+ Crate") { naming = true }.controlSize(.small)
        .popover(isPresented: $naming) {
          TextField("Crate name (Return)", text: $draft)
            .textFieldStyle(.roundedBorder).frame(width: 200).padding(10)
            .onSubmit {
              model.newCrate(draft)
              draft = ""
              naming = false
            }
        }
    }
  }
}

/// One loop in the list: its name, then tempo, key and what it is. Pressing it loads the loop;
/// drag it onto a crate to keep it there.
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
    .draggable(loop.path)
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
  /// Keep the seed after Generate / Queue next (regenerate the same track); off, the seed moves
  /// on to the next version's, so pressing Generate again gives a new song.
  @AppStorage("generate.lockSeed") private var lockSeed = false
  /// The palette the next Generate / Queue next plays from; nil = the deck's own (it carries).
  @State private var palette: String?
  static let structures = ["loop", "minimal", "standard", "extended"]

  /// After a Generate / Queue next: on to the next seed in the walk (`TrackSpec.nextVersion`,
  /// the step auto-next takes too), unless the seed is locked.
  private func advanceSeed() {
    if !lockSeed { seed = String(Int(spec.nextVersion.seed)) }
  }

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
      paletteRow
      HStack(spacing: 4) {
        HStack(spacing: 4) {
          ChoiceButton(label: "shared motif", selected: cohesion == "v2", tint: tint) {
            cohesion = "v2"
          }
          .help(
            "Cohesion v2: one theme per track — a motif, a chord plan and a groove every part"
              + " shares, so the melody restates the motif and the bass follows the same chords")
          ChoiceButton(label: "free-form", selected: cohesion == "v1", tint: tint) {
            cohesion = "v1"
          }
          .help(
            "Cohesion v1: no shared theme — each part writes its own line; the melody keeps one"
              + " rhythm from seed to seed, so it varies less than shared motif")
        }
        .arrowKeys(["v2", "v1"], current: cohesion) { cohesion = $0 }
        Spacer()
        TextField("Seed", text: $seed).frame(width: 70).controlSize(.small)
        Toggle(isOn: $lockSeed) { Image(systemName: lockSeed ? "lock.fill" : "lock.open") }
          .toggleStyle(.button).controlSize(.small)
          .help(
            lockSeed
              ? "Seed locked: Generate makes this track again"
              : "After Generate / Queue next the seed moves on to the next version; lock to keep it"
          )
        Button("Roll") { seed = String(Int.random(in: 1...999_999)) }.controlSize(.small)
      }
      HStack(spacing: 4) {
        // on the deck at once, whatever is playing: the next version of the song is composed in
        // the background and plays when this one ends (or what Queue next queued)
        let auto = model.decks[name]?.autoAdvance ?? false
        ChoiceButton(label: "Auto-next", selected: auto, tint: tint) {
          model.setAutoAdvance(name, !auto)
        }
        .help(
          "When the song ends, play the next version (same genre and structure, a new seed),"
            + " composed in the background — or the track Queue next queued")
        Spacer()
        Button("Queue next") {
          model.queueNext(name, model.generateSpec(name, spec, palette: palette))
          advanceSeed()
        }
        Button("Generate now") {
          model.generate(name, model.generateSpec(name, spec, palette: palette))
          advanceSeed()
        }
        .buttonStyle(.borderedProminent).tint(tint)
      }
      .controlSize(.small)
    }
  }
}

extension GeneratePanel {
  /// The palette for the new track: the deck's own unless another is chosen here.
  private var paletteRow: some View {
    let cards = PaletteCard.cards(current: palette ?? model.decks[name]?.palette)
    let playable = cards.filter { $0.unavailable == nil }.map(\.id)
    return FlowRow(spacing: 4) {
      ForEach(cards) { c in
        ChoiceButton(label: "\(c.icon) \(c.label)", selected: c.selected, tint: tint) {
          palette = c.id
        }
        .disabled(c.unavailable != nil)
        .help(c.unavailable.map { "Can't play here: \($0)" } ?? c.description)
      }
    }
    .arrowKeys(playable, current: cards.first(where: \.selected)?.id) { palette = $0 }
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
  private var notes: [TrackNote] { model.favoriteNotes(favorite) }

  private var helpText: String {
    let kind = favorite.isSample ? "Sample: \(favorite.file ?? "")" : "Net track"
    var text = kind + " — load onto deck \(deck) (right-click: tags, remove)"
    for n in notes {
      let at = n.position.map { "\($0.label): " } ?? ""
      text += "\n✎ " + at + n.text
    }
    return text
  }

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
        // its notes travel with it (the same track, by CID)
        if !notes.isEmpty { Text("✎\(notes.count)").font(.caption2).foregroundStyle(.yellow) }
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
    .help(helpText)
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

/// The track's sound: copy it to the other deck, choose its palette, fine-tune its roles
/// (`SoundChoices`).
struct TrackPanel: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  var body: some View {
    let other = name == "A" ? "B" : "A"
    VStack(alignment: .leading, spacing: 6) {
      SoundChoices(name: name, state: state, model: model, tint: tint)
      Button("Copy to deck \(other)") { Task { await model.copyDeck(from: name, to: other) } }
        .controlSize(.small)
        .help("Load this track, with its palette and sound changes, onto deck \(other)")
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
              ChoiceButton(label: m.label, selected: running.contains(m), tint: tint, live: true) {
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

/// Wander on the deck's button, lockable like the rest (right-click ▸ Disable also locks the
/// Inpulse's browser push for this deck).
struct WanderButton: View {
  let name: String
  let on: Bool
  let model: AppModel
  let tint: Color

  var body: some View {
    Toggle("Wander", isOn: Binding(get: { on }, set: { model.setWander(name, $0) }))
      .toggleStyle(.button).liveButton().tint(tint)
      .lockable(DJActionKind.lockKey(deck: name, .wander), model)
      .help(
        "The deck walks by itself: one move per phrase (a mute, a macro, the next seed, another "
          + "instrument or genre). Turn the browser wheel to steer: it waits a phrase for you.")
  }
}

/// The walk (Wander.swift): on/off, the pace, what it may not change, and the trail of moves
/// it took, newest first, each with a ★ to keep the track it led to.
struct WanderPanel: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  private var w: WanderState { state.wander }

  /// "next move in 3 bars", "paused — you're steering", or why it stands still.
  var status: String {
    guard w.on else { return "off" }
    if let idle = state.wanderIdle { return idle }
    let n = state.wanderCountdown ?? w.pace
    let bars = n == 1 ? "1 bar" : "\(n) bars"
    return w.paused ? "paused — you're steering (back in \(bars))" : "next move in \(bars)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        WanderButton(name: name, on: w.on, model: model, tint: tint)
        HStack(spacing: 2) {
          ForEach(WanderState.paces, id: \.self) { p in
            ChoiceButton(label: "\(p)", selected: w.pace == p, tint: tint) {
              model.setWanderPace(name, p)
            }
          }
        }
        .arrowKeys(WanderState.paces, current: w.pace) { model.setWanderPace(name, $0) }
        .help("Bars per move (SHIFT + browser wheel on the Inpulse)")
        Text("bars").font(.caption2).foregroundStyle(.secondary)
        Spacer(minLength: DJStyle.xs)
        Text(status).font(.caption).monospacedDigit().lineLimit(1)
          .foregroundStyle(
            w.on && state.wanderIdle == nil ? (w.paused ? .orange : tint) : .secondary)
      }
      FlowRow(spacing: 4) {
        Text("Lock").font(.caption2).foregroundStyle(.secondary)
        ForEach(WanderLock.dimensions, id: \.self) { d in
          ChoiceButton(label: WanderLock.label(d), selected: w.isLocked(d), tint: tint) {
            model.setWanderLock(name, d, !w.isLocked(d))
          }
          .help(Self.help(d))
        }
      }
      if !state.roles.isEmpty {
        FlowRow(spacing: 4) {
          Text("Keep").font(.caption2).foregroundStyle(.secondary)
          ForEach(state.roles, id: \.self) { r in
            let key = WanderLock.keep(r)
            ChoiceButton(label: r, selected: w.isLocked(key), tint: tint) {
              model.setWanderLock(name, key, !w.isLocked(key))
            }
            .help("Keep the \(r): its instrument comes with every new seed, and no move mutes it")
          }
        }
      }
      if w.log.isEmpty {
        Text(w.on ? "No moves yet: the first comes at the end of the phrase." : "Moves show here.")
          .font(.caption2).foregroundStyle(.secondary)
      } else {
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(w.log.reversed(), id: \.step) { m in
              WanderMoveRow(move: m, kept: model.isFavoriteSpec(m.spec), tint: tint) {
                model.keepWanderMove(m)
              }
            }
          }
        }
        .frame(height: 96)
      }
    }
  }

  static func help(_ d: String) -> String {
    switch d {
    case "genre": return "No genre hops: new seeds stay in this genre"
    case "tempo": return "Stay within ±6 % of the tempo playing now"
    case "key": return "Keep the scale and root playing now"
    case "structure": return "Keep the structure (genre hops stay in its family)"
    case "instruments": return "No instrument changes: every new seed keeps these instruments"
    case "arrangement": return "No mutes or STEMS changes"
    case "fx": return "No macros, FX or stingers"
    case "palette": return "No palette hops: the walk keeps this sound palette"
    default: return WanderLock.label(d)
    }
  }
}

/// One move of the walk: its number, bar and what it did; ★ keeps the track it led to.
struct WanderMoveRow: View {
  let move: WanderMove
  let kept: Bool
  let tint: Color
  let keep: () -> Void

  var body: some View {
    HStack(spacing: DJStyle.s) {
      Text("#\(move.step + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .frame(width: 30, alignment: .leading)
      Text("bar \(move.bar)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        .frame(width: 44, alignment: .leading)
      Text(move.detail).font(.caption).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(move.kind.swaps ? tint : .primary)
      Spacer(minLength: DJStyle.xs)
      if move.spec != nil {
        Button(kept ? "★" : "☆", action: keep).buttonStyle(.plain).font(.caption)
          .foregroundStyle(kept ? Color.yellow : Color.secondary)
          .help(kept ? "Starred: click to unstar" : "Star the track this move led to")
      }
    }
    .padding(.horizontal, DJStyle.xs).padding(.vertical, 2)
  }
}
