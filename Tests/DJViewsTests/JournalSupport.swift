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

/// Stores unlike anything a test model starts with, for `AppModel.replaceStores`.
func replacementStores() -> JournalStoreState {
  let at = Date(timeIntervalSince1970: 1_700_000_000)
  return JournalStoreState(
    favorites: [
      Favorite(
        title: "new", source: .net(TrackSpec(genre: "house", seed: 7)), added: at, tags: ["warm"])
    ],
    crates: ["warm", "set 2"],
    variations: ["bass": [VoiceVariation(name: "deep", params: VoiceTweak(), useSynth: true)]],
    notes: [TrackNote(id: "n-9", target: .clip(id: "c"), text: "replaced", created: at)])
}
