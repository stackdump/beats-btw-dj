import Darwin
import Foundation

// The journal: the app's always-on, append-only log of every state change, the system of record
// a run can be rebuilt from (`JournalReplay`). One JSONL file per app run under
// `~/Library/Application Support/dj-vevr-se/journal/` (`$DJ_JOURNAL_DIR` overrides), named by
// the run's start time. Line 0 is a checkpoint (`JournalState`); every line after is one event
// with its sequence number, wall-clock time (metadata only) and engine frame (the timebase).
//
// Threads: events are recorded on the main / control side — `DJEngine.perform`, the
// `ControllerRouter` (MIDI is hopped to the main queue before routing), the app's store edits —
// never on the audio thread; the frame is the engine's atomic counter, read relaxed. Lines are
// encoded and written on the journal's own serial queue.
//
// Durability: each line is written with one `write(2)` as soon as the queue gets to it (a few
// microseconds after the event), so an app crash loses at most the lines still queued and can
// cut only the last line short — readers drop a torn last line. `fsync` runs at most once a
// second (and on checkpoints and close): enough against a kernel panic or power cut, without
// paying a disk flush for each of the hundreds of events a fader sweep makes.

public final class Journal: @unchecked Sendable {
  public static let fileExtension = "jsonl"
  /// How often the file is flushed to disk at most (seconds).
  public static let syncInterval = 1.0
  /// How many entries `recent` keeps (the History panel).
  public static let recentCapacity = 400

  public let file: URL
  public let started: Date
  private weak var engine: DJEngine?
  /// The stores' contents for a checkpoint (the app's favorites, crates, variations, notes).
  private let stores: () -> JournalStoreState
  private let lock = NSLock()
  private var nextSeq = 0
  private var ring: [JournalEntry] = []
  private let queue = DispatchQueue(label: "dj-vevr-se.journal", qos: .utility)
  // queue-only state
  private var fd: Int32
  private var lastSync = 0.0
  private var syncPending = false
  private var writeError: String?

  /// Where the journals live: `$DJ_JOURNAL_DIR`, else the app's support folder.
  public static var defaultDirectory: URL {
    if let d = ProcessInfo.processInfo.environment["DJ_JOURNAL_DIR"], !d.isEmpty {
      return URL(fileURLWithPath: d, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/journal", isDirectory: true)
  }

  /// Open a new journal file for this run in `directory`, write its checkpoint, and attach it
  /// to `engine` (`DJEngine.journal`), so from here every input lands in it.
  public init(
    engine: DJEngine, directory: URL = Journal.defaultDirectory, started: Date = Date(),
    stores: @escaping () -> JournalStoreState = { JournalStoreState() }
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = "journal-" + Self.fileStamp(started)
    var url = directory.appendingPathComponent("\(base).\(Self.fileExtension)")
    var n = 1
    while FileManager.default.fileExists(atPath: url.path) {
      n += 1
      url = directory.appendingPathComponent("\(base)-\(n).\(Self.fileExtension)")
    }
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
    self.fd = fd
    file = url
    self.started = JournalTime.rounded(started)
    self.engine = engine
    self.stores = stores
    record(.checkpoint(JournalState(engine: engine, stores: stores())))
    engine.journal = self
  }

  // Queued writes hold the journal, so by now they have all run.
  deinit {
    if fd >= 0 {
      _ = Darwin.fsync(fd)
      Darwin.close(fd)
    }
  }

  /// "20261017T143205.123Z": sorts by time, safe in a file name.
  static func fileStamp(_ d: Date) -> String {
    var t = time_t(d.timeIntervalSince1970)
    var tmv = tm()
    gmtime_r(&t, &tmv)
    let ms = Int((d.timeIntervalSince1970 * 1000).rounded()) % 1000
    return String(
      format: "%04d%02d%02dT%02d%02d%02d.%03dZ", tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
      tmv.tm_hour, tmv.tm_min, tmv.tm_sec, ms)
  }

  /// Append an event, stamped with the next sequence number, now and the engine's frame.
  /// Cheap on the caller's thread (a lock, a struct); the line is encoded and written on the
  /// journal's queue. Never call it from the audio thread.
  @discardableResult
  public func record(_ event: JournalEvent) -> JournalEntry {
    let frame = engine?.frame ?? 0
    let entry: JournalEntry = lock.withLock {
      let e = JournalEntry(seq: nextSeq, time: JournalTime.now(), frame: frame, event: event)
      nextSeq += 1
      ring.append(e)
      if ring.count > Self.recentCapacity + Self.recentCapacity / 4 {
        ring.removeFirst(ring.count - Self.recentCapacity)
      }
      return e
    }
    let urgent: Bool
    if case .checkpoint = event { urgent = true } else { urgent = false }
    queue.async { self.write(entry, sync: urgent) }
    return entry
  }

  private func write(_ e: JournalEntry, sync urgent: Bool) {
    guard fd >= 0 else { return }
    var bytes = Array((e.line + "\n").utf8)
    var off = 0
    while off < bytes.count {
      let n = bytes.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress! + off, $0.count - off) }
      if n < 0 {
        if errno == EINTR { continue }
        writeError = String(cString: strerror(errno))
        return
      }
      off += n
    }
    bytes.removeAll()
    let now = ProcessInfo.processInfo.systemUptime
    if urgent || now - lastSync >= Self.syncInterval {
      _ = Darwin.fsync(fd)
      lastSync = now
    } else if !syncPending {
      syncPending = true
      queue.asyncAfter(deadline: .now() + Self.syncInterval) {
        self.syncPending = false
        if self.fd >= 0 {
          _ = Darwin.fsync(self.fd)
          self.lastSync = ProcessInfo.processInfo.systemUptime
        }
      }
    }
  }

  /// Wait for every recorded line to be written and synced.
  public func flush() {
    queue.sync { if fd >= 0 { _ = Darwin.fsync(fd) } }
  }

  /// Stop: detach from the engine, write what's queued, close the file.
  public func close() {
    if let engine, engine.journal === self { engine.journal = nil }
    queue.sync {
      if fd >= 0 {
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
        fd = -1
      }
    }
  }

  /// The last entries recorded (up to `recentCapacity`), oldest first.
  public var recent: [JournalEntry] {
    lock.withLock { Array(ring.suffix(Self.recentCapacity)) }
  }

  /// The sequence number of the last entry (0: only the checkpoint).
  public var lastSeq: Int { lock.withLock { nextSeq - 1 } }

  /// A write that failed (disk full…), if any.
  public var error: String? { queue.sync { writeError } }

  // MARK: reading

  /// The journal files in `directory`, newest first (by name: the start time).
  public static func list(in directory: URL = Journal.defaultDirectory) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasPrefix("journal-") && $0.hasSuffix("." + fileExtension) }
      .sorted(by: >).map { directory.appendingPathComponent($0) }
  }

  /// A journal file read back: its entries in order, and what was dropped.
  public struct Contents: Sendable {
    public var entries: [JournalEntry]
    /// Lines that didn't parse or are of a kind this build doesn't know (line numbers from 1).
    public var skipped: [Int]
    /// The last line was cut short (the app stopped mid-write).
    public var truncated: Bool

    /// The checkpoint the file starts with.
    public var checkpoint: JournalState? {
      if case .checkpoint(let s)? = entries.first?.event { return s }
      return nil
    }
  }

  /// Read a journal file. A last line without its newline that doesn't parse is a torn write
  /// (`truncated`), not an error; other bad lines are skipped and listed.
  public static func read(_ url: URL) throws -> Contents {
    let data = try Data(contentsOf: url)
    return parse(String(decoding: data, as: UTF8.self))
  }

  public static func parse(_ text: String) -> Contents {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let endsClean = text.hasSuffix("\n") || text.isEmpty
    if endsClean, lines.last == "" { lines.removeLast() }
    var out = Contents(entries: [], skipped: [], truncated: false)
    for (i, line) in lines.enumerated() where !line.isEmpty {
      if let e = JournalEntry(line: line) {
        out.entries.append(e)
      } else if i == lines.count - 1, !endsClean {
        out.truncated = true
      } else {
        out.skipped.append(i + 1)
      }
    }
    return out
  }

  /// The stores as the newest journal in `directory` leaves them: its checkpoint's, then its
  /// store events. Nil when there is no readable journal. (The app checks `notes.json` against
  /// it at launch: the journal is the notes' source of truth.)
  public static func latestStores(in directory: URL = Journal.defaultDirectory)
    -> JournalStoreState?
  {
    for url in list(in: directory) {
      guard let c = try? read(url), var s = c.checkpoint?.stores else { continue }
      for e in c.entries.dropFirst() { s.apply(e.event) }
      return s
    }
    return nil
  }
}
