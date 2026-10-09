import AppKit
import DJCore
import Foundation

/// The control socket's methods (see `ControlSocket`, `MCPBridge`). Everything goes through
/// the same calls the app's own buttons make, so it lands in a recorded session the same way.
extension AppModel {
  public enum ControlRequestError: Error, CustomStringConvertible {
    case bad(String)
    public var description: String {
      switch self {
      case .bad(let s): return s
      }
    }
  }

  /// Start listening (the real app only; tests call `control` directly).
  func startControlServer() {
    do {
      controlServer = try ControlServer { [weak self] method, params in
        guard let self else { throw ControlRequestError.bad("DJApp is shutting down") }
        return try await self.control(method, params)
      }
    } catch {
      status = "control socket: \(error)"
    }
  }

  public func control(_ method: String, _ p: JSONValue) async throws -> JSONValue {
    guard let dj = engine else { throw ControlRequestError.bad("the audio engine did not start") }
    switch method {
    case "state":
      poll()
      return controlState()

    case "catalog":
      return controlCatalog()

    case "perform":
      guard let a = p["action"], let action = DeckAction(json: a) else {
        throw ControlRequestError.bad(
          "`action` must be an object with a known `op` (see the dj_perform description)")
      }
      if case .load = action {
        throw ControlRequestError.bad("use dj_generate or dj_load_file to load a deck")
      }
      if let deck = a["deck"]?.string {
        let d = try requireDeck(deck)
        let netOnly = ["section", "role", "macro", "stinger", "panic"]
        if let op = a["op"]?.string, netOnly.contains(op), d.mode != .net {
          throw ControlRequestError.bad("deck \(deck) is playing a sample; \(op) needs a net deck")
        }
        if case .macro(_, let id) = action, !NetMacro.allCases.contains(where: { $0.id == id }) {
          throw ControlRequestError.bad("unknown macro \(id) (see dj_catalog)")
        }
      }
      dj.perform(action)
      poll()
      return a["deck"]?.string.flatMap { deckJSON($0) } ?? controlState()

    case "generate":
      let deck = p["deck"]?.string ?? ""
      _ = try requireDeck(deck)
      guard let genre = p["genre"]?.string, BeatsTables.shared.genres[genre] != nil else {
        throw ControlRequestError.bad("unknown genre (see dj_catalog)")
      }
      let structure = p["structure"]?.string
      if let structure, !Self.structures.contains(structure) {
        throw ControlRequestError.bad("structure must be one of \(Self.structures)")
      }
      let spec = TrackSpec(genre: genre, seed: p["seed"]?.double ?? 1, structure: structure)
      await composeAndLoad(deck, spec)
      poll()
      return deckJSON(deck) ?? .null

    case "loadFile":
      let deck = p["deck"]?.string ?? ""
      _ = try requireDeck(deck)
      guard let path = p["path"]?.string, FileManager.default.fileExists(atPath: path) else {
        throw ControlRequestError.bad("no file at `path`")
      }
      guard load(deck, url: URL(fileURLWithPath: path)) else {
        throw ControlRequestError.bad(status)
      }
      poll()
      return deckJSON(deck) ?? .null

    case "pad":
      guard let group = p["group"]?.string, let index = p["index"]?.int else {
        throw ControlRequestError.bad("`group` and `index` are required")
      }
      if !showPads { setShowPads(true) }
      poll()
      guard let port = padPort, router?.press(port: port, group: group, index: index) == true
      else {
        throw ControlRequestError.bad("no pad \(group)[\(index)] on the APC mini")
      }
      poll()
      return controlState()

    case "screenshot":
      return try screenshot(to: p["path"]?.string)

    case "record":
      let on = p["on"]?.bool ?? false
      if on != isRecording { toggleRecording() }
      guard on == isRecording else { throw ControlRequestError.bad(status) }
      var o = JSONObject([("recording", .bool(isRecording)), ("status", .string(status))])
      if !on, let cid = lastSession { o["cid"] = .string(cid) }
      return .object(o)

    default:
      throw ControlRequestError.bad("unknown method \(method)")
    }
  }

  static let structures = ["minimal", "standard", "extended"]

  /// The app's own window as a PNG (no Screen Recording permission: it is our window).
  /// Default path: `~/Library/Application Support/DJApp/shots/<time>.png`.
  func screenshot(to path: String?) throws -> JSONValue {
    poll()
    guard
      let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
      let view = window.contentView
    else { throw ControlRequestError.bad("no visible DJApp window") }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw ControlRequestError.bad("could not allocate a bitmap for the window")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw ControlRequestError.bad("could not encode PNG")
    }
    let url: URL
    if let path {
      url = URL(fileURLWithPath: path)
    } else {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
        of: ":", with: "")
      url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DJApp/shots/\(stamp).png")
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    return .object(
      JSONObject([
        ("path", .string(url.path)), ("width", .int(rep.pixelsWide)),
        ("height", .int(rep.pixelsHigh)),
      ]))
  }

  private func requireDeck(_ name: String) throws -> Deck {
    guard let d = engine?[name] else {
      let have = (engine?.decks.keys.sorted() ?? []).joined(separator: ", ")
      throw ControlRequestError.bad("no deck \"\(name)\" (decks: \(have))")
    }
    return d
  }

  func controlState() -> JSONValue {
    var o = JSONObject()
    o["status"] = .string(status)
    o["decks"] = .object(
      JSONObject(decks.keys.sorted().compactMap { n in deckJSON(n).map { (n, $0) } }))
    o["crossfader"] = .number(crossfader)
    o["master"] = .number(master)
    o["focus"] = .string(engine?.focus ?? "A")
    o["recording"] = .bool(isRecording)
    if let s = lastSession { o["lastSession"] = .string(s) }
    o["controllers"] = .array(
      devices.map {
        .object(JSONObject([("port", .string($0.port)), ("profile", .string($0.profile))]))
      })
    if !lastMessage.isEmpty { o["lastMidi"] = .string(lastMessage) }
    o["padsOnScreen"] = .bool(showPads)
    return .object(o)
  }

  func deckJSON(_ name: String) -> JSONValue? {
    guard let s = decks[name], let d = engine?[name] else { return nil }
    var o = JSONObject()
    o["title"] = .string(s.title)
    o["mode"] = .string(s.isNet ? "net" : "sample")
    o["playing"] = .bool(s.playing)
    if let bpm = s.bpm { o["bpm"] = .number((bpm * 10).rounded() / 10) }
    o["position"] = .number((s.positionSeconds * 100).rounded() / 100)
    o["duration"] = .number((s.duration * 100).rounded() / 100)
    o["volume"] = .number(s.volume)
    o["filter"] = .number(s.filter)
    o["pitch"] = .number(s.pitch)
    o["eq"] = .object(
      JSONObject([
        ("low", .number(d.eqLow)), ("mid", .number(d.eqMid)), ("high", .number(d.eqHigh)),
      ]))
    o["quantize"] = .string(s.quantize)
    o["autoAdvance"] = .bool(d.autoAdvance)
    o["hotCues"] = .array(s.cues.sorted().map { .int($0) })
    if s.isNet {
      o["sections"] = .array(
        s.sections.enumerated().map { i, sec in
          .object(
            JSONObject([
              ("index", .int(i)), ("name", .string(sec.name)), ("steps", .int(sec.steps)),
            ]))
        })
      if let c = s.currentSection { o["currentSection"] = .int(c) }
      o["roles"] = .object(JSONObject(s.roles.map { ($0, .bool(s.rolesOn.contains($0))) }))
      o["beatInBar"] = .int(s.beatInBar)
      o["nextTrack"] = .string(s.nextReady ? "ready" : (s.nextComposing ? "composing" : "none"))
    }
    return .object(o)
  }

  func controlCatalog() -> JSONValue {
    var o = JSONObject()
    o["decks"] = .array((engine?.decks.keys.sorted() ?? []).map { .string($0) })
    o["genres"] = .array(BeatsTables.shared.genres.keys.sorted().map { .string($0) })
    o["structures"] = .array(Self.structures.map { .string($0) })
    o["macros"] = .array(
      NetMacro.allCases.map {
        .object(JSONObject([("id", .string($0.id)), ("label", .string($0.label))]))
      })
    o["apcPads"] = .array(
      SurfaceProfile.apcMiniMK2.deviceMap().filter { !$0.parked && $0.action != "unbound" }.map {
        var r = JSONObject([
          ("group", .string($0.group)), ("index", .int($0.index)), ("action", .string($0.action)),
        ])
        if let s = $0.shiftedAction { r["shifted"] = .string(s) }
        return .object(r)
      })
    return .object(o)
  }
}
