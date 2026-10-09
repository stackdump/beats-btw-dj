import Foundation

/// The running app's control channel: a Unix socket speaking newline-delimited JSON.
///
///     → {"id": 1, "method": "state", "params": {}}
///     ← {"id": 1, "result": {…}}            or   {"id": 1, "error": "no deck C"}
///
/// The socket is user-only (0600) and local; `djctl mcp` bridges it to MCP. The handler is
/// where the app decides what a method means — this file only moves lines.
public enum ControlSocket {
  /// `$DJ_CONTROL_SOCKET`, else `~/Library/Application Support/DJApp/control.sock`.
  public static var defaultPath: String {
    if let p = ProcessInfo.processInfo.environment["DJ_CONTROL_SOCKET"], !p.isEmpty { return p }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJApp/control.sock").path
  }
}

public enum ControlError: Error, CustomStringConvertible, Equatable {
  /// The app answered with an error.
  case remote(String)
  /// Nothing listening, or the line could not be sent / read.
  case unavailable(String)
  case badReply(String)

  public var description: String {
    switch self {
    case .remote(let s): return s
    case .unavailable(let s): return s
    case .badReply(let s): return "bad reply from DJApp: \(s)"
    }
  }
}

public typealias ControlHandler =
  @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue

// MARK: - server

public final class ControlServer: @unchecked Sendable {
  public let path: String
  private let fd: Int32
  private let handler: ControlHandler

  /// Bind and start accepting. An existing socket file at `path` is replaced.
  public init(path: String = ControlSocket.defaultPath, handler: @escaping ControlHandler) throws {
    self.path = path
    self.handler = handler
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    unlink(path)
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { throw ControlError.unavailable("socket: \(errno)") }
    var addr = try unixAddress(path)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(s, 8) == 0 else {
      let e = errno
      close(s)
      throw ControlError.unavailable("bind \(path): errno \(e)")
    }
    fd = s
    let t = Thread { [self] in acceptLoop() }
    t.name = "dj-control-accept"
    t.start()
  }

  /// Stop accepting and remove the socket file. Open connections finish their line.
  public func stop() {
    shutdown(fd, SHUT_RDWR)
    close(fd)
    unlink(path)
  }

  private func acceptLoop() {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 {
        if errno == EINTR { continue }
        return  // closed by stop()
      }
      var one: Int32 = 1
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      let handler = handler
      Task.detached {
        let h = FileHandle(fileDescriptor: c, closeOnDealloc: true)
        do {
          for try await line in h.bytes.lines where !line.isEmpty {
            let reply = await Self.respond(to: line, handler: handler)
            guard writeAll(c, reply + "\n") else { break }
          }
        } catch {}
      }
    }
  }

  /// One request line → one reply line. Never throws: errors become `{"error": …}`.
  public static func respond(to line: String, handler: ControlHandler) async -> String {
    var reply = JSONObject()
    guard let req = try? JSONValue.parse(line), let method = req["method"]?.string else {
      reply["id"] = .null
      reply["error"] = .string("expected {\"id\", \"method\", \"params\"}")
      return JSONValue.object(reply).jsStringified
    }
    reply["id"] = req["id"] ?? .null
    do {
      reply["result"] = try await handler(method, req["params"] ?? .object(JSONObject()))
    } catch {
      reply["error"] = .string("\(error)")
    }
    return JSONValue.object(reply).jsStringified
  }
}

// MARK: - client

/// One connection to the app. Synchronous: `djctl` is a plain CLI.
public final class ControlClient {
  private let fd: Int32
  private var nextID = 1
  private var buffer: [UInt8] = []

  /// `timeout`: how long one request may take (composing a track takes a few seconds).
  public init(path: String = ControlSocket.defaultPath, timeout: TimeInterval = 120) throws {
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    guard s >= 0 else { throw ControlError.unavailable("socket: \(errno)") }
    var addr = try unixAddress(path)
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0 else {
      close(s)
      throw ControlError.unavailable(
        "DJApp is not running (nothing listening on \(path)). Start it with `make run-app`.")
    }
    var one: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    fd = s
  }

  deinit { close(fd) }

  public func request(_ method: String, _ params: JSONValue = .object(JSONObject())) throws
    -> JSONValue
  {
    let id = nextID
    nextID += 1
    let req = JSONValue.object(
      JSONObject([("id", .int(id)), ("method", .string(method)), ("params", params)]))
    guard writeAll(fd, req.jsStringified + "\n") else {
      throw ControlError.unavailable("DJApp closed the connection")
    }
    let line = try readLine()
    guard let reply = try? JSONValue.parse(line) else { throw ControlError.badReply(line) }
    if let e = reply["error"]?.string { throw ControlError.remote(e) }
    return reply["result"] ?? .null
  }

  private func readLine() throws -> String {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let nl = buffer.firstIndex(of: 0x0A) {
        let line = String(decoding: buffer[..<nl], as: UTF8.self)
        buffer.removeSubrange(...nl)
        return line
      }
      let n = read(fd, &chunk, chunk.count)
      if n <= 0 {
        throw ControlError.unavailable(
          n == 0 ? "DJApp closed the connection" : "no reply from DJApp (errno \(errno))")
      }
      buffer.append(contentsOf: chunk[..<n])
    }
  }
}

// MARK: - plumbing

private func unixAddress(_ path: String) throws -> sockaddr_un {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let cap = MemoryLayout.size(ofValue: addr.sun_path)
  guard bytes.count < cap else {
    throw ControlError.unavailable("socket path too long (\(bytes.count) ≥ \(cap)): \(path)")
  }
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  return addr
}

@discardableResult
private func writeAll(_ fd: Int32, _ s: String) -> Bool {
  var bytes = Array(s.utf8)[...]
  while !bytes.isEmpty {
    let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if n < 0 && errno == EINTR { continue }
    guard n > 0 else { return false }
    bytes = bytes.dropFirst(n)
  }
  return true
}
