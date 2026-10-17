import CryptoKit
import Foundation

// A performance as data: the decks' starting contents, the mixer's starting state and the
// stream of inputs (controller messages and UI actions), each stamped with the engine
// frame it arrived on. Canonical JSON → CID, the way a beats track is content-addressed
// (share/codec.js: canonicalizeJSON → sha256 → CIDv1 dag-json), so a set can be named,
// compared and re-rendered by anyone holding the same samples.

public enum SessionError: Error, Equatable {
  /// A session starts with every deck stopped at its beginning.
  case notAtRest(deck: String)
  /// The deck holds something a session can't name (a hand-built net, not a `TrackSpec`).
  case unrecordable(deck: String)
  case badSchema
  case cidMismatch
  case missingSample(id: String)
}

/// Content id of decoded audio: sha256 over the rate and both channels' float bits.
extension SampleBuffer {
  public var contentID: String {
    var h = SHA256()
    var rate = sampleRate.bitPattern
    withUnsafeBytes(of: &rate) { h.update(bufferPointer: $0) }
    h.update(bufferPointer: UnsafeRawBufferPointer(start: left, count: length * 4))
    if right != left {
      h.update(bufferPointer: UnsafeRawBufferPointer(start: right, count: length * 4))
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// What a deck holds. Raw-`nets` payloads are equal when their canonical JSON is (a session
/// read back from its canonical text has them in sorted key order).
public enum DeckSourceDescriptor: Equatable, Sendable {
  case none
  /// Audio, by content id. The built-in demo loop is `demo-loop`. The grid is recorded so
  /// a replay doesn't depend on re-running the tempo analysis.
  case sample(id: String, title: String, grid: BeatGrid?)
  case net(TrackSpec)
  /// A raw-`nets` beats share: the envelope payload as given (its CID is `shareCID` of it).
  /// It plays `Share.rawNetsProject()` — the nets verbatim, arranged and overridden as the
  /// browser does — so a session names the share, not the project.
  case rawNets(payload: JSONValue)

  public static let demoID = "demo-loop"

  /// The seed a raw-`nets` deck picks its sampled instruments with: the envelope's `seed`
  /// when it has a number there, else 0 (the composed path uses the spec's seed).
  static func voicingSeed(rawNets payload: JSONValue) -> Double {
    if case .number(let s)? = payload["seed"] { return s }
    return 0
  }

  public static func == (a: Self, b: Self) -> Bool {
    switch (a, b) {
    case (.none, .none): return true
    case (.sample(let i, let t, let g), .sample(let j, let u, let h)):
      return i == j && t == u && g == h
    case (.net(let x), .net(let y)): return x == y
    case (.rawNets(let p), .rawNets(let q)): return p == q || p.canonicalJS == q.canonicalJS
    default: return false
    }
  }
}

/// Per-deck knobs at the start of a session.
public struct DeckParams: Equatable, Sendable {
  public var volume = 0.8
  public var gain = 0.5
  public var filter = 0.5
  public var eqLow = 0.5
  public var eqMid = 0.5
  public var eqHigh = 0.5
  public var pitch = 0.0
  public var quantize = "off"
  public var autoAdvance = false
  public var reverbWet = 0.0
  public var reverbSize = 0.5
  public var reverbTone = 0.5
  public init() {}
}

/// Every input a performer (or a UI) can give a deck. Controller hardware arrives as MIDI
/// bytes; these are the other ways in.
public enum DeckAction: Equatable, Sendable {
  case play(deck: String, on: Bool)
  case cue(deck: String)
  case hotCue(deck: String, slot: Int)
  case clearCue(deck: String, slot: Int)
  case loop(deck: String, op: String)  // in | out | halve | double
  /// name: volume | filter | gain | eqLow | eqMid | eqHigh | pitch | mute | reverbWet |
  /// reverbSize | reverbTone
  case param(deck: String, name: String, value: Double)
  case crossfader(Double)
  case master(Double)
  case load(deck: String, source: DeckSourceDescriptor)
  case queueNext(deck: String, spec: TrackSpec)
  case nextTrack(deck: String)
  case autoAdvance(deck: String, on: Bool)
  case section(deck: String, index: Int)
  case role(deck: String, role: String, on: Bool)
  case macro(deck: String, id: String)
  case panic(deck: String)
  case stinger(deck: String, n: Int)
  case sync(deck: String, align: String)  // beat | bar | tempo
  case quantize(deck: String, mode: String)  // off | beat | bar
  case follow(deck: String, leader: String?)
  /// The tempo analysis (or a tap) put a beat grid on a sample deck.
  case grid(deck: String, bpm: Double, offset: Double)
  /// LOOP record held (`on`) or let go on a deck (`DJEngine.loopRecord`).
  case loopRecord(deck: String, on: Bool)
  /// Put a LOOP-record clip on a deck or the loop channel ("L") (`DJEngine.playClip`).
  case clip(deck: String, id: String)
  /// Start (`on`) or stop a clip looping under the mixer, at the next downbeat.
  case clipLoop(id: String, on: Bool)
  /// A clip's level under the mixer, 0…1.
  case clipGain(id: String, value: Double)
  /// Crop a clip to its beats `from..<to` (`DJEngine.cropClip`).
  case clipCrop(id: String, from: Int, to: Int)
  /// Join clips into a sequence (`DJEngine.makeSequence`), or rewrite the one `replacing` names.
  case clipSequence(steps: [SequenceStep], replacing: String?)
  /// What loops start and stop on, in beats: 1 | 4 (a bar) | 8 | 16 | 32
  /// (`DJEngine.setLoopQuantum`).
  case loopQuantize(beats: Int)
  /// Save the loops playing now as scene `name` (overwriting one of that name).
  case sceneSave(name: String)
  /// Launch a scene: its clips in, every other loop out, on the next launch boundary. Recorded
  /// with the scene's `clips`, so a replay needs no saved scenes; nil launches the saved one.
  case sceneLaunch(name: String, clips: [SceneClip]?)
  case sceneRename(name: String, to: String)
  case sceneDelete(name: String)
}

public enum SessionEventKind: Equatable, Sendable {
  case midi(port: String, bytes: [UInt8])
  case action(DeckAction)
}

public struct SessionEvent: Equatable, Sendable {
  /// Engine frame (samples rendered since the session began) at which it was applied.
  public var frame: Int
  public var kind: SessionEventKind
  public init(frame: Int, kind: SessionEventKind) {
    self.frame = frame
    self.kind = kind
  }
}

public struct Session: Equatable, Sendable {
  public static let schema = "dj-vevr-se/session/v1"
  public var sampleRate: Double
  /// Length of the performance in frames.
  public var frames: Int
  public var decks: [String: DeckSourceDescriptor]
  public var params: [String: DeckParams]
  public var crossfader: Double
  public var master: Double
  public var events: [SessionEvent]

  public init(
    sampleRate: Double, frames: Int, decks: [String: DeckSourceDescriptor],
    params: [String: DeckParams], crossfader: Double, master: Double, events: [SessionEvent]
  ) {
    self.sampleRate = sampleRate
    self.frames = frames
    self.decks = decks
    self.params = params
    self.crossfader = crossfader
    self.master = master
    self.events = events
  }

  public var duration: TimeInterval { Double(frames) / sampleRate }
}

// MARK: - JSON

extension TrackSpec {
  /// A beats share-envelope payload for this spec (so a deck's source is a normal share),
  /// written where `shareFromPayload` reads it: the compose overrides in `extra` under
  /// `traits` (an array `macroCurve` at the top level, as beats writes it), `layers` under
  /// their envelope names. Keys `overrides` sets itself (seed, cohesion, a set structure) are
  /// left out of `traits`, so beats composes with the same params the deck does. A spec
  /// without extras writes exactly what it always did.
  public var payload: JSONValue {
    var o = JSONObject()
    o["genre"] = .string(genre)
    o["seed"] = .number(seed)
    if let structure, !structure.isEmpty { o["structure"] = .string(structure) }
    o["cohesion"] = .string(cohesion)
    var traits = JSONObject()
    for (k, v) in extra.entries where k != "seed" && k != "cohesion" {
      if k == "structure", o[k] != nil { continue }
      if k == "macroCurve", v.array != nil { o[k] = v } else { traits[k] = v }
    }
    if !traits.entries.isEmpty { o["traits"] = .object(traits) }
    for (k, v) in layers.entries where o[k] == nil { o[k] = v }
    return .object(o)
  }

  /// Envelope fields named in `layerKeys` come back as `layers`; `traits` (an object) is
  /// spread into `extra`; every other non-core field is a compose override, as before (no
  /// compose param uses a layer name). Payloads written before traits moved under `traits`
  /// (sessions recorded with top-level traits) therefore read back unchanged.
  init?(payload p: JSONValue) {
    guard let genre = p["genre"]?.string, let seed = p["seed"]?.double else { return nil }
    var extra = JSONObject()
    var layers = JSONObject()
    for (k, v) in p.object?.entries ?? []
    where !["genre", "seed", "structure", "cohesion"].contains(k) {
      if k == "traits", case .object(let traits) = v {
        for (tk, tv) in traits.entries { extra[tk] = tv }
      } else if Self.layerKeys.contains(k) {
        layers[k] = v
      } else {
        extra[k] = v
      }
    }
    self.init(
      genre: genre, seed: seed, structure: p["structure"]?.string,
      cohesion: p["cohesion"]?.string ?? "v2", extra: extra, layers: layers)
  }
}

extension DeckSourceDescriptor {
  var json: JSONValue {
    switch self {
    case .none: return .object(JSONObject([("kind", .string("none"))]))
    case .net(let spec):
      return .object(
        JSONObject([
          ("kind", .string("net")), ("share", spec.payload),
          ("cid", .string(BeatsCID.shareCID(spec.payload))),
        ]))
    case .rawNets(let payload):
      return .object(
        JSONObject([
          ("kind", .string("rawNets")), ("share", payload),
          ("cid", .string(BeatsCID.shareCID(payload))),
        ]))
    case .sample(let id, let title, let grid):
      var o = JSONObject([
        ("kind", .string("sample")), ("id", .string(id)), ("title", .string(title)),
      ])
      if let grid {
        o["grid"] = .object(
          JSONObject([("bpm", .number(grid.bpm)), ("offset", .number(grid.offset))]))
      }
      return .object(o)
    }
  }

  init?(json v: JSONValue) {
    switch v["kind"]?.string {
    case "none": self = .none
    case "net":
      guard let p = v["share"], let spec = TrackSpec(payload: p) else { return nil }
      self = .net(spec)
    case "rawNets":
      guard let p = v["share"], Share(payload: p).nets != nil else { return nil }
      self = .rawNets(payload: p)
    case "sample":
      guard let id = v["id"]?.string else { return nil }
      var grid: BeatGrid?
      if let g = v["grid"], let bpm = g["bpm"]?.double {
        grid = BeatGrid(bpm: bpm, offset: g["offset"]?.double ?? 0, confidence: 1)
      }
      self = .sample(id: id, title: v["title"]?.string ?? "", grid: grid)
    default: return nil
    }
  }
}

extension DeckParams {
  var json: JSONValue {
    var o = JSONObject([
      ("volume", .number(volume)), ("gain", .number(gain)), ("filter", .number(filter)),
      ("eqLow", .number(eqLow)), ("eqMid", .number(eqMid)), ("eqHigh", .number(eqHigh)),
      ("pitch", .number(pitch)), ("quantize", .string(quantize)),
      ("autoAdvance", .bool(autoAdvance)),
    ])
    // only when touched, so sets from before the reverb keep their canonical text and CID
    if reverbWet != 0 || reverbSize != 0.5 || reverbTone != 0.5 {
      o["reverbWet"] = .number(reverbWet)
      o["reverbSize"] = .number(reverbSize)
      o["reverbTone"] = .number(reverbTone)
    }
    return .object(o)
  }

  init(json v: JSONValue) {
    self.init()
    volume = v["volume"]?.double ?? volume
    gain = v["gain"]?.double ?? gain
    filter = v["filter"]?.double ?? filter
    eqLow = v["eqLow"]?.double ?? eqLow
    eqMid = v["eqMid"]?.double ?? eqMid
    eqHigh = v["eqHigh"]?.double ?? eqHigh
    pitch = v["pitch"]?.double ?? pitch
    quantize = v["quantize"]?.string ?? quantize
    autoAdvance = v["autoAdvance"]?.bool ?? autoAdvance
    reverbWet = v["reverbWet"]?.double ?? reverbWet
    reverbSize = v["reverbSize"]?.double ?? reverbSize
    reverbTone = v["reverbTone"]?.double ?? reverbTone
  }
}

extension DeckAction {
  public var json: JSONValue {
    func o(_ op: String, _ rest: [(String, JSONValue)]) -> JSONValue {
      .object(JSONObject([("op", .string(op))] + rest))
    }
    func d(_ s: String) -> (String, JSONValue) { ("deck", .string(s)) }
    switch self {
    case .play(let deck, let on): return o("play", [d(deck), ("on", .bool(on))])
    case .cue(let deck): return o("cue", [d(deck)])
    case .hotCue(let deck, let slot): return o("hotCue", [d(deck), ("slot", .int(slot))])
    case .clearCue(let deck, let slot): return o("clearCue", [d(deck), ("slot", .int(slot))])
    case .loop(let deck, let op): return o("loop", [d(deck), ("loop", .string(op))])
    case .param(let deck, let name, let value):
      return o("param", [d(deck), ("name", .string(name)), ("value", .number(value))])
    case .crossfader(let v): return o("crossfader", [("value", .number(v))])
    case .master(let v): return o("master", [("value", .number(v))])
    case .load(let deck, let source): return o("load", [d(deck), ("source", source.json)])
    case .queueNext(let deck, let spec): return o("queueNext", [d(deck), ("share", spec.payload)])
    case .nextTrack(let deck): return o("nextTrack", [d(deck)])
    case .autoAdvance(let deck, let on): return o("autoAdvance", [d(deck), ("on", .bool(on))])
    case .section(let deck, let i): return o("section", [d(deck), ("index", .int(i))])
    case .role(let deck, let role, let on):
      return o("role", [d(deck), ("role", .string(role)), ("on", .bool(on))])
    case .macro(let deck, let id): return o("macro", [d(deck), ("macro", .string(id))])
    case .panic(let deck): return o("panic", [d(deck)])
    case .stinger(let deck, let n): return o("stinger", [d(deck), ("n", .int(n))])
    case .sync(let deck, let align): return o("sync", [d(deck), ("align", .string(align))])
    case .quantize(let deck, let mode): return o("quantize", [d(deck), ("mode", .string(mode))])
    case .follow(let deck, let leader):
      return o("follow", [d(deck), ("leader", leader.map { .string($0) } ?? .null)])
    case .grid(let deck, let bpm, let offset):
      return o("grid", [d(deck), ("bpm", .number(bpm)), ("offset", .number(offset))])
    case .loopRecord(let deck, let on): return o("loopRecord", [d(deck), ("on", .bool(on))])
    case .clip(let deck, let id): return o("clip", [d(deck), ("id", .string(id))])
    case .clipLoop(let id, let on): return o("clipLoop", [("id", .string(id)), ("on", .bool(on))])
    case .clipGain(let id, let v):
      return o("clipGain", [("id", .string(id)), ("value", .number(v))])
    case .clipCrop(let id, let from, let to):
      return o("clipCrop", [("id", .string(id)), ("from", .int(from)), ("to", .int(to))])
    case .clipSequence(let steps, let replacing):
      return o(
        "clipSequence",
        [
          ("steps", steps.json),
          ("replacing", replacing.map { .string($0) } ?? .null),
        ])
    case .loopQuantize(let beats): return o("loopQuantize", [("beats", .int(beats))])
    case .sceneSave(let name): return o("sceneSave", [("name", .string(name))])
    case .sceneLaunch(let name, let clips):
      return o("sceneLaunch", [("name", .string(name)), ("clips", clips?.json ?? .null)])
    case .sceneRename(let name, let to):
      return o("sceneRename", [("name", .string(name)), ("to", .string(to))])
    case .sceneDelete(let name): return o("sceneDelete", [("name", .string(name))])
    }
  }

  public init?(json v: JSONValue) {
    guard let op = v["op"]?.string else { return nil }
    let deck = v["deck"]?.string ?? ""
    switch op {
    case "play": self = .play(deck: deck, on: v["on"]?.bool ?? false)
    case "cue": self = .cue(deck: deck)
    case "hotCue": self = .hotCue(deck: deck, slot: v["slot"]?.int ?? 0)
    case "clearCue": self = .clearCue(deck: deck, slot: v["slot"]?.int ?? 0)
    case "loop": self = .loop(deck: deck, op: v["loop"]?.string ?? "")
    case "param":
      self = .param(deck: deck, name: v["name"]?.string ?? "", value: v["value"]?.double ?? 0)
    case "crossfader": self = .crossfader(v["value"]?.double ?? 0.5)
    case "master": self = .master(v["value"]?.double ?? 0.8)
    case "load":
      guard let s = v["source"].flatMap(DeckSourceDescriptor.init(json:)) else { return nil }
      self = .load(deck: deck, source: s)
    case "queueNext":
      guard let s = v["share"].flatMap(TrackSpec.init(payload:)) else { return nil }
      self = .queueNext(deck: deck, spec: s)
    case "nextTrack": self = .nextTrack(deck: deck)
    case "autoAdvance": self = .autoAdvance(deck: deck, on: v["on"]?.bool ?? false)
    case "section": self = .section(deck: deck, index: v["index"]?.int ?? 0)
    case "role": self = .role(deck: deck, role: v["role"]?.string ?? "", on: v["on"]?.bool ?? true)
    case "macro": self = .macro(deck: deck, id: v["macro"]?.string ?? "")
    case "panic": self = .panic(deck: deck)
    case "stinger": self = .stinger(deck: deck, n: v["n"]?.int ?? 0)
    case "sync": self = .sync(deck: deck, align: v["align"]?.string ?? "beat")
    case "quantize": self = .quantize(deck: deck, mode: v["mode"]?.string ?? "off")
    case "follow": self = .follow(deck: deck, leader: v["leader"]?.string)
    case "grid":
      self = .grid(deck: deck, bpm: v["bpm"]?.double ?? 120, offset: v["offset"]?.double ?? 0)
    case "loopRecord": self = .loopRecord(deck: deck, on: v["on"]?.bool ?? false)
    case "clip": self = .clip(deck: deck, id: v["id"]?.string ?? "")
    case "clipLoop": self = .clipLoop(id: v["id"]?.string ?? "", on: v["on"]?.bool ?? false)
    case "clipGain": self = .clipGain(id: v["id"]?.string ?? "", value: v["value"]?.double ?? 1)
    case "clipSequence":
      self = .clipSequence(
        steps: [SequenceStep](json: v["steps"]), replacing: v["replacing"]?.string)
    case "clipCrop":
      self = .clipCrop(id: v["id"]?.string ?? "", from: v["from"]?.int ?? 0, to: v["to"]?.int ?? 0)
    case "loopQuantize": self = .loopQuantize(beats: v["beats"]?.int ?? DJEngine.defaultLoopQuantum)
    case "sceneSave": self = .sceneSave(name: v["name"]?.string ?? "")
    case "sceneLaunch":
      self = .sceneLaunch(
        name: v["name"]?.string ?? "", clips: v["clips"]?.array.map { [SceneClip](json: .array($0)) })
    case "sceneRename":
      self = .sceneRename(name: v["name"]?.string ?? "", to: v["to"]?.string ?? "")
    case "sceneDelete": self = .sceneDelete(name: v["name"]?.string ?? "")
    default: return nil
    }
  }
}

extension SessionEvent {
  var json: JSONValue {
    switch kind {
    case .midi(let port, let bytes):
      return .object(
        JSONObject([
          ("f", .int(frame)), ("k", .string("midi")), ("p", .string(port)),
          ("b", .array(bytes.map { .int(Int($0)) })),
        ]))
    case .action(let a):
      return .object(JSONObject([("f", .int(frame)), ("k", .string("act")), ("a", a.json)]))
    }
  }

  init?(json v: JSONValue) {
    guard let f = v["f"]?.int else { return nil }
    switch v["k"]?.string {
    case "midi":
      guard let p = v["p"]?.string, let b = v["b"]?.ints else { return nil }
      self.init(frame: f, kind: .midi(port: p, bytes: b.map { UInt8(clamping: $0) }))
    case "act":
      guard let a = v["a"].flatMap(DeckAction.init(json:)) else { return nil }
      self.init(frame: f, kind: .action(a))
    default: return nil
    }
  }
}

extension Session {
  /// The envelope as JSON. Key order is irrelevant: the canonical form sorts keys.
  public var json: JSONValue {
    var decksObj = JSONObject()
    for name in decks.keys.sorted() {
      decksObj[name] = .object(
        JSONObject([
          ("source", decks[name]!.json), ("params", (params[name] ?? DeckParams()).json),
        ]))
    }
    return .object(
      JSONObject([
        ("schema", .string(Self.schema)), ("sampleRate", .number(sampleRate)),
        ("frames", .int(frames)), ("decks", .object(decksObj)),
        (
          "mixer",
          .object(JSONObject([("crossfader", .number(crossfader)), ("master", .number(master))]))
        ),
        ("events", .array(events.map(\.json))),
      ]))
  }

  /// `canonicalizeJSON` of the envelope — the bytes the CID hashes.
  public var canonical: String { json.canonicalJS }

  /// CIDv1 (dag-json, sha2-256, base58btc), the same function beats names a share with.
  public var cid: String { BeatsCID.shareCID(canonical: canonical) }

  public init(json v: JSONValue) throws {
    guard v["schema"]?.string == Self.schema, let sr = v["sampleRate"]?.double,
      let frames = v["frames"]?.int, let decksObj = v["decks"]?.object
    else { throw SessionError.badSchema }
    var decks: [String: DeckSourceDescriptor] = [:]
    var params: [String: DeckParams] = [:]
    for (name, d) in decksObj.entries {
      guard let s = d["source"].flatMap(DeckSourceDescriptor.init(json:)) else {
        throw SessionError.badSchema
      }
      decks[name] = s
      params[name] = d["params"].map(DeckParams.init(json:)) ?? DeckParams()
    }
    var events: [SessionEvent] = []
    for e in v["events"]?.array ?? [] {
      guard let ev = SessionEvent(json: e) else { throw SessionError.badSchema }
      events.append(ev)
    }
    self.init(
      sampleRate: sr, frames: frames, decks: decks, params: params,
      crossfader: v["mixer"]?["crossfader"]?.double ?? 0.5,
      master: v["mixer"]?["master"]?.double ?? 0.8, events: events)
  }

  /// Parse envelope text; with `cid`, the content must hash to it.
  public static func decode(_ text: String, cid: String? = nil) throws -> Session {
    let v = try JSONValue.parse(text)
    if let cid, BeatsCID.shareCID(v) != cid { throw SessionError.cidMismatch }
    return try Session(json: v)
  }
}

extension [SequenceStep] {
  var json: JSONValue {
    .array(
      map {
        .object(JSONObject([("clip", .string($0.clipID)), ("repeats", .int($0.repeats))]))
      })
  }

  init(json v: JSONValue?) {
    self = (v?.array ?? []).compactMap { e in
      e["clip"]?.string.map { SequenceStep(clipID: $0, repeats: e["repeats"]?.int ?? 1) }
    }
  }
}
