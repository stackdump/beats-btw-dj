import DJCore
import Foundation

// Kept out of the Testing files (see TempFavorites.swift).

/// A fresh temporary folder for journals.
func temporaryJournalDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "journal-\(UUID().uuidString)", isDirectory: true)
}

/// A notes store in a fresh temporary folder.
func temporaryNotes() -> NotesStore {
  NotesStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("notes-\(UUID().uuidString)/notes.json"))
}

/// The newest journal in `dir`, read back.
func newestJournal(_ dir: URL) throws -> Journal.Contents {
  guard let url = Journal.list(in: dir).first else { throw JournalError.noCheckpoint }
  return try Journal.read(url)
}
