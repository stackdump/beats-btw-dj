import Foundation

/// Gameplay on the valoper Minecraft server fires stingers: the `minecraft` MCP server's
/// `mc_recent_events` (a ring buffer of `{at, source, event, params}`, oldest first) is
/// polled by whoever runs the loop (`djctl minecraft events` reads it on stdin) and handed to
/// the app's `minecraftEvents` method, which maps each new event through
/// `Resources/voices/minecraft-events.json` and performs it on a deck (`DJEngine.perform`, so it
/// records). The polling loop is ops work; this is the part that has to be right: each event
/// fires once however often the window is re-read, and a deck gets at most one stinger a bar.
public struct MinecraftEvent: Equatable, Sendable {
  /// ISO-8601 with milliseconds, UTC (`new Date().toISOString()`): sorts as text.
  public var at: String
  /// `rpc` (management-protocol notifications) or `log` (the log bridge: chat, deaths,
  /// advancements).
  public var source: String
  /// The RPC method (`minecraft:notification/players/joined`) or `log:chat` / `log:death` /
  /// `log:advancement`.
  public var event: String
  public var params: JSONValue

  public init(at: String, source: String = "log", event: String, params: JSONValue = .null) {
    self.at = at
    self.source = source
    self.event = event
    self.params = params
  }

  public init?(json v: JSONValue) {
    guard let event = v["event"]?.string, let at = v["at"]?.string else { return nil }
    self.init(
      at: at, source: v["source"]?.string ?? "", event: event, params: v["params"] ?? .null)
  }

  /// Who it happened to: the log bridge's `params.player`, or a notification's player object
  /// (`params: [{id, name}]`, or `{player: {name}}`).
  public var player: String? {
    if let s = params["player"]?.string { return s }
    if let s = params["player"]?["name"]?.string { return s }
    if let s = params[0]?["name"]?.string { return s }
    return params[0]?["player"]?["name"]?.string
  }

  /// What tells two events apart at the same `at`.
  var key: String { event + "\u{1F}" + params.canonicalJS }

  /// The events in `text`: the tool's own array, `{events: [...]}`, or an MCP tool result
  /// (`{content: [{type: "text", text: "[...]"}]}`, or val_call's `{content: ["[...]"]}`)
  /// whose text is that array.
  public static func parse(_ text: String) throws -> [MinecraftEvent] {
    try parse(json: JSONValue.parse(text))
  }

  public static func parse(json v: JSONValue) throws -> [MinecraftEvent] {
    if let a = v.array {
      // an array of events, or a content array of text parts
      if a.allSatisfy({ $0["event"] != nil }) { return a.compactMap(MinecraftEvent.init(json:)) }
      var out: [MinecraftEvent] = []
      for part in a {
        guard let t = part.string ?? part["text"]?.string else { continue }
        out += try parse(t)
      }
      return out
    }
    if let e = v["events"] { return try parse(json: e) }
    if let c = v["content"] { return try parse(json: c) }
    if let r = v["result"] { return try parse(json: r) }
    throw MinecraftEventError.shape(
      "expected mc_recent_events' array of {at, source, event, params} (or an MCP result)")
  }
}

public enum MinecraftEventError: Error, CustomStringConvertible {
  case shape(String)
  public var description: String {
    switch self {
    case .shape(let s): return s
    }
  }
}

/// Which event plays what: `minecraft-events.json`'s `events`, event name → a deck action as
/// dj_perform takes it, without the deck (`{"op": "stinger", "n": 0}`).
public struct MinecraftEventMap: Sendable {
  public var actions: [String: JSONValue]

  public init(actions: [String: JSONValue]) { self.actions = actions }

  public init(json v: JSONValue) {
    var a: [String: JSONValue] = [:]
    for (k, e) in v["events"]?.object?.entries ?? [] where e["op"]?.string != nil { a[k] = e }
    self.init(actions: a)
  }

  /// The bundled map (the app's `Contents/Resources` first, SwiftPM's bundle second); empty
  /// when neither has it.
  public static let shared: MinecraftEventMap = {
    (try? load()) ?? MinecraftEventMap(actions: [:])
  }()

  /// Where `load` looks, in order: the app's bundle, then SwiftPM's resource bundle.
  public static var defaultBundles: [Bundle] { [.main, .module] }

  public static func load(bundles: [Bundle] = defaultBundles) throws -> MinecraftEventMap {
    try MinecraftEventMap(json: JSONValue.parse(loadText(bundles: bundles)))
  }

  static func loadText(bundles: [Bundle] = defaultBundles) throws -> String {
    for b in bundles {
      if let url = b.url(
        forResource: "minecraft-events", withExtension: "json", subdirectory: "voices")
      {
        return try String(contentsOf: url, encoding: .utf8)
      }
    }
    throw CocoaError(
      .fileNoSuchFile, userInfo: [NSFilePathErrorKey: "voices/minecraft-events.json"])
  }

  /// The action `e` plays on `deck`, if the map names one.
  public func action(for e: MinecraftEvent, deck: String) -> DeckAction? {
    guard var o = actions[e.event]?.object else { return nil }
    o["deck"] = .string(deck)
    return DeckAction(json: .object(o))
  }
}

/// The poller's memory: a cursor over the event stream (so a re-read window fires nothing
/// twice) and, per deck, the bar its last stinger went on.
public struct MinecraftEventFeed: Sendable {
  public struct Fired: Sendable {
    public var event: MinecraftEvent
    public var action: DeckAction
  }
  public struct Skipped: Sendable {
    public var event: MinecraftEvent
    public var reason: String
  }

  public var map: MinecraftEventMap
  /// The newest `at` taken so far (nil: nothing yet).
  public private(set) var cursor: String?
  /// The events already taken whose `at` is the cursor (several can share a millisecond).
  private var atCursor: Set<String> = []
  /// Per deck, the bar its last stinger fired on.
  private var stingerBar: [String: Int] = [:]

  public init(map: MinecraftEventMap = .shared) { self.map = map }

  /// The events in `events` not taken before, oldest first, and what each plays on `deck`.
  /// `bar` is where the deck is now (`Deck.beatState?.bar`; nil when it has no grid: then one
  /// stinger per call); `net` is false when the deck can't play stingers. `prime` takes the
  /// events without playing any (start the loop without replaying the buffer's backlog).
  public mutating func take(
    _ events: [MinecraftEvent], deck: String, bar: Int?, net: Bool = true, prime: Bool = false
  ) -> (fired: [Fired], skipped: [Skipped]) {
    let fresh = events.enumerated()
      .filter { _, e in
        guard let c = cursor else { return true }
        return e.at > c || (e.at == c && !atCursor.contains(e.key))
      }
      .sorted {
        $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset
      }
      .map(\.element)
    var fired: [Fired] = []
    var skipped: [Skipped] = []
    var stungThisCall = false
    for e in fresh {
      if e.at != cursor {
        cursor = e.at
        atCursor = []
      }
      atCursor.insert(e.key)
      guard !prime else {
        skipped.append(Skipped(event: e, reason: "primed"))
        continue
      }
      guard let action = map.action(for: e, deck: deck) else {
        skipped.append(Skipped(event: e, reason: "unmapped"))
        continue
      }
      if case .stinger = action {
        guard net else {
          skipped.append(Skipped(event: e, reason: "deck \(deck) is not playing a net"))
          continue
        }
        if let bar {
          if stingerBar[deck] == bar {
            skipped.append(Skipped(event: e, reason: "a stinger already fired in bar \(bar)"))
            continue
          }
          stingerBar[deck] = bar
        } else if stungThisCall {
          skipped.append(Skipped(event: e, reason: "one stinger per poll without a beat grid"))
          continue
        }
        stungThisCall = true
      }
      fired.append(Fired(event: e, action: action))
    }
    return (fired, skipped)
  }

  /// The `minecraftEvents` reply: what fired, what didn't and why, and the cursor.
  public static func report(
    deck: String, fired: [Fired], skipped: [Skipped], cursor: String?
  ) -> JSONValue {
    func ev(_ e: MinecraftEvent) -> [(String, JSONValue)] {
      [("at", .string(e.at)), ("event", .string(e.event))]
        + (e.player.map { [("player", .string($0))] } ?? [])
    }
    return .object(
      JSONObject([
        ("deck", .string(deck)),
        (
          "fired",
          .array(fired.map { .object(JSONObject(ev($0.event) + [("action", $0.action.json)])) })
        ),
        (
          "skipped",
          .array(
            skipped.map { .object(JSONObject(ev($0.event) + [("reason", .string($0.reason))])) })
        ),
        ("cursor", cursor.map { .string($0) } ?? .null),
      ]))
  }
}

/// `djctl minecraft events`: stdin (an `mc_recent_events` result) → the `minecraftEvents`
/// request's params.
public enum MinecraftEventsCommand {
  public static func params(stdin text: String, deck: String?, prime: Bool = false) throws
    -> JSONValue
  {
    let events = try MinecraftEvent.parse(text)
    var o = JSONObject([
      (
        "events",
        .array(
          events.map {
            .object(
              JSONObject([
                ("at", .string($0.at)), ("source", .string($0.source)),
                ("event", .string($0.event)), ("params", $0.params),
              ]))
          })
      )
    ])
    if let deck { o["deck"] = .string(deck) }
    if prime { o["prime"] = .bool(true) }
    return .object(o)
  }

  /// One line per event the app fired, then the skipped count.
  public static func describe(_ reply: JSONValue) -> String {
    var lines: [String] = []
    let deck = reply["deck"]?.string ?? "?"
    for f in reply["fired"]?.array ?? [] {
      let who = f["player"]?.string.map { " (\($0))" } ?? ""
      lines.append(
        "\(f["at"]?.string ?? "")  \(f["event"]?.string ?? "")\(who) → \(deck) "
          + (f["action"]?.jsStringified ?? ""))
    }
    let skipped = reply["skipped"]?.array?.count ?? 0
    lines.append("fired \(reply["fired"]?.array?.count ?? 0), skipped \(skipped)")
    return lines.joined(separator: "\n")
  }
}
