import Foundation

/// A session laid out the way cdn.stackdump.com stores a CID: `blobs/<cid>/` holding
/// `index.md` (frontmatter is the metadata of record), `session.json` (the canonical bytes —
/// the directory name is the hash of exactly this) and optionally `audio.wav`.
///
/// This mirrors beats-builder's `publish.cdn.publish_to_cdn`: stage the files into the CDN
/// master's blob tree on valoper, ping `/admin/reload?cid=`, and (separately, and only on
/// request) run `mirror-push.sh`, which is what makes it public on pflow.dev.
public struct SessionBundle: Sendable {
  public struct File: Sendable, Equatable {
    public var name: String
    public var data: Data
  }

  public let cid: String
  /// In write order. `index.md` is last: the indexer ignores a directory without one, so a
  /// half-copied bundle is never served.
  public let files: [File]

  public static let publicBase = "https://cdn.stackdump.com/ipfs/"
  public var publicURL: String { Self.publicBase + cid + "/" }

  /// A CID as the CDN's `validCID` accepts it (6–128 of A–Z a–z 0–9 - _), which is also safe
  /// to put in a shell line and can't escape the blobs directory.
  public static func isSafeCID(_ s: String) -> Bool {
    s.utf8.count >= 6 && s.utf8.count <= 128
      && s.utf8.allSatisfy {
        ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x30 && $0 <= 0x39)
          || $0 == 0x2d || $0 == 0x5f
      }
  }

  /// `renderedAt` is passed in (not read from the clock) so bundles are reproducible.
  public init(
    session: Session, title: String? = nil, audioWAV: [UInt8]? = nil, renderedAt: String,
    draft: Bool = false
  ) throws {
    let cid = session.cid
    guard Self.isSafeCID(cid) else { throw PublishError.unsafeCID(cid) }
    self.cid = cid
    var files = [File(name: "session.json", data: Data((session.canonical + "\n").utf8))]
    if let audioWAV { files.append(File(name: "audio.wav", data: Data(audioWAV))) }
    let md = Self.indexMarkdown(
      session: session, cid: cid, title: title, renderedAt: renderedAt, draft: draft,
      hasAudio: audioWAV != nil)
    files.append(File(name: "index.md", data: Data(md.utf8)))
    self.files = files
  }

  static func indexMarkdown(
    session: Session, cid: String, title: String?, renderedAt: String, draft: Bool,
    hasAudio: Bool
  ) -> String {
    var genres: [String] = []
    for name in session.decks.keys.sorted() {
      if case .net(let spec)? = session.decks[name], !genres.contains(spec.genre) {
        genres.append(spec.genre)
      }
    }
    let seconds = Int(session.duration.rounded())
    let name = title ?? "Live set \(cid.prefix(10))"
    var l = [
      "---", "title: \(yamlString(name))", "cid: \(cid)", "source: dj-vevr-se",
      "schema: \(Session.schema)",
    ]
    if let g = genres.first { l.append("genre: \(g)") }
    l.append("renderedAt: \(renderedAt)")
    l.append("provenance: performance")
    if draft { l.append("draft: true") }
    l.append("tags:")
    for t in ["live-set"] + genres { l.append("  - \(t)") }
    l.append("---")
    l.append("")
    l.append(
      "A \(seconds) s live performance on \(session.decks.count) deck"
        + "\(session.decks.count == 1 ? "" : "s") "
        + "(\(session.events.count) recorded events). `session.json` is the canonical "
        + "session; this directory's name is its CID, so it re-renders to the same set.")
    if hasAudio { l.append("\n`audio.wav` is the offline render of that session.") }
    l.append("")
    return l.joined(separator: "\n")
  }

  static func yamlString(_ s: String) -> String {
    if s.isEmpty { return "\"\"" }
    let needs =
      s.contains { ":#[]{},&*!|>'\"%@`\\".contains($0) }
      || s != s.trimmingCharacters(in: .whitespaces)
    guard needs else { return s }
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}

public enum PublishError: Error, Equatable, CustomStringConvertible {
  case unsafeCID(String)
  case commandFailed(String, Int32, String)

  public var description: String {
    switch self {
    case .unsafeCID(let c): "refusing to publish unsafe CID \(c)"
    case .commandFailed(let c, let s, let e): "\(c) exited \(s): \(e)"
    }
  }
}

/// Where a bundle goes.
public protocol CDNTransport: Sendable {
  /// Put the bundle's files under `blobs/<cid>/`.
  func stage(_ bundle: SessionBundle) throws
  /// As `stage`, reporting each file as it starts (transports that can't stream just call
  /// `stage`; the default does that).
  func stage(_ bundle: SessionBundle, progress: (PublishStep) -> Void) throws
  /// Tell the CDN master to index just this CID. Returns whether it said yes.
  func reload(cid: String) throws -> Bool
  /// Push the master's blob tree to the public mirror (pflow.dev). This is what publishes.
  func mirror() throws
}

extension CDNTransport {
  public func stage(_ bundle: SessionBundle, progress: (PublishStep) -> Void) throws {
    progress(.staging(file: bundle.files.map(\.name).joined(separator: ", "), index: 1, of: 1))
    try stage(bundle)
  }
}

/// Writes straight into a blobs directory (tests; a CDN tree mounted locally).
public struct DirectoryTransport: CDNTransport {
  public let blobs: URL
  public init(blobs: URL) { self.blobs = blobs }
  public init(path: String) { self.blobs = URL(fileURLWithPath: path) }

  public func stage(_ bundle: SessionBundle) throws {
    let dir = blobs.appendingPathComponent(bundle.cid, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in bundle.files {
      try f.data.write(to: dir.appendingPathComponent(f.name), options: .atomic)
    }
  }
  public func reload(cid: String) throws -> Bool { true }
  public func mirror() throws {}
}

/// Stages onto valoper over ssh, the way the render farm does locally: nothing but the
/// existing ssh key is needed. `run` is the process seam (command line, stdin) for tests.
public struct SSHTransport: CDNTransport {
  public typealias Runner =
    @Sendable (_ argv: [String], _ stdin: [UInt8]?) throws -> (
      status: Int32, out: String
    )

  public var host: String
  public var blobsDir: String
  public var reloadURL: String
  public var mirrorScript: String
  public var run: Runner

  public init(
    host: String = "valoper.local",
    blobsDir: String = "~/Workspace/cdn-stackdump-com/data/blobs",
    reloadURL: String = "http://127.0.0.1:18091/admin/reload",
    mirrorScript: String = "~/Workspace/cdn-stackdump-com/bin/mirror-push.sh",
    run: @escaping Runner = SSHTransport.process
  ) {
    self.host = host
    self.blobsDir = blobsDir
    self.reloadURL = reloadURL
    self.mirrorScript = mirrorScript
    self.run = run
  }

  /// `~/x` must expand on the remote side, so a leading `~/` is left outside the quotes.
  static func remotePath(_ p: String) -> String {
    p.hasPrefix("~/") ? "~/" + shellQuote(String(p.dropFirst(2))) : shellQuote(p)
  }
  static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func ssh(_ command: String, stdin: [UInt8]? = nil) throws -> (Int32, String) {
    let r = try run(
      [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
        host, command,
      ], stdin)
    return (r.status, r.out)
  }

  public func stage(_ bundle: SessionBundle) throws { try stage(bundle, progress: { _ in }) }

  public func stage(_ bundle: SessionBundle, progress: (PublishStep) -> Void) throws {
    guard SessionBundle.isSafeCID(bundle.cid) else { throw PublishError.unsafeCID(bundle.cid) }
    let dir = Self.remotePath(blobsDir) + "/" + bundle.cid
    for (i, f) in bundle.files.enumerated() {
      progress(.staging(file: f.name, index: i + 1, of: bundle.files.count))
      // write to a dotfile and rename, so a reader never sees a partial file
      let tmp = "\(dir)/.\(f.name).part"
      let cmd = "mkdir -p \(dir) && cat > \(tmp) && mv \(tmp) \(dir)/\(f.name)"
      let (status, out) = try ssh(cmd, stdin: Array(f.data))
      guard status == 0 else { throw PublishError.commandFailed("stage \(f.name)", status, out) }
    }
  }

  public func reload(cid: String) throws -> Bool {
    guard SessionBundle.isSafeCID(cid) else { throw PublishError.unsafeCID(cid) }
    let url = Self.shellQuote("\(reloadURL)?cid=\(cid)")
    let (status, _) = try ssh("curl -s -f -m 10 -X POST \(url) >/dev/null")
    return status == 0
  }

  public func mirror() throws {
    let script = Self.remotePath(mirrorScript)
    let (status, out) = try ssh("test -x \(script) && nohup \(script) >/dev/null 2>&1 &")
    guard status == 0 else { throw PublishError.commandFailed("mirror-push", status, out) }
  }

  public static func process(_ argv: [String], _ stdin: [UInt8]?) throws -> (
    status: Int32, out: String
  ) {
    // A write to a pipe whose reader (ssh) already exited is SIGPIPE, which would take the app
    // down. Ignoring it turns it into an EPIPE error from `write(contentsOf:)` below.
    signal(SIGPIPE, SIG_IGN)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = argv
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let inp = Pipe()
    p.standardInput = inp
    try p.run()
    // Feed stdin on its own thread so a large WAV can't deadlock against ssh's output pipe.
    let writer = DispatchQueue(label: "ssh-stdin")
    let done = DispatchSemaphore(value: 0)
    writer.async {
      if let stdin { try? inp.fileHandleForWriting.write(contentsOf: Data(stdin)) }
      try? inp.fileHandleForWriting.close()
      done.signal()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    done.wait()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

public struct PublishResult: Equatable, Sendable {
  public var cid: String
  public var url: String
  public var reloaded: Bool
  public var mirrored: Bool
}

/// Where `publishSession` is, for a progress line.
public enum PublishStep: Equatable, Sendable {
  case staging(file: String, index: Int, of: Int)
  case reloading
  case mirroring
  case done
}

/// Stage, reload, and (only when asked) mirror. The mirror step is the public one.
public func publishSession(
  _ bundle: SessionBundle, via transport: CDNTransport, mirror: Bool,
  progress: (PublishStep) -> Void = { _ in }
) throws -> PublishResult {
  try transport.stage(bundle, progress: progress)
  progress(.reloading)
  let reloaded = try transport.reload(cid: bundle.cid)
  if mirror {
    progress(.mirroring)
    try transport.mirror()
  }
  progress(.done)
  return PublishResult(cid: bundle.cid, url: bundle.publicURL, reloaded: reloaded, mirrored: mirror)
}

/// Whether a published bundle is reachable at its public URL yet. `mirror-push.sh` runs in the
/// background on valoper (rsync to pflow.dev), so right after `publishSession` the answer is
/// usually "not yet"; this polls the last file written (`index.md`) and the audio, if any.
public struct PublicProbe: Sendable {
  /// HTTP status of a HEAD request, nil when the request failed. The seam for tests.
  public typealias Head = @Sendable (URL) -> Int?
  public var head: Head
  public var attempts: Int
  public var interval: TimeInterval

  public init(
    attempts: Int = 40, interval: TimeInterval = 3, head: @escaping Head = PublicProbe.urlSession
  ) {
    self.head = head
    self.attempts = attempts
    self.interval = interval
  }

  /// URLs that must answer 200 before the set counts as public.
  public static func urls(for bundle: SessionBundle) -> [URL] {
    bundle.files.compactMap { f in
      f.name == "session.json" ? nil : URL(string: bundle.publicURL + f.name)
    }
  }

  /// Blocks (call it off the main thread). True once every URL is 200, false after the last
  /// attempt. `onAttempt` gets the 1-based attempt number.
  public func wait(
    for bundle: SessionBundle,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    onAttempt: (Int) -> Void = { _ in }
  ) -> Bool {
    let urls = Self.urls(for: bundle)
    guard !urls.isEmpty else { return false }
    for n in 1...max(attempts, 1) {
      onAttempt(n)
      if urls.allSatisfy({ head($0) == 200 }) { return true }
      if n < attempts { sleep(interval) }
    }
    return false
  }

  public static let urlSession: Head = { url in
    var req = URLRequest(url: url, timeoutInterval: 8)
    req.httpMethod = "HEAD"
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let box = StatusBox()
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
      box.status = (resp as? HTTPURLResponse)?.statusCode
      sem.signal()
    }.resume()
    sem.wait()
    return box.status
  }

  private final class StatusBox: @unchecked Sendable { var status: Int? }
}
