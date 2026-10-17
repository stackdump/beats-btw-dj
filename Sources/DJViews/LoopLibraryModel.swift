import AppKit
import DJCore
import SwiftUI
import UniformTypeIdentifiers

/// The last loop taken off the row, for its "Undo" (shown `undoSeconds`).
struct LoopRemoval: Equatable {
  var id: String
  var title: String
  /// When (the model's `uptime`).
  var at: Double
  static let undoSeconds = 8.0
}

/// What the Loops row shows. Filtering only hides tiles: pad slots (A1…B4) still follow the
/// order of every clip on the row.
struct LoopFilter: Equatable {
  /// The sources shown ("A", "B", "seq" for sequences); empty shows them all.
  var sources: Set<String> = []
  /// Matched against titles, the genre and the title of what they were taken from.
  var search = ""
  /// Only loops within `tempoTolerance` of the playing tempo (when something plays).
  var nearTempo = false
  static let tempoTolerance = 0.05
  static let sourceChips = ["A", "B", "seq"]

  var isActive: Bool {
    !sources.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty || nearTempo
  }

  static func source(of c: ClipState) -> String { c.steps != nil ? "seq" : c.source }

  func matches(_ c: ClipState, tempo: Double?) -> Bool {
    if !sources.isEmpty, !sources.contains(Self.source(of: c)) { return false }
    if nearTempo, let tempo, tempo > 0, abs(c.bpm / tempo - 1) > Self.tempoTolerance {
      return false
    }
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return true }
    return [c.title, c.genre, c.originTitle].compactMap { $0?.lowercased() }.contains {
      $0.contains(q)
    }
  }
}

extension AppModel {
  /// The tempo the row's tempo filter works from: the first playing deck's.
  var playingTempo: Double? {
    decks.keys.sorted().compactMap { n in decks[n].flatMap { $0.playing ? $0.bpm : nil } }.first
  }

  /// The tiles the row shows, in row order.
  var visibleClips: [ClipState] {
    guard loopFilter.isActive else { return clips }
    let tempo = playingTempo
    return clips.filter { loopFilter.matches($0, tempo: tempo) }
  }

  /// The Inpulse pad (LOOP pad mode) that switches clip `id`: A1…A4, B1…B4 by its place among
  /// every clip on the row, whatever the filter shows.
  func padSlot(_ id: String) -> String? {
    guard let i = clips.firstIndex(where: { $0.id == id }), i < 8 else { return nil }
    return i < 4 ? "A\(i + 1)" : "B\(i - 3)"
  }

  func toggleSourceFilter(_ s: String) {
    if loopFilter.sources.contains(s) {
      loopFilter.sources.remove(s)
    } else {
      loopFilter.sources.insert(s)
    }
  }

  // MARK: removal, recorded, and reversible

  /// Take a clip off the row. Its audio is kept (`removed/` in the library) and "Undo" shows
  /// for a few seconds.
  func removeClip(_ id: String) {
    guard let dj = engine, let c = dj.clip(id) else { return }
    dj.perform(.clipRemove(id: id))
    lastRemoval = LoopRemoval(id: id, title: c.title, at: uptime())
    pollLoops(dj)
  }

  /// Put the last removed loop back where it was.
  func undoRemove() {
    guard let r = lastRemoval else { return }
    lastRemoval = nil
    restoreRemoved(r.id)
  }

  /// Put a removed loop back on the row where it was: from this launch's, or decoded from the
  /// library's `removed/`.
  @discardableResult
  func restoreRemoved(_ id: String) -> Bool {
    guard let dj = engine else { return false }
    if !dj.removedClips.contains(where: { $0.clip.id == id }) {
      guard let store = takeStore, let entry = removedLoops.first(where: { $0.id == id }) else {
        return false
      }
      let sr = dj.sampleRate
      guard let clip = saveQueue.sync(execute: { store.removedClip(id, sampleRate: sr) }) else {
        status = "that loop's audio is gone"
        return false
      }
      dj.rememberRemovedClip(clip, at: entry.index)
    }
    dj.perform(.clipRestore(id: id, at: nil))
    if lastRemoval?.id == id { lastRemoval = nil }
    pollLoops(dj)
    return dj.clip(id) != nil
  }

  /// Delete a removed loop for good (its audio too).
  func deleteForever(_ id: String) {
    guard let dj = engine else { return }
    dj.perform(.clipForget(id: id))
    diskRemoved.removeAll { $0.id == id }
    if lastRemoval?.id == id { lastRemoval = nil }
    if let store = takeStore {
      saveQueue.async {
        do { try store.deleteForever(id) } catch { print("loop library: \(error)") }
      }
    }
    pollLoops(dj)
  }

  /// This launch's removed loops, then the library's, newest first; "Undo" expires.
  func pollRemoved(_ dj: DJEngine) {
    if let r = lastRemoval, uptime() - r.at > LoopRemoval.undoSeconds || dj.clip(r.id) != nil {
      lastRemoval = nil
    }
    let now = dj.removedClips.map { RemovedLoop($0) }
    let seen = Set(now.map(\.id))
    let onRow = Set(dj.clips.map(\.id))
    let list = now + diskRemoved.filter { !seen.contains($0.id) && !onRow.contains($0.id) }
    if list != removedLoops { removedLoops = list }
  }

  // MARK: names and colours

  func renameClip(_ id: String, _ title: String) {
    guard let dj = engine, let c = dj.clip(id) else { return }
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t != c.title else { return }
    dj.perform(.clipRename(id: id, title: t))
    pollLoops(dj)
  }

  func setClipColor(_ id: String, _ color: String?) {
    guard let dj = engine, dj.clip(id) != nil else { return }
    dj.perform(.clipColor(id: id, color: color))
    pollLoops(dj)
  }

  // MARK: where it came from

  func canLoadOrigin(_ id: String, _ dj: DJEngine) -> Bool {
    if originCacheSamples != dj.sampleLibrary.count {
      originCache = [:]
      originCacheSamples = dj.sampleLibrary.count
    }
    if let known = originCache[id] { return known }
    let can = dj.clipOrigin(id) != nil
    originCache[id] = can
    return can
  }

  /// Load the track a loop was taken from onto `deck` (a net composed again; a sample only while
  /// its audio is in memory), at the section it was in. Through `perform`, so it records.
  @discardableResult
  func loadOrigin(_ id: String, on deck: String) async -> Bool {
    guard let dj = engine, let o = dj.clipOrigin(id) else {
      status = "can't load where that loop came from"
      return false
    }
    switch o.source {
    case .net, .rawNets:
      guard await prepareAndLoad(deck, o.source) else { return false }
    default:
      dj.perform(.load(deck: deck, source: o.source), buffer: o.buffer)
    }
    if let s = o.section { launchSection(deck, s) }
    return true
  }

  // MARK: out of the app

  /// Ask where to save a loop's audio, and write it there.
  func exportClip(_ id: String) {
    guard let c = engine?.clip(id) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.wav]
    panel.nameFieldStringValue = c.fileName
    panel.title = "Export loop"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try c.wavData().write(to: url, options: .atomic) } catch {
      status = "export: \(error)"
    }
  }
}

/// A tile being dragged: the clip id for drops in the app (decks, other tiles, the row), and a
/// WAV file for Finder and other apps, written when one asks for it.
struct ClipDrag: Transferable {
  let id: String
  let clip: LoopClip?

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .wav) { d in
      guard let clip = d.clip else { throw CocoaError(.fileNoSuchFile) }
      return SentTransferredFile(try ClipDrag.file(for: clip))
    }
    ProxyRepresentation(exporting: \.id)
  }

  /// The clip as a WAV in a temporary folder of its own, named after its title.
  static func file(for clip: LoopClip) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("dj-vevr-se-drag/\(clip.id.prefix(16))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(clip.fileName)
    if !FileManager.default.fileExists(atPath: url.path) {
      try clip.wavData().write(to: url, options: .atomic)
    }
    return url
  }
}
