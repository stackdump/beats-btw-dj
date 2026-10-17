import DJCore
import SwiftUI

/// A clip's colour (`LoopClip.palette`) as drawn; none is the row's violet.
@MainActor func clipTint(_ name: String?) -> Color {
  switch name {
  case "red": Color(red: 0.95, green: 0.33, blue: 0.33)
  case "orange": Color(red: 0.98, green: 0.58, blue: 0.22)
  case "yellow": Color(red: 0.96, green: 0.84, blue: 0.25)
  case "green": Color(red: 0.36, green: 0.82, blue: 0.42)
  case "teal": Color(red: 0.25, green: 0.80, blue: 0.78)
  case "blue": Color(red: 0.33, green: 0.56, blue: 0.98)
  case "violet": Color(red: 0.62, green: 0.42, blue: 0.98)
  case "pink": Color(red: 0.96, green: 0.45, blue: 0.75)
  default: LoopRowView.tint
  }
}

/// The Loops row's second header line: which loops show (source chips, a search, the tempo
/// filter), the loops taken off the row (Removed…), and "Undo" just after a removal.
struct LoopLibraryBar: View {
  let model: AppModel
  @State private var showRemoved = false

  var body: some View {
    HStack(spacing: DJStyle.s) {
      Text("SHOW").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.tertiary)
      ForEach(LoopFilter.sourceChips, id: \.self) { s in
        chip(
          s == "seq" ? "Seq" : s, on: model.loopFilter.sources.contains(s),
          tint: s == "seq" ? LoopRowView.tint : deckTint(s)
        ) { model.toggleSourceFilter(s) }
        .help(s == "seq" ? "Show sequences" : "Show loops taken from deck \(s)")
      }
      let tempo = model.playingTempo
      chip(
        tempo.map { String(format: "≈ %.0f bpm", $0) } ?? "≈ tempo",
        on: model.loopFilter.nearTempo, tint: LoopRowView.tint
      ) { model.loopFilter.nearTempo.toggle() }
      .help(
        "Only loops within ±\(Int(LoopFilter.tempoTolerance * 100))% of the playing tempo"
          + (tempo == nil ? " (nothing is playing)" : ""))
      TextField(
        "Search titles, genre",
        text: Binding(get: { model.loopFilter.search }, set: { model.loopFilter.search = $0 })
      )
      .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 170)
      if model.loopFilter.isActive {
        Text("\(model.visibleClips.count) of \(model.clips.count)").font(.caption)
          .monospacedDigit().foregroundStyle(.secondary)
        Button("Clear") { model.loopFilter = LoopFilter() }.controlSize(.small)
      }
      Spacer(minLength: 0)
      if let r = model.lastRemoval {
        HStack(spacing: DJStyle.xs) {
          Text("Removed “\(r.title)”").font(.caption).lineLimit(1)
          Button("Undo") { model.undoRemove() }.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
        .help("Put it back where it was")
      }
      Button("Removed (\(model.removedLoops.count))") { showRemoved.toggle() }
        .controlSize(.small).disabled(model.removedLoops.isEmpty)
        .help("Loops taken off the row: restore them, or delete them for good")
        .popover(isPresented: $showRemoved) { RemovedLoopsPanel(model: model) }
    }
  }

  private func chip(_ label: String, on: Bool, tint: Color, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(label).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
        .foregroundStyle(on ? Color.black : tint)
        .background(Capsule().fill(on ? tint : tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.6)))
    }
    .buttonStyle(.plain)
  }
}

/// The loops taken off the row, newest first: each can be restored (back where it was) or
/// deleted for good.
struct RemovedLoopsPanel: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Removed loops").font(.headline)
      if model.removedLoops.isEmpty {
        Text("Nothing removed").foregroundStyle(.secondary)
      }
      ForEach(model.removedLoops) { r in
        HStack(spacing: DJStyle.s) {
          RoundedRectangle(cornerRadius: 2).fill(clipTint(r.color)).frame(width: 4, height: 18)
          VStack(alignment: .leading, spacing: 0) {
            Text(r.title).font(.callout).lineLimit(1)
            Text(
              "\(r.isSequence ? "sequence" : "from \(r.source)") · \(r.beats) beats · "
                + String(format: "%.1f bpm", r.bpm)
            )
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
          Spacer(minLength: DJStyle.m)
          Button("Restore") { model.restoreRemoved(r.id) }.controlSize(.small)
            .help("Back on the row where it was (slot \(r.index + 1))")
          Button("Delete forever", role: .destructive) { model.deleteForever(r.id) }
            .controlSize(.small).help("Delete its audio: this can't be undone")
        }
      }
    }
    .padding(12).frame(minWidth: 380, alignment: .leading)
  }
}

/// The palette as swatches; the current one ringed, the first clears it.
struct ClipColorSwatches: View {
  let current: String?
  let pick: (String?) -> Void

  var body: some View {
    HStack(spacing: 4) {
      Button {
        pick(nil)
      } label: {
        Image(systemName: "circle.slash").foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless).help("No colour")
      ForEach(LoopClip.palette, id: \.self) { name in
        Button {
          pick(name)
        } label: {
          Circle().fill(clipTint(name)).frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color.primary, lineWidth: current == name ? 2 : 0))
        }
        .buttonStyle(.plain).help(name)
      }
    }
  }
}

/// A clip's name: double-click to rename it in place (Return keeps it, Escape doesn't).
struct ClipTitleField: View {
  let clip: ClipState
  let model: AppModel
  @State private var editing = false
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    if editing {
      TextField("Name", text: $draft)
        .textFieldStyle(.plain).font(.caption.bold()).focused($focused)
        .onSubmit { commit() }
        .onExitCommand { editing = false }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .onAppear { focused = true }
    } else {
      Text(clip.title).font(.caption.bold()).lineLimit(1)
        .foregroundStyle(clip.color == nil ? Color.primary : clipTint(clip.color))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          draft = clip.title
          editing = true
        }
        .help("Double-click to rename")
    }
  }

  private func commit() {
    guard editing else { return }
    editing = false
    model.renameClip(clip.id, draft)
  }
}

/// The info popover's name field: the rename is one action, on Return or when it closes (not
/// one per keystroke).
struct ClipNameEditor: View {
  let clip: ClipState
  let model: AppModel
  @State private var draft = ""

  var body: some View {
    TextField("Name", text: $draft)
      .textFieldStyle(.roundedBorder).font(.headline)
      .onAppear { draft = clip.title }
      .onSubmit { model.renameClip(clip.id, draft) }
      .onDisappear { model.renameClip(clip.id, draft) }
  }
}
