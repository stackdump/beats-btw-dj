import AppKit
import DJCore
import SwiftUI

/// The Soundboard: every loop on the row as one big pad, the saved scenes along the top. A
/// click brings a loop in or out on the next launch boundary (⌥-click solos it, ⇧-click mutes
/// it); right-click has the quick settings and "Settings…", the clip's full editor. With the
/// mouse over the board the arrow keys move a focus between the pads (↑ / ↓ a row) and Return /
/// Space toggle the focused one.
///
/// A panel in the main window (the bottom bar's "Soundboard", View ▸ Soundboard, ⇧⌘B), like
/// Controllers: it sits right under the decks, above the Loops row it is a simpler view of.
struct SoundboardView: View {
  let model: AppModel
  static let title = "Soundboard"
  static let help = "Every loop as a big pad: click to bring it in or out, right-click for more"

  /// The pad the arrow keys are on.
  @State private var focus: String?
  /// The pad whose settings are open.
  @State private var settings: String?
  /// The pad being renamed (from its menu), and the name typed so far.
  @State private var renaming: String?
  @State private var newName = ""
  /// The grid's width, for its column count (↑ / ↓ move a row).
  @State private var gridWidth: CGFloat = 0

  var body: some View {
    let pads = model.soundPads
    VStack(alignment: .leading, spacing: DJStyle.s) {
      header(pads)
      switch model.soundboardPage {
      case .row: rowPage(pads)
      case .stock: StockBoardView(model: model)
      case .crate: CrateBoardView(model: model)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .alert(
      "Rename loop",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let r = renaming { model.soundboard(.rename(newName), r) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
  }

  /// The Row page: every loop on the row as a pad, the scenes above them.
  @ViewBuilder private func rowPage(_ pads: [SoundPad]) -> some View {
    Group {
      if !model.scenes.isEmpty || model.loopChannel.looping > 0 {
        HStack(spacing: DJStyle.s) {
          Text("SCENES").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.tertiary)
          SceneStrip(model: model)
          Spacer(minLength: 0)
        }
      }
      if pads.isEmpty {
        SoundboardEmpty(tapBars: model.tapBars)
      } else {
        SoundboardGrid {
          ForEach(pads) { pad in
            SoundPadView(pad: pad, focused: focus == pad.id)
              .onTapGesture {
                let flags = NSEvent.modifierFlags
                focus = pad.id
                model.padClick(
                  pad.id, option: flags.contains(.option), shift: flags.contains(.shift))
              }
              .onHover { if $0 { focus = pad.id } }
              .contextMenu {
                SoundPadMenu(
                  pad: pad, fade: model.loopChannel.fade,
                  run: { model.soundboard($0, pad.id) },
                  rename: {
                    newName = pad.title
                    renaming = pad.id
                  },
                  openSettings: { settings = pad.id })
              }
              .popover(
                isPresented: Binding(
                  get: { settings == pad.id }, set: { if !$0 { settings = nil } }),
                arrowEdge: .trailing
              ) {
                ClipSettingsView(
                  id: Binding(get: { settings ?? pad.id }, set: { settings = $0 }), model: model)
              }
              .help(
                "\(pad.title): click to bring it in or out on the next "
                  + "\(DJEngine.quantumLabel(model.loopQuantum)) · ⌥-click solo · ⇧-click mute "
                  + "· right-click for its settings")
          }
        }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          gridWidth = $0
        }
        .arrowKeys(
          pads.map(\.id), columns: SoundboardLayout.columns(count: pads.count, width: gridWidth),
          current: focus, select: { focus = $0 },
          activate: { if let f = focus { model.soundboard(.toggle, f) } })
      }
    }
  }

  private func header(_ pads: [SoundPad]) -> some View {
    HStack(spacing: DJStyle.m) {
      Text("SOUNDBOARD").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.secondary)
      HStack(spacing: DJStyle.xs) {
        ForEach(SoundboardPage.allCases, id: \.self) { p in
          ChoiceButton(label: p.label, selected: model.soundboardPage == p, tint: LoopRowView.tint)
          {
            model.setSoundboardPage(p)
          }
          .help(p.help)
        }
      }
      if model.soundboardPage == .row, !pads.isEmpty {
        Text("\(pads.count) loop\(pads.count == 1 ? "" : "s")").font(.caption)
          .foregroundStyle(.secondary).monospacedDigit()
      }
      Button("Stop all") { model.stopAllLoops() }
        .controlSize(.small).disabled(model.loopChannel.looping == 0)
        .help("Every loop out on the next launch boundary")
      if let r = model.lastRemoval {
        HStack(spacing: DJStyle.xs) {
          Text("Removed “\(r.title)”").font(.caption).lineLimit(1)
          Button("Undo") { model.undoRemove() }.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
      }
      Spacer(minLength: 0)
      Text(
        "in / out on the next \(DJEngine.quantumLabel(model.loopQuantum)) · ⌥ solo · ⇧ mute"
      )
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Button {
        model.setShowSoundboard(false)
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless).help("Close the soundboard (⇧⌘B)")
    }
  }
}

/// The Stock page: the Apple Loops on this Mac nearest the decks' tempo as pads (the first
/// `AppModel.stockPadLimit`), with a category strip and a search. A click puts the loop on the
/// row, coming in on the next launch boundary; a loop already on the row lights as its clip
/// does, and a click on a sounding one takes it out. Arrows move the focus, Return / Space press
/// the focused pad.
struct StockBoardView: View {
  let model: AppModel
  @State private var focus: String?
  @State private var gridWidth: CGFloat = 0

  var body: some View {
    let all = model.stockLoops
    let pads = model.stockPads
    VStack(alignment: .leading, spacing: DJStyle.s) {
      HStack(spacing: DJStyle.s) {
        TextField(
          "Search stock loops (name, pack, genre)",
          text: Binding(get: { model.stockPadQuery }, set: { model.stockPadQuery = $0 })
        )
        .textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 280)
        Text(summary(all: all.count, hits: model.stockPadMatches.count))
          .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        Spacer(minLength: 0)
      }
      if !all.isEmpty {
        let categories = all.categories
        FlowRow(spacing: DJStyle.xs) {
          ChoiceButton(label: "All", selected: model.stockPadCategory.isEmpty, tint: tint) {
            model.stockPadCategory = ""
          }
          ForEach(categories, id: \.self) { c in
            ChoiceButton(label: c, selected: model.stockPadCategory == c, tint: tint) {
              model.setStockPadCategory(c)
            }
          }
        }
        .arrowKeys([""] + categories, current: model.stockPadCategory) {
          model.stockPadCategory = $0
        }
      }
      if pads.isEmpty {
        Text(
          model.stockLoopsLoading
            ? "Reading the loop index…"
            : all.isEmpty
              ? "No Apple Loops installed (GarageBand or Logic content in /Library/Audio/Apple Loops)"
              : "No loops match: clear the search or pick another category"
        )
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
      } else {
        SoundboardGrid {
          ForEach(pads) { pad in
            StockPadView(pad: pad, focused: focus == pad.id)
              .onTapGesture {
                focus = pad.id
                Task { await model.stockPadClick(pad.id) }
              }
              .onHover { if $0 { focus = pad.id } }
              .help(
                pad.sounding
                  ? "\(pad.title): click to take it out on the next "
                    + DJEngine.quantumLabel(model.loopQuantum)
                  : "\(pad.title): click to put it on the row, in on the next "
                    + DJEngine.quantumLabel(model.loopQuantum))
          }
        }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          gridWidth = $0
        }
        .arrowKeys(
          pads.map(\.id), columns: SoundboardLayout.columns(count: pads.count, width: gridWidth),
          current: focus, select: { focus = $0 },
          activate: {
            if let f = focus { Task { await model.stockPadClick(f) } }
          })
      }
    }
    // the index is read (or scanned, the first time) off the main thread
    .task { await model.loadStockLoops() }
  }

  private var tint: Color { LoopRowView.tint }

  private func summary(all: Int, hits: Int) -> String {
    if model.stockLoopsLoading { return "scanning…" }
    guard all > 0 else { return "none installed" }
    let shown = min(hits, AppModel.stockPadLimit)
    let head = hits > shown ? "\(shown) of \(hits)" : "\(hits)"
    return model.stockPadTempo.map { String(format: "%@ · nearest %.0f BPM", head, $0) } ?? head
  }
}

/// A Stock page pad: the loop's name, its category, tempo and length, lit as its clip on the row
/// is (full while it plays, blinking on its way in or out or while it loads).
struct StockPadView: View {
  let pad: StockPad
  var focused = false

  var body: some View {
    let tint = LoopRowView.tint
    ZStack(alignment: .topLeading) {
      if pad.pending {
        TimelineView(.periodic(from: .now, by: 0.25)) { t in
          let lit = Int(t.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
          face(tint, fill: lit ? 0.42 : 0.16)
        }
      } else {
        face(tint, fill: pad.sounding ? 0.62 : 0.1)
      }
      VStack(alignment: .leading, spacing: DJStyle.xs) {
        Text(pad.title).font(.headline).lineLimit(2)
          .foregroundStyle(pad.sounding ? Color.white : Color.primary)
        Text(pad.category.isEmpty ? "—" : pad.category).font(.caption)
          .foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 0)
        Text(pad.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        HStack(spacing: DJStyle.xs) {
          Text(String(format: "%.0f BPM", pad.bpm)).font(.caption.bold()).monospacedDigit()
          Spacer(minLength: 0)
          if pad.onRow {
            Text("ROW").font(.caption2.bold()).padding(.horizontal, 3)
              .foregroundStyle(Color.black)
              .background(RoundedRectangle(cornerRadius: 3).fill(tint))
          }
          Text(stateLabel).font(.caption2.bold()).monospacedDigit()
            .foregroundStyle(pad.state == .stopping ? LoopCountdownBadge.outTint : Color.primary)
        }
      }
      .padding(DJStyle.s)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(pad.title), \(pad.category), \(stateLabel)")
    .accessibilityAddTraits(.isButton)
  }

  private var stateLabel: String {
    if pad.loading { return "LOADING" }
    switch pad.state {
    case .off: return pad.onRow ? "OFF" : "ADD"
    case .on: return "ON"
    case .starting: return (pad.countdown?.label ?? "in").uppercased()
    case .stopping: return "OUT"
    }
  }

  private func face(_ tint: Color, fill: Double) -> some View {
    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(fill))
      .overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(
          focused ? Color.white : tint.opacity(pad.state == .off ? 0.35 : 0.9),
          style: StrokeStyle(lineWidth: focused ? 2 : 1, dash: pad.pending ? [5, 3] : [])))
  }
}

/// The Crate page: a crate's favorites as pads, with a strip choosing the crate (remembered). A
/// click loads the favorite on the focus deck, ⌥-click on the other one (`loadFavorite`, so it is
/// performed and recorded as the Favorites panel's load); a pad is lit while a deck plays it.
/// Arrows move the focus, Return / Space press the focused pad.
struct CrateBoardView: View {
  let model: AppModel
  @State private var focus: String?
  @State private var gridWidth: CGFloat = 0

  var body: some View {
    let crates = model.crates
    let crate = model.crateBoardCrate
    let pads = model.cratePads
    VStack(alignment: .leading, spacing: DJStyle.s) {
      if !crates.isEmpty {
        FlowRow(spacing: DJStyle.xs) {
          ForEach(crates, id: \.self) { c in
            ChoiceButton(label: c, selected: crate == c, tint: tint) {
              model.setSoundboardCrate(c)
            }
          }
        }
        .arrowKeys(crates, current: crate) { model.setSoundboardCrate($0) }
      }
      if pads.isEmpty {
        Text(
          crates.isEmpty
            ? "No crates yet: make one in a deck's Load panel and drag loops onto it."
            : "Empty: drag stock loops onto the crate's chip in a deck's Load panel."
        )
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
      } else {
        SoundboardGrid {
          ForEach(pads) { pad in
            CratePadView(pad: pad, focused: focus == pad.id)
              .onTapGesture {
                focus = pad.id
                model.cratePadPress(pad.id, other: NSEvent.modifierFlags.contains(.option))
              }
              .onHover { if $0 { focus = pad.id } }
              .help(
                "\(pad.title): click to load it on deck \(model.crateBoardDeck()) · ⌥-click "
                  + "on deck \(model.crateBoardDeck(other: true))")
          }
        }
        .onGeometryChange(for: CGFloat.self) {
          $0.size.width
        } action: {
          gridWidth = $0
        }
        .arrowKeys(
          pads.map(\.id), columns: SoundboardLayout.columns(count: pads.count, width: gridWidth),
          current: focus, select: { focus = $0 },
          activate: { if let f = focus { model.cratePadPress(f) } })
      }
    }
  }

  private var tint: Color { .yellow }
}

/// A Crate page pad: the favorite's title, what it is, and the decks holding it; lit while one
/// plays it.
struct CratePadView: View {
  let pad: CratePad
  var focused = false

  var body: some View {
    let tint = pad.playingOn.first.map { deckTint($0) } ?? Color.yellow
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10).fill(tint.opacity(pad.sounding ? 0.62 : 0.1))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(
            focused ? Color.white : tint.opacity(pad.onDecks.isEmpty ? 0.35 : 0.9),
            lineWidth: focused ? 2 : 1))
      VStack(alignment: .leading, spacing: DJStyle.xs) {
        HStack(alignment: .top, spacing: DJStyle.xs) {
          Text(pad.title).font(.headline).lineLimit(2)
            .foregroundStyle(pad.sounding ? Color.white : Color.primary)
          Spacer(minLength: 0)
          Image(systemName: pad.isSample ? "waveform" : "point.3.connected.trianglepath.dotted")
            .font(.caption)
        }
        Spacer(minLength: 0)
        Text(pad.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        HStack(spacing: DJStyle.xs) {
          Spacer(minLength: 0)
          ForEach(pad.onDecks, id: \.self) { d in
            Text("on \(d)").font(.caption2.bold()).padding(.horizontal, 3)
              .foregroundStyle(Color.black)
              .background(RoundedRectangle(cornerRadius: 3).fill(deckTint(d)))
          }
          Text(stateLabel).font(.caption2.bold())
        }
      }
      .padding(DJStyle.s)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(pad.title), \(pad.detail), \(stateLabel)")
    .accessibilityAddTraits(.isButton)
  }

  private var stateLabel: String {
    pad.sounding ? "PLAYING" : pad.onDecks.isEmpty ? "LOAD" : "LOADED"
  }
}

/// No loops yet: how to make one.
struct SoundboardEmpty: View {
  let tapBars: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("No loops yet").font(.headline)
      Text(
        "Hold LOOP on a playing deck to record its bars (a quick tap takes \(tapBars) "
          + "bar\(tapBars == 1 ? "" : "s")), or grab the last 1, 2 or 4 bars it played with ⟲. "
          + "Every loop becomes a pad here, and the Inpulse's LOOP pads switch the first eight."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
  }
}

/// One pad: the clip's colour, its title, a ring for where it is in its loop (or how long until
/// it switches), a small waveform, its length and its state. Lit as the controllers light it:
/// full while it plays, blinking on its way in or out, dark when off.
struct SoundPadView: View {
  let pad: SoundPad
  var focused = false

  var body: some View {
    let tint = pad.onDeck.map { deckTint($0) } ?? clipTint(pad.color)
    ZStack(alignment: .topLeading) {
      if pad.pending {
        // the LEDs' blink, ~2 Hz
        TimelineView(.periodic(from: .now, by: 0.25)) { t in
          let lit = Int(t.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
          face(tint, fill: lit ? 0.42 : 0.16)
        }
      } else {
        face(tint, fill: pad.sounding ? 0.62 : 0.1)
      }
      VStack(alignment: .leading, spacing: DJStyle.xs) {
        HStack(alignment: .top, spacing: DJStyle.xs) {
          Text(pad.title).font(.headline).lineLimit(2)
            .foregroundStyle(pad.sounding ? Color.white : Color.primary)
          Spacer(minLength: 0)
          SoundPadRing(pad: pad, tint: tint).frame(width: 26, height: 26)
        }
        Spacer(minLength: 0)
        WaveformStrip(
          overview: pad.overview, overlay: pad.phase.map { WaveformOverlay(playhead: $0) },
          tint: pad.sounding ? .white : tint.opacity(0.8)
        )
        .frame(height: 18).opacity(pad.muted ? 0.35 : 1)
        HStack(spacing: DJStyle.xs) {
          Text(pad.lengthLabel).font(.caption.bold()).monospacedDigit()
          if pad.isSequence { Image(systemName: "list.bullet").font(.caption2) }
          Spacer(minLength: 0)
          if pad.muted { badge("M", .orange) }
          if pad.soloed { badge("S", .yellow) }
          if pad.keyLock { Image(systemName: "lock.fill").font(.caption2) }
          if pad.fx.isActive { ClipFxBadge(fx: pad.fx) }
          if let d = pad.onDeck { badge("on \(d)", deckTint(d)) }
          if let s = pad.slot { Text(s).font(.caption2.monospaced()).foregroundStyle(.secondary) }
          Text(pad.stateLabel.uppercased()).font(.caption2.bold()).monospacedDigit()
            .foregroundStyle(pad.state == .stopping ? LoopCountdownBadge.outTint : Color.primary)
        }
      }
      .padding(DJStyle.s)
    }
    .contentShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(pad.title), \(pad.lengthLabel), \(pad.stateLabel)")
    .accessibilityAddTraits(.isButton)
  }

  private func face(_ tint: Color, fill: Double) -> some View {
    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(fill))
      .overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(
          focused ? Color.white : tint.opacity(pad.state == .off ? 0.35 : 0.9),
          style: StrokeStyle(lineWidth: focused ? 2 : 1, dash: pad.pending ? [5, 3] : [])))
  }

  private func badge(_ s: String, _ c: Color) -> some View {
    Text(s).font(.caption2.bold()).padding(.horizontal, 3)
      .foregroundStyle(Color.black).background(RoundedRectangle(cornerRadius: 3).fill(c))
  }
}

/// The pad's ring: its loop's phase while it sounds, filling towards the boundary while it
/// waits (the loops' violet coming in, amber going out), an empty ring when off.
struct SoundPadRing: View {
  let pad: SoundPad
  let tint: Color

  var body: some View {
    let (amount, color): (Double, Color) =
      if let c = pad.countdown {
        (c.progress, pad.state == .stopping ? LoopCountdownBadge.outTint : LoopRowView.tint)
      } else {
        (pad.phase ?? 0, pad.sounding ? Color.white : tint)
      }
    ZStack {
      Circle().stroke(color.opacity(0.3), lineWidth: 3)
      Circle().trim(from: 0, to: amount)
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if let c = pad.countdown {
        Text("\(c.beats)").font(.caption2.bold().monospacedDigit()).foregroundStyle(color)
      }
    }
  }
}

/// A pad's right-click: the quick settings, then the clip's full editor.
struct SoundPadMenu: View {
  let pad: SoundPad
  /// How loops come in and go out now (the loop channel's).
  let fade: LoopFade
  let run: (SoundPadCommand) -> Void
  let rename: () -> Void
  let openSettings: () -> Void

  var body: some View {
    Button(pad.sounding ? "Stop" : "Play") { run(.toggle) }
    Divider()
    Button("Rename…", action: rename)
    Menu("Colour") {
      Button("None") { run(.color(nil)) }
      ForEach(LoopClip.palette, id: \.self) { name in
        Button(name.capitalized) { run(.color(name)) }
      }
    }
    Toggle("Mute", isOn: Binding(get: { pad.muted }, set: { run(.mute($0)) }))
    Toggle("Solo", isOn: Binding(get: { pad.soloed }, set: { run(.solo($0)) }))
    Toggle("Key lock", isOn: Binding(get: { pad.keyLock }, set: { run(.keyLock($0)) }))
    ClipFxMenu(fx: pad.fx) { run(.fx($0)) }
    Menu("Fade (every loop)") {
      ForEach(LoopFade.allCases, id: \.self) { f in
        Toggle(f.label, isOn: Binding(get: { fade == f }, set: { _ in run(.fade(f)) }))
      }
    }
    Divider()
    Button("Move to deck A") { run(.move("A")) }.disabled(pad.onDeck == "A")
    Button("Move to deck B") { run(.move("B")) }.disabled(pad.onDeck == "B")
    if pad.onDeck != nil { Button("Back under the mixer") { run(.move("L")) } }
    Divider()
    Button("Settings…", action: openSettings)
    Divider()
    Button("Remove (Undo for a few seconds)", role: .destructive) { run(.remove) }
  }
}

/// "Save scene" and a chip per saved scene (tap: launch; right-click: rename, overwrite,
/// delete), with the rename prompt: the Loops row's launch bar and the Soundboard's top strip.
struct SceneStrip: View {
  let model: AppModel
  /// The scene being renamed, and the name typed so far.
  @State private var renaming: String?
  @State private var newName = ""

  var body: some View {
    HStack(alignment: .top, spacing: DJStyle.m) {
      Button("Save scene") { model.saveScene() }
        .controlSize(.small).disabled(model.loopChannel.looping == 0)
        .help("Keep the loops playing now (and their levels) as a scene")
      FlowRow(spacing: 4) {
        ForEach(model.scenes) { scene in SceneChip(scene: scene, model: model, rename: rename) }
      }
    }
    .alert(
      "Rename scene",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $newName)
      Button("Rename") {
        if let r = renaming { model.renameScene(r, to: newName) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
  }

  private func rename(_ name: String) {
    newName = name
    renaming = name
  }
}
