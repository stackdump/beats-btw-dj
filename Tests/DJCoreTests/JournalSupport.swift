import DJCore
import Foundation

// Kept out of the Testing files: importing Foundation next to Testing needs a cross-import
// overlay Command Line Tools doesn't ship (see TempFavorites.swift).

/// A fresh temporary folder for journals.
func tempJournalDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "journal-\(UUID().uuidString)", isDirectory: true)
}

func removeDir(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// A file's text.
func fileText(_ url: URL) -> String {
  (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// Write `text` over a file.
func writeText(_ text: String, to url: URL) {
  try? Data(text.utf8).write(to: url)
}

/// A date at a whole second (what the stores' second-precision stamps survive).
func wholeSecond(_ s: Double) -> Date { Date(timeIntervalSince1970: s.rounded()) }

/// A stamp at the millisecond (what the journal's stamps survive).
func journalDate(_ s: Double) -> Date { JournalTime.rounded(Date(timeIntervalSince1970: s)) }

/// The notes store in a fresh temporary folder.
func tempNotesStore() -> NotesStore {
  NotesStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-\(UUID().uuidString)/notes.json"))
}

/// The app's stores as a test holds them while it journals: the journal reads them for its
/// checkpoint, the test applies each store event to them as it records it.
final class StoreBox: @unchecked Sendable {
  var state = JournalStoreState()
}

/// The newest journal in `dir`, read back.
func readNewestJournal(_ dir: URL) throws -> Journal.Contents {
  guard let url = Journal.list(in: dir).first else { throw JournalError.noCheckpoint }
  return try Journal.read(url)
}

/// The newest journal's text.
func newestJournalText(_ dir: URL) -> String {
  Journal.list(in: dir).first.map(fileText) ?? ""
}

/// How many journal files `dir` holds, and their names.
func journalNames(_ dir: URL) -> [String] { Journal.list(in: dir).map(\.lastPathComponent) }
