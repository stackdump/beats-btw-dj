import DJCore
import SwiftUI

// Notes on what a deck plays (the Notes section), the journal's latest lines (the History
// section), and the note marker on a loop clip. Notes are yellow wherever they show.

private let noteTint = Color.yellow

/// A deck's Notes section: one-tap notes at the current bar (no keyboard), a field for your own,
/// and the track's notes in track order (right-click to edit or delete).
struct NotesPanel: View {
  let name: String
  let model: AppModel
  let tint: Color
  @State private var text = ""

  var body: some View {
    let notes = model.deckNotes(name)
    let canNote = model.deckNoteKeys[name] != nil
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      FlowRow(spacing: DJStyle.xs) {
        ForEach(AppModel.quickNotes, id: \.self) { q in
          Button(q) { model.addNote(name, q) }
            .help("Note “\(q)” at the bar deck \(name) is on")
        }
      }
      .controlSize(.small).disabled(!canNote)
      HStack(spacing: DJStyle.xs) {
        TextField("Note at this bar…", text: $text)
          .textFieldStyle(.roundedBorder).controlSize(.small)
          .onSubmit(add)
        Button("✎ Note", action: add).controlSize(.small)
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !canNote)
      }
      if notes.isEmpty {
        Text(
          canNote
            ? "No notes on this track. They come back whenever the same track (same genre, seed and settings) plays again."
            : "Load something to leave notes on it."
        )
        .font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(notes) { n in NoteRow(note: n, model: model) }
      }
    }
  }

  private func add() {
    guard model.addNote(name, text) != nil else { return }
    text = ""
  }
}

/// One note: where in the track, the text, when; right-click to edit or delete.
struct NoteRow: View {
  let note: TrackNote
  let model: AppModel
  @State private var editing = false
  @State private var draft = ""

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DJStyle.xs) {
      Text(note.position?.label ?? "—").font(.caption.monospacedDigit()).foregroundStyle(noteTint)
        .frame(minWidth: 52, alignment: .leading)
      Text(note.text).font(.caption).lineLimit(3)
      Spacer(minLength: 0)
      Text(note.created.formatted(date: .abbreviated, time: .shortened))
        .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.vertical, 1)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Edit…") {
        draft = note.text
        editing = true
      }
      Button("Delete note", role: .destructive) { model.deleteNote(note.id) }
    }
    .popover(isPresented: $editing) {
      HStack {
        TextField("Note", text: $draft).frame(width: 240).onSubmit(save)
        Button("Save", action: save)
      }
      .padding(DJStyle.s)
    }
    .help(note.edited.map { "edited \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
  }

  private func save() {
    model.editNote(note.id, draft)
    editing = false
  }
}

/// The History section: the journal's latest lines, newest first, a fader sweep folded into
/// one row, notes highlighted. "⟲ Rewind" turns the list into a picker (`RewindPoint`: marks,
/// notes, checkpoints, every `AppModel.rewindEvery`th action, then the file's older
/// checkpoints); a row's ⟲ asks first, naming the time and what happened, then rewinds.
struct HistoryPanel: View {
  let model: AppModel
  @State private var notesOnly = false
  @State private var rewinding: Bool
  @State private var picked: RewindPoint?
  @State private var older: [RewindPoint] = []
  @State private var busy = false
  @State private var outcome: String?
  static let shown = 80

  init(model: AppModel, rewinding: Bool = false, picked: RewindPoint? = nil) {
    self.model = model
    _rewinding = State(initialValue: rewinding)
    _picked = State(initialValue: picked)
  }

  struct Row: Identifiable {
    let entry: JournalEntry
    let count: Int
    var id: Int { entry.seq }
  }

  /// Newest first; consecutive events with one `foldKey` as one row (the newest of them).
  static func rows(_ entries: [JournalEntry], notesOnly: Bool) -> [Row] {
    var out: [Row] = []
    for e in entries.reversed() where !notesOnly || e.event.isNote {
      if let k = e.event.foldKey, let last = out.last, last.entry.event.foldKey == k {
        out[out.count - 1] = Row(entry: last.entry, count: last.count + 1)
      } else {
        out.append(Row(entry: e, count: 1))
      }
      if out.count > shown { break }
    }
    return Array(out.prefix(shown))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      HStack(spacing: DJStyle.xs) {
        SectionLabel("Journal")
        Toggle("Notes only", isOn: $notesOnly).toggleStyle(.button).controlSize(.mini)
          .tint(noteTint).disabled(rewinding)
        Toggle("⟲ Rewind", isOn: $rewinding).toggleStyle(.button).controlSize(.mini)
          .tint(.orange).disabled(model.journal == nil || busy)
          .help("Pick a point in this run's journal to put the app back to")
      }
      if rewinding { picker } else { history }
      if let file = model.journal?.file.lastPathComponent {
        Text("\(file) · djctl journal show latest")
          .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .task(id: rewinding) {
      if rewinding { older = await model.fileRewindPoints() } else { picked = nil }
    }
  }

  @ViewBuilder private var history: some View {
    let rows = Self.rows(model.journalEntries, notesOnly: notesOnly)
    if rows.isEmpty {
      Text(model.journal == nil ? "No journal this run." : "Nothing yet.")
        .font(.caption).foregroundStyle(.secondary)
    } else {
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 1) {
          ForEach(rows) { r in
            HStack(alignment: .firstTextBaseline, spacing: DJStyle.xs) {
              Text(r.entry.time.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
              Text(r.entry.event.summary + (r.count > 1 ? "  ×\(r.count)" : ""))
                .font(.caption).lineLimit(1)
                .foregroundStyle(r.entry.event.isNote ? noteTint : Color.primary)
                .fontWeight(r.entry.event.isNote ? .semibold : .regular)
            }
            .help("#\(r.entry.seq) at frame \(r.entry.frame)")
          }
        }
      }
      .frame(height: 180)
    }
  }

  /// The rewind picker: the confirm strip for the picked row, progress / the outcome, the rows.
  @ViewBuilder private var picker: some View {
    let points = AppModel.rewindPoints(model.journalEntries, older: older)
    if let p = picked {
      VStack(alignment: .leading, spacing: DJStyle.xs) {
        Text("Rewind to \(Self.time(p)) — \(p.summary)?").font(.caption.bold()).lineLimit(2)
        Text("Everything after it is undone; the journal keeps it.")
          .font(.caption2).foregroundStyle(.secondary)
        HStack(spacing: DJStyle.xs) {
          Button("⟲ Rewind", role: .destructive) { rewind(to: p) }
          Button("Cancel") { picked = nil }
        }
        .controlSize(.small)
      }
      .padding(DJStyle.xs)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
    if busy {
      HStack(spacing: DJStyle.xs) {
        ProgressView().controlSize(.small)
        Text(model.status).font(.caption).lineLimit(1)
      }
    } else if let outcome {
      Text(outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
    if points.isEmpty {
      Text("Nothing to rewind to yet.").font(.caption).foregroundStyle(.secondary)
    } else {
      ScrollView(.vertical) {
        RewindPointRows(points: points, picked: picked?.seq, busy: busy) { picked = $0 }
      }
      .frame(height: 180)
    }
  }

  static func time(_ p: RewindPoint) -> String {
    p.time.formatted(date: .omitted, time: .standard)
  }

  private func rewind(to p: RewindPoint) {
    picked = nil
    busy = true
    outcome = nil
    Task {
      do {
        try await model.rewindJournal(toSeq: p.seq)
        outcome = model.status
      } catch {
        let line = "rewind to seq \(p.seq) failed: \(error)"
        model.status = line
        outcome = line
      }
      busy = false
      older = await model.fileRewindPoints()
    }
  }
}

/// The rewind picker's rows, newest first, each with its ⟲ (outside the panel's ScrollView so
/// the layout tests can draw them: `ImageRenderer` draws no ScrollView). The ⟲ is a plain
/// button, a SwiftUI-drawn label, so it renders offscreen as on screen.
struct RewindPointRows: View {
  let points: [RewindPoint]
  let picked: Int?
  let busy: Bool
  let pick: (RewindPoint) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(points.enumerated()), id: \.element.id) { i, p in
        if p.fromFile, i == 0 || !points[i - 1].fromFile {
          Text("earlier — checkpoints in the file").font(.caption2).foregroundStyle(.secondary)
            .padding(.top, DJStyle.xs)
        }
        row(p)
      }
    }
  }

  private func row(_ p: RewindPoint) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DJStyle.xs) {
      Text(HistoryPanel.time(p)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      Text(p.summary).font(.caption).lineLimit(1)
        .foregroundStyle(Self.color(p.kind))
        .fontWeight(p.kind == .action ? .regular : .semibold)
      Spacer(minLength: 0)
      Button("⟲") { pick(p) }
        .buttonStyle(.plain).font(.caption.bold()).foregroundStyle(.orange)
        .disabled(busy).help("Rewind to #\(p.seq)…")
    }
    .padding(.vertical, 1)
    .background(picked == p.seq ? Color.orange.opacity(0.15) : .clear)
  }

  private static func color(_ k: RewindPoint.Kind) -> Color {
    switch k {
    case .note: noteTint
    case .mark: .orange
    case .checkpoint: .cyan
    case .action: .primary
    }
  }
}

/// A loop clip's notes: a pencil on its tile (lit, with a count, when it has some); click for
/// the list and a field to add one.
struct ClipNoteMarker: View {
  let clipID: String
  let model: AppModel
  @State private var open = false
  @State private var text = ""

  var body: some View {
    let notes = model.clipNotes(clipID)
    Button {
      open.toggle()
    } label: {
      Text(notes.isEmpty ? "✎" : "✎\(notes.count)").font(.caption2.bold())
        .foregroundStyle(notes.isEmpty ? Color.secondary.opacity(0.6) : noteTint)
    }
    .buttonStyle(.borderless)
    .help(notes.isEmpty ? "Leave a note on this loop" : notes.map(\.text).joined(separator: "\n"))
    .popover(isPresented: $open) {
      VStack(alignment: .leading, spacing: DJStyle.xs) {
        ForEach(notes) { n in NoteRow(note: n, model: model) }
        HStack {
          TextField("Note on this loop…", text: $text).frame(width: 220).onSubmit(add)
          Button("Add", action: add)
        }
      }
      .padding(DJStyle.s).frame(minWidth: 280)
    }
  }

  private func add() {
    guard model.addClipNote(clipID, text) != nil else { return }
    text = ""
  }
}
