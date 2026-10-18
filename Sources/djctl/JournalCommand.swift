import DJCore
import Foundation

// djctl journal list | show | replay | export-session — the app's journal (Journal.swift) from
// the command line. A file is a path, a name in the journal folder, `latest`, or its number in
// `list` (1 = newest). `--dir D` reads another folder (default: the app's, `$DJ_JOURNAL_DIR`).

let journalUsage = """
  usage: djctl journal list [--dir D]
         djctl journal show <file> [--all] [--notes] [--from SEQ] [--to SEQ] [--dir D]
         djctl journal replay <file> [--to SEQ | --at SECONDS] [--from-start] [--render out.wav]
                              [--float32] [--loops DIR] [--write-stores DIR] [--json] [--dir D]
         djctl journal export-session <file> --from SEQ --to SEQ [--store DIR] [--loops DIR]
  """

@MainActor func journalCommand() {
  let dir =
    value("--dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? Journal.defaultDirectory
  guard let sub = positional.first else {
    stderr(journalUsage)
    exit(2)
  }
  positional.removeFirst()
  do {
    switch sub {
    case "list": journalList(dir)
    case "show": try journalShow(dir)
    case "replay": try journalReplay(dir)
    case "export-session": try journalExport(dir)
    default:
      stderr(journalUsage)
      exit(2)
    }
  } catch {
    stderr("journal \(sub): \(error)")
    exit(1)
  }
}

/// The file a command names.
@MainActor func journalFile(_ dir: URL) throws -> URL {
  guard let arg = positional.first else {
    stderr(journalUsage)
    exit(2)
  }
  positional.removeFirst()
  let files = Journal.list(in: dir)
  if arg == "latest", let f = files.first { return f }
  if let n = Int(arg), n >= 1, n <= files.count { return files[n - 1] }
  if FileManager.default.fileExists(atPath: arg) { return URL(fileURLWithPath: arg) }
  let inDir = dir.appendingPathComponent(arg)
  if FileManager.default.fileExists(atPath: inDir.path) { return inDir }
  throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: arg])
}

/// Engine time of an entry from the checkpoint, "m:ss.mmm".
func journalClock(_ frame: Int, base: Int, rate: Double) -> String {
  let t = Double(frame - base) / max(rate, 1)
  return String(format: "%d:%06.3f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}

@MainActor func journalList(_ dir: URL) {
  let files = Journal.list(in: dir)
  if files.isEmpty { print("no journals in \(dir.path)") }
  for (i, url) in files.enumerated() {
    guard let c = try? Journal.read(url), let first = c.entries.first else {
      print("\(i + 1)  \(url.lastPathComponent)  (unreadable)")
      continue
    }
    let rate = c.checkpoint?.sampleRate ?? 48_000
    let last = c.entries.last!
    let notes = c.entries.filter { if case .noteAdd = $0.event { true } else { false } }.count
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print(
      "\(i + 1)  \(url.lastPathComponent)  \(c.entries.count) entries  "
        + journalClock(last.frame, base: first.frame, rate: rate)
        + (notes > 0 ? "  ✎\(notes)" : "") + "  \(size / 1024) KB"
        + (c.truncated ? "  (last line torn)" : ""))
  }
}

@MainActor func journalShow(_ dir: URL) throws {
  let all = flag("--all")
  let notesOnly = flag("--notes")
  let from = option("--from").map { Int($0) } ?? 0
  let to = option("--to").map { Int($0) } ?? Int.max
  let url = try journalFile(dir)
  let c = try Journal.read(url)
  guard let first = c.entries.first else { return }
  let rate = c.checkpoint?.sampleRate ?? 48_000
  let tty = isatty(STDOUT_FILENO) != 0
  let stamp = DateFormatter()
  stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
  print("\(url.lastPathComponent)  \(c.entries.count) entries")
  // where a replay can start: one row per checkpoint
  let checkpoints = c.checkpointIndices.map { c.entries[$0] }
  print("checkpoints: \(checkpoints.count)")
  for e in checkpoints {
    print(
      String(format: "  seq %6d  ", e.seq) + journalClock(e.frame, base: first.frame, rate: rate)
        + "  " + e.event.summary)
  }
  var i = 0
  let shown = c.entries.filter { $0.seq >= from && $0.seq <= to && (!notesOnly || $0.event.isNote) }
  while i < shown.count {
    let e = shown[i]
    // a fader sweep: one row for the run, with its last value
    var j = i
    if !all, let k = e.event.foldKey {
      while j + 1 < shown.count, shown[j + 1].event.foldKey == k { j += 1 }
    }
    let last = shown[j]
    let fold = j > i ? "  (×\(j - i + 1), seq \(e.seq)…\(last.seq))" : ""
    let text = last.event.summary + fold
    let line =
      String(format: "%6d  ", e.seq) + journalClock(e.frame, base: first.frame, rate: rate) + "  "
      + stamp.string(from: e.time) + "  " + text
    if e.event.isNote, tty {
      print("\u{1B}[1;33m\(line)\u{1B}[0m")
    } else {
      print(line)
    }
    i = j + 1
  }
  if c.truncated { print("(the last line was cut short: the app stopped while writing it)") }
  if !c.skipped.isEmpty {
    print("(skipped lines: \(c.skipped.map(String.init).joined(separator: ", ")))")
  }
  // the notes as they stand at the end, with their places
  if let s = c.checkpoint?.stores {
    var stores = s
    for e in c.entries.dropFirst() { stores.apply(e.event) }
    if !stores.notes.isEmpty {
      print("notes:")
      for n in stores.notes {
        print(
          "  ✎ \(n.title.isEmpty ? n.target.key : n.title)"
            + (n.position.map { " @ \($0.label)" } ?? "") + ": \(n.text)  [\(n.target.key)]")
      }
    }
  }
}

/// A loop library's clips by id, decoded at `rate`: the row, then `removed/`.
func libraryClips(_ rate: Double, dir: String?) -> (String) -> LoopClip? {
  let lib =
    dir.map { LoopLibrary(dir: URL(fileURLWithPath: $0, isDirectory: true)) }
    ?? LoopLibrary()
  var row: [String: LoopClip]?
  return { id in
    if row == nil { row = Dictionary(lib.load(sampleRate: rate).map { ($0.id, $0) }) { a, _ in a } }
    return row?[id] ?? lib.removedClip(id, sampleRate: rate)
  }
}

@MainActor func journalReplay(_ dir: URL) throws {
  let toSeq = option("--to").map { Int($0) }
  let at = option("--at")
  let fromStart = flag("--from-start")
  let render = value("--render")
  let float32 = flag("--float32")
  let json = flag("--json")
  let writeStores = value("--write-stores")
  let loops = value("--loops")
  let url = try journalFile(dir)
  let c = try Journal.read(url)
  guard let cp = c.checkpoint else { throw JournalError.noCheckpoint }
  let r = try Journal.replay(
    c, toSeq: toSeq, endFrame: at.map { Int($0 * cp.sampleRate) }, render: render != nil,
    fromStart: fromStart, clips: libraryClips(cp.sampleRate, dir: loops))
  if json {
    print(r.state.json.jsStringified)
  } else {
    print(
      "replayed \(url.lastPathComponent) to seq \(r.lastSeq)  "
        + journalClock(r.frames, base: 0, rate: cp.sampleRate)
        + "  (from checkpoint seq \(r.startSeq))")
    for name in r.state.decks.keys.sorted() {
      let d = r.state.decks[name]!
      print(
        "  \(name): \(d.source.summary)\(d.playing ? " ▶" : "")  vol \(String(format: "%.2f", d.params.volume))"
          + (d.params.disabledRoles.isEmpty
            ? "" : "  off: \(d.params.disabledRoles.joined(separator: ","))"))
    }
    print(
      String(format: "  mixer: crossfader %.2f  master %.2f", r.state.crossfader, r.state.master))
    print("  loops: \(r.state.clips.map(\.title).joined(separator: ", "))")
    if !r.state.locked.isEmpty { print("  locked: \(r.state.locked.joined(separator: ", "))") }
    let s = r.stores
    print(
      "  stores: \(s.favorites.count) favorites, \(s.crates.count) crates, "
        + "\(s.variations.values.map(\.count).reduce(0, +)) variations, \(s.notes.count) notes")
  }
  for w in r.warnings { stderr("warning: \(w)") }
  if render != nil, r.startSeq > 0 {
    stderr(
      "note: the audio starts at checkpoint seq \(r.startSeq) (--from-start renders the whole file)"
    )
  }
  if let render, let audio = r.audio {
    try WAV.encode(audio, float32: float32).write(
      to: URL(fileURLWithPath: render), options: .atomic)
    print("wrote \(render)  \(String(format: "%.2f", Double(audio.frames) / audio.sampleRate)) s")
  }
  if let writeStores {
    let d = URL(fileURLWithPath: writeStores, isDirectory: true)
    try FavoritesStore(file: d.appendingPathComponent("favorites.json")).replaceAll(
      r.stores.favorites)
    try VoiceVariationStore(file: d.appendingPathComponent("voices.json")).replaceAll(
      r.stores.variations)
    try NotesStore(file: d.appendingPathComponent("notes.json")).replaceAll(r.stores.notes)
    let crates = JSONValue.object(
      JSONObject([("crates", .array(r.stores.crates.map { .string($0) }))]))
    try Data((crates.canonicalJS + "\n").utf8).write(to: d.appendingPathComponent("crates.json"))
    print("stores written to \(d.path)")
  }
}

@MainActor func journalExport(_ dir: URL) throws {
  guard let from = option("--from").map({ Int($0) }), let to = option("--to").map({ Int($0) })
  else {
    stderr(journalUsage)
    exit(2)
  }
  let store = storeOption()
  let loops = value("--loops")
  let url = try journalFile(dir)
  let c = try Journal.read(url)
  guard let cp = c.checkpoint else { throw JournalError.noCheckpoint }
  let session = try Journal.exportSession(
    c, from: from, to: to, clips: libraryClips(cp.sampleRate, dir: loops))
  let saved = try store.save(session)
  print(
    "\(saved.cid)  \(String(format: "%.1f", session.duration)) s  \(session.events.count) events"
      + "  → \(saved.url.path)")
}
