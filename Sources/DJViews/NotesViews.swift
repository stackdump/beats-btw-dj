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
/// one row, notes highlighted.
struct HistoryPanel: View {
  let model: AppModel
  @State private var notesOnly = false
  static let shown = 80

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
    let rows = Self.rows(model.journalEntries, notesOnly: notesOnly)
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      HStack(spacing: DJStyle.xs) {
        SectionLabel("Journal")
        Toggle("Notes only", isOn: $notesOnly).toggleStyle(.button).controlSize(.mini)
          .tint(noteTint)
      }
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
      if let file = model.journal?.file.lastPathComponent {
        Text("\(file) · djctl journal show latest")
          .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
      }
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
