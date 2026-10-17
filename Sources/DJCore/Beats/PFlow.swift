import Foundation

// Port of beats' public/lib/pflow.js (parse, projectToJSON, durations, model CID).
// Cross-checked against go-pflow semantics via the JS's own notes: internal/pflow/cid.go
// is what normalizeProjectForCID mirrors, and tools/parity diffs the two live.
//
// Deliberately not ported here:
//  - recomputeLayout: it only fills x/y when a document has no coordinates, and x/y
//    never reach projectToJSON or the CID. Coordinates that are present are kept.
//  - the runtime half of NetBundle (arc index, isEnabled, fire): that is the wave
//    engine (ROADMAP 2.6 / 3.1).
//
// Known JS↔Go gap, mirrored from JS: sorts here are UTF-16 code-unit order (JS
// `<`), Go sorts bytes. They agree except when astral and U+E000–U+FFFF characters
// are compared; no genre produces such ids.

// MARK: - JS helpers

/// `Math.round`: ties toward +∞.
public func jsRound(_ d: Double) -> Double {
  guard d.isFinite else { return d }
  let f = d.rounded(.down)
  return d - f >= 0.5 ? f + 1 : f
}

private func jsRoundInt(_ d: Double) -> Int {
  let r = jsRound(d)
  guard r.isFinite else { return 0 }
  return Int(max(min(r, 9e18), -9e18))
}

/// JS `a < b` on strings (UTF-16 code units).
public func jsStringLess(_ a: String, _ b: String) -> Bool {
  a.utf16.lexicographicallyPrecedes(b.utf16)
}

extension JSONValue {
  /// JS truthiness.
  public var isTruthy: Bool {
    switch self {
    case .null: false
    case .bool(let b): b
    case .number(let d): d != 0 && !d.isNaN
    case .string(let s): !s.isEmpty
    case .array, .object: true
    }
  }
  fileprivate var isObjectLike: Bool {
    switch self {
    case .array, .object: true
    default: false
    }
  }
}

/// A string-keyed map that iterates the way a JS object does (integer keys first).
public struct OrderedMap<Value> {
  public private(set) var keys: [String] = []
  private var storage: [String: Value] = [:]

  public init() {}

  public subscript(key: String) -> Value? {
    get { storage[key] }
    set {
      if let newValue {
        if storage.updateValue(newValue, forKey: key) == nil {
          keys.append(key)
          if JSONObject.arrayIndex(key) != nil {
            let ints = keys.filter { JSONObject.arrayIndex($0) != nil }
              .sorted { JSONObject.arrayIndex($0)! < JSONObject.arrayIndex($1)! }
            keys = ints + keys.filter { JSONObject.arrayIndex($0) == nil }
          }
        }
      } else if storage.removeValue(forKey: key) != nil {
        keys.removeAll { $0 == key }
      }
    }
  }

  public var count: Int { keys.count }
  public var pairs: [(key: String, value: Value)] { keys.map { ($0, storage[$0]!) } }
  public var values: [Value] { keys.map { storage[$0]! } }
}

// MARK: - Model

public struct Place {
  public var initial: [Double] = [0]
  public var x = 0.0
  public var y = 0.0
  public var label: String?
}

public struct Transition {
  public var x = 0.0
  public var y = 0.0
  public var label: String?
}

public struct Arc {
  public var source: String
  public var target: String
  public var weight: [Double]
  public var inhibit: Bool
}

public struct MidiBinding: Equatable {
  public var note: Int
  public var channel: Int
  public var velocity: Int
  public var duration: Int  // legacy milliseconds
  public var durationSteps: Int  // sixteenth steps; canonical when > 0
}

public struct ControlBinding {
  public var action: String
  public var targetNet: String
  public var targetNote: Int
  public var macro: String?
  public var macroBars: Double?
  public var macroParams: JSONValue?
}

public struct Track {
  public var channel = 1
  public var defaultVelocity = 100
  public var instrument = ""
  /// The instrument was chosen by the user (a share `tracks` override), not the composer: its
  /// sampled sound is picked by the name (`VoiceCatalog.sources(picked:)`). dj-only, never
  /// encoded: the project's canonical text and CID are beats'.
  public var picked = false
  /// The drum kit this net's drum lanes play (`DrumKits`, a share `tracks` override's `kit`),
  /// nil = beats' synth kit. dj-only, never encoded, like `picked`.
  public var kit: String?
  /// The sound palette this net's role plays from (`SoundPalette`, a `tracks` override's
  /// `palette`), nil = its instrument's category. dj-only, never encoded.
  public var palette: String?
  /// What the palette (or the user's role override) resolved this net to play
  /// (`Project.applySound`). dj-only, never encoded.
  public var sound = TrackSound()
  public var instrumentSet: [JSONValue] = []
  public var mix: JSONValue?
  public var group: String?
  public var generator: String?
  public var ringSize: Double?
  public var beats: Double?
  public var rotation: Double?
  public var note: Double?
  public var generatorParams: JSONValue?

  public init(
    channel: Int = 1, defaultVelocity: Int = 100, instrument: String = "",
    instrumentSet: [JSONValue] = [], mix: JSONValue? = nil, group: String? = nil,
    generator: String? = nil, ringSize: Double? = nil, beats: Double? = nil,
    rotation: Double? = nil, note: Double? = nil, generatorParams: JSONValue? = nil
  ) {
    self.channel = channel
    self.defaultVelocity = defaultVelocity
    self.instrument = instrument
    self.instrumentSet = instrumentSet
    self.mix = mix
    self.group = group
    self.generator = generator
    self.ringSize = ringSize
    self.beats = beats
    self.rotation = rotation
    self.note = note
    self.generatorParams = generatorParams
  }
}

public struct NetBundle {
  public var places = OrderedMap<Place>()
  public var transitions = OrderedMap<Transition>()
  public var arcs: [Arc] = []
  public var track = Track()
  public var role = "music"
  public var riffGroup = ""
  public var riffVariant = ""
  public var bindings = OrderedMap<MidiBinding>()
  public var controlBindings = OrderedMap<ControlBinding>()
  /// For a net that came from an unparsed wire document (`Project.init(wireJSON:)`): the raw
  /// ms `stampDurationSteps` stamps from, per binding — only bindings whose JSON carried a
  /// finite positive `duration` and no positive `durationSteps`, as the JS stamp on raw nets.
  /// nil for parsed nets. Not part of the model.
  var wireDurationMs: [String: Double]?
}

public struct Section {
  public var name: String
  public var steps: Int
  public var phrases = OrderedMap<[String]>()
}

public struct Project {
  public var name = "Untitled"
  public var tempo = 120.0
  public var swing = 0.0
  public var humanize = 0.0
  public var rootNote: Int?
  public var scaleName = ""
  public var bars: Int?
  public var nets = OrderedMap<NetBundle>()
  public var structure: [Section] = []
  public var initialMutes: [String] = []
  /// Set by the composer when the cohesion-v2 engine ran; not part of the model CID.
  public var cohesion: String?
}

// MARK: - Parsing

private func getString(_ m: JSONValue?, _ key: String, _ def: String) -> String {
  m?[key]?.string ?? def
}
private func getFloat(_ m: JSONValue?, _ key: String, _ def: Double) -> Double {
  m?[key]?.double ?? def
}
private func getInt(_ m: JSONValue?, _ key: String, _ def: Int) -> Int {
  if let d = m?[key]?.double { return jsRoundInt(d) }
  return def
}
private func getFloatArray(_ m: JSONValue?, _ key: String, _ def: [Double]) -> [Double] {
  guard let arr = m?[key]?.array else { return def }
  return arr.map { $0.double ?? 0 }
}

extension NetBundle {
  /// `parseNetBundle`
  public init(json data: JSONValue) {
    self.init()
    role = getString(data, "role", "music")
    riffGroup = getString(data, "riffGroup", "")
    riffVariant = getString(data, "riffVariant", "")

    let t = data["track"]
    track.channel = getInt(t, "channel", 1)
    track.defaultVelocity = getInt(t, "defaultVelocity", 100)
    track.instrument = getString(t, "instrument", "")
    track.instrumentSet = t?["instrumentSet"]?.array ?? []
    if let mix = t?["mix"], mix.isTruthy { track.mix = mix }
    if let g = t?["group"]?.string, !g.isEmpty { track.group = g }
    if let g = t?["generator"]?.string { track.generator = g }
    track.ringSize = t?["ringSize"]?.double
    track.beats = t?["beats"]?.double
    track.rotation = t?["rotation"]?.double
    track.note = t?["note"]?.double
    if let gp = t?["generatorParams"], gp.isObjectLike { track.generatorParams = gp }

    if let places = data["places"]?.object {
      for (id, p) in places.entries {
        var place = Place()
        place.initial = getFloatArray(p, "initial", [0])
        place.x = getFloat(p, "x", 0)
        place.y = getFloat(p, "y", 0)
        if let l = p["label"]?.string, !l.isEmpty { place.label = l }
        self.places[id] = place
      }
    }

    if let transitions = data["transitions"]?.object {
      for (id, td) in transitions.entries {
        var tr = Transition()
        tr.x = getFloat(td, "x", 0)
        tr.y = getFloat(td, "y", 0)
        if let l = td["label"]?.string, !l.isEmpty { tr.label = l }
        self.transitions[id] = tr

        if let m = td["midi"], m.isObjectLike {
          bindings[id] = midi(m)
        }
        if let c = td["control"], c.isObjectLike {
          var cb = ControlBinding(
            action: getString(c, "action", "toggle-track"),
            targetNet: getString(c, "targetNet", ""),
            targetNote: getInt(c, "targetNote", 0))
          let macro = getString(c, "macro", "")
          if !macro.isEmpty { cb.macro = macro }
          let bars = getFloat(c, "macroBars", 0)
          if bars != 0 { cb.macroBars = bars }
          if let mp = c["macroParams"], mp.isObjectLike { cb.macroParams = mp }
          controlBindings[id] = cb
        }
      }
    }

    for a in data["arcs"]?.array ?? [] {
      arcs.append(
        Arc(
          source: getString(a, "source", ""), target: getString(a, "target", ""),
          weight: getFloatArray(a, "weight", [1]),
          inhibit: { if case .bool(let b)? = a["inhibit"] { b } else { false } }()))
    }

    // Re-parse fallback: a previously parsed bundle carries bindings as siblings.
    if let b = data["bindings"]?.object {
      for (id, m) in b.entries where bindings[id] == nil && m.isTruthy && m.isObjectLike {
        bindings[id] = midi(m)
      }
    }
    if let cbs = data["controlBindings"]?.object {
      for (id, c) in cbs.entries where controlBindings[id] == nil && c.isTruthy && c.isObjectLike {
        var cb = ControlBinding(
          action: getString(c, "action", "toggle-track"),
          targetNet: getString(c, "targetNet", ""),
          targetNote: getInt(c, "targetNote", 0))
        if c["macro"]?.isTruthy == true { cb.macro = getString(c, "macro", "") }
        if c["macroBars"]?.isTruthy == true { cb.macroBars = getFloat(c, "macroBars", 0) }
        if let mp = c["macroParams"], mp.isObjectLike { cb.macroParams = mp }
        controlBindings[id] = cb
      }
    }
  }

  private func midi(_ m: JSONValue) -> MidiBinding {
    MidiBinding(
      note: getInt(m, "note", 60),
      channel: getInt(m, "channel", track.channel),
      velocity: getInt(m, "velocity", track.defaultVelocity),
      duration: getInt(m, "duration", 100),
      durationSteps: getInt(m, "durationSteps", 0))
  }
}

extension Project {
  /// `parseProject`
  public init(json data: JSONValue) {
    self.init()
    name = getString(data, "name", "Untitled")
    tempo = getFloat(data, "tempo", 120)
    swing = getFloat(data, "swing", 0)
    humanize = getFloat(data, "humanize", 0)
    if let r = data["rootNote"], r != .null {
      let v = jsRoundInt(getFloat(data, "rootNote", -1))
      rootNote = v < 0 ? nil : v
    }
    scaleName = getString(data, "scaleName", "")
    if let b = data["bars"], b != .null {
      bars = max(0, jsRoundInt(getFloat(data, "bars", 0)))
    }

    if let nets = data["nets"]?.object {
      for (id, n) in nets.entries where n.isObjectLike {
        self.nets[id] = NetBundle(json: n)
      }
    }

    for s in data["structure"]?.array ?? [] {
      guard s.isObjectLike, s.object != nil else { continue }
      var sec = Section(
        name: getString(s, "name", ""), steps: jsRoundInt(getFloat(s, "steps", 0)))
      if let ph = s["phrases"]?.object {
        for (role, arr) in ph.entries {
          if let a = arr.array { sec.phrases[role] = a.compactMap(\.string) }
        }
      }
      structure.append(sec)
    }

    initialMutes = data["initialMutes"]?.array?.compactMap(\.string) ?? []
  }
}

// MARK: - Serialization (projectToJSON)

extension Project {
  /// `projectToJSON` — key order and omission rules follow the JS exactly.
  public func toJSON() -> JSONValue {
    var r = JSONObject()
    r["name"] = .string(name)
    r["tempo"] = .number(tempo)
    var netsObj = JSONObject()
    r["nets"] = .object(netsObj)  // position fixed; filled below
    if swing > 0 { r["swing"] = .number(swing) }
    if humanize > 0 { r["humanize"] = .number(humanize) }
    if let rootNote { r["rootNote"] = .int(rootNote) }
    if !scaleName.isEmpty { r["scaleName"] = .string(scaleName) }
    if let bars, bars > 0 { r["bars"] = .int(bars) }
    for (id, nb) in nets.pairs { netsObj[id] = nb.toJSON() }
    r["nets"] = .object(netsObj)
    if !initialMutes.isEmpty { r["initialMutes"] = .array(initialMutes.map { .string($0) }) }
    if !structure.isEmpty {
      r["structure"] = .array(
        structure.map { sec in
          var s = JSONObject()
          s["name"] = .string(sec.name)
          s["steps"] = .int(sec.steps)
          if sec.phrases.count > 0 {
            var ph = JSONObject()
            for (k, v) in sec.phrases.pairs { ph[k] = .array(v.map { .string($0) }) }
            s["phrases"] = .object(ph)
          }
          return .object(s)
        })
    }
    return .object(r)
  }
}

extension NetBundle {
  func toJSON() -> JSONValue {
    var tm = JSONObject()
    tm["channel"] = .int(track.channel)
    if track.defaultVelocity != 100 { tm["defaultVelocity"] = .int(track.defaultVelocity) }
    if !track.instrument.isEmpty { tm["instrument"] = .string(track.instrument) }
    if !track.instrumentSet.isEmpty { tm["instrumentSet"] = .array(track.instrumentSet) }
    if let mix = track.mix { tm["mix"] = mix }
    if let g = track.generator, !g.isEmpty { tm["generator"] = .string(g) }
    if let v = track.ringSize { tm["ringSize"] = .number(v) }
    if let v = track.beats { tm["beats"] = .number(v) }
    if let v = track.rotation, v != 0 { tm["rotation"] = .number(v) }
    if let v = track.note { tm["note"] = .number(v) }
    if let gp = track.generatorParams { tm["generatorParams"] = gp }
    if let g = track.group { tm["group"] = .string(g) }

    var r = JSONObject()
    r["track"] = .object(tm)
    if !role.isEmpty && role != "music" { r["role"] = .string(role) }
    if !riffGroup.isEmpty { r["riffGroup"] = .string(riffGroup) }
    if !riffVariant.isEmpty { r["riffVariant"] = .string(riffVariant) }

    var pl = JSONObject()
    for (label, place) in places.pairs {
      var p = JSONObject()
      if place.initial.reduce(0, +) > 0 { p["initial"] = .array(place.initial.map { .number($0) }) }
      if let l = place.label { p["label"] = .string(l) }
      pl[label] = .object(p)
    }
    r["places"] = .object(pl)

    var tr = JSONObject()
    for (label, trans) in transitions.pairs {
      var t = JSONObject()
      if let l = trans.label { t["label"] = .string(l) }
      if let m = bindings[label] {
        var midi = JSONObject()
        midi["note"] = .int(m.note)
        if m.channel != track.channel { midi["channel"] = .int(m.channel) }
        if m.velocity != track.defaultVelocity { midi["velocity"] = .int(m.velocity) }
        if m.durationSteps > 0 {
          midi["durationSteps"] = .int(m.durationSteps)
        } else if m.duration != 100 {
          midi["duration"] = .int(m.duration)
        }
        t["midi"] = .object(midi)
      }
      if let c = controlBindings[label] {
        var cm = JSONObject()
        cm["action"] = .string(c.action)
        if !c.targetNet.isEmpty { cm["targetNet"] = .string(c.targetNet) }
        if c.targetNote > 0 { cm["targetNote"] = .int(c.targetNote) }
        if let m = c.macro, !m.isEmpty { cm["macro"] = .string(m) }
        if let b = c.macroBars, b != 0 { cm["macroBars"] = .number(b) }
        if let mp = c.macroParams { cm["macroParams"] = mp }
        t["control"] = .object(cm)
      }
      _ = trans
      tr[label] = .object(t)
    }
    r["transitions"] = .object(tr)

    r["arcs"] = .array(
      arcs.map { arc in
        var a = JSONObject()
        a["source"] = .string(arc.source)
        a["target"] = .string(arc.target)
        if !(arc.weight.count == 1 && arc.weight[0] == 1) {
          a["weight"] = .array(arc.weight.map { .number($0) })
        }
        if arc.inhibit { a["inhibit"] = .bool(true) }
        return .object(a)
      })
    return .object(r)
  }
}

// MARK: - Model CID (normalizeProjectForCID / canonicalProjectJSON)

extension NetBundle {
  func normalizedForCID() -> JSONValue {
    var n = JSONObject()
    if !role.isEmpty && role != "music" { n["role"] = .string(role) }
    if !riffGroup.isEmpty { n["riffGroup"] = .string(riffGroup) }

    var pl = JSONObject()
    for id in places.keys.sorted(by: jsStringLess) {
      var p = JSONObject()
      p["initial"] = .array(places[id]!.initial.map { .number($0) })
      pl[id] = .object(p)
    }
    n["places"] = .object(pl)

    var tr = JSONObject()
    for id in transitions.keys.sorted(by: jsStringLess) {
      var t = JSONObject()
      if let m = bindings[id] {
        var midi = JSONObject()
        midi["note"] = .int(m.note)
        midi["velocity"] = .int(m.velocity)
        midi["channel"] = .int(m.channel)
        if m.durationSteps > 0 {
          midi["durationSteps"] = .int(m.durationSteps)
        } else {
          midi["duration"] = .int(m.duration)
        }
        t["midi"] = .object(midi)
      }
      if let c = controlBindings[id] {
        var ctrl = JSONObject()
        ctrl["action"] = .string(c.action)
        if !c.targetNet.isEmpty { ctrl["targetNet"] = .string(c.targetNet) }
        t["control"] = .object(ctrl)
      }
      tr[id] = .object(t)
    }
    n["transitions"] = .object(tr)

    // Stable sort by (source, target): equal keys keep document order.
    let sorted = arcs.enumerated().sorted { a, b in
      if a.element.source != b.element.source {
        return jsStringLess(a.element.source, b.element.source)
      }
      if a.element.target != b.element.target {
        return jsStringLess(a.element.target, b.element.target)
      }
      return a.offset < b.offset
    }.map(\.element)
    n["arcs"] = .array(
      sorted.map { arc in
        var a = JSONObject()
        a["source"] = .string(arc.source)
        a["target"] = .string(arc.target)
        a["weight"] = .array(arc.weight.map { .number($0) })
        if arc.inhibit { a["inhibit"] = .bool(true) }
        return .object(a)
      })
    return .object(n)
  }
}

extension Project {
  public func normalizedForCID() -> JSONValue {
    var r = JSONObject()
    r["name"] = .string(name)
    r["tempo"] = .number(tempo)
    if swing > 0 { r["swing"] = .number(swing) }
    if humanize > 0 { r["humanize"] = .number(humanize) }
    var n = JSONObject()
    for id in nets.keys.sorted(by: jsStringLess) { n[id] = nets[id]!.normalizedForCID() }
    r["nets"] = .object(n)
    return .object(r)
  }

  /// `canonicalProjectJSON`: the exact bytes the model CID hashes.
  public var canonicalJSON: String { normalizedForCID().canonicalGo }

  /// Hex sha256 of `canonicalJSON` (internal/pflow/cid.go `Project.CID`).
  public var modelCID: String { BeatsCID.modelCID(canonicalProject: canonicalJSON) }
}

// MARK: - Beat-relative durations (internal/pflow/duration.go)

/// `durationStepsFromMs`
public func durationStepsFromMs(_ ms: Double, bpm: Double) -> Int {
  guard ms > 0, bpm > 0 else { return 0 }
  let steps = jsRound(ms * bpm * 4 / 60000)
  return steps < 1 ? 1 : Int(steps)
}

/// `resolveDurationMs` for a binding's raw fields (nil = absent / not finite).
public func resolveDurationMs(durationSteps: Double?, duration: Double?, bpm: Double) -> Double {
  if let s = durationSteps, s > 0, bpm > 0 { return jsRound(s * 60000 / (bpm * 4)) }
  if let d = duration, d.isFinite { return d }
  return 100
}

extension MidiBinding {
  public func resolvedDurationMs(bpm: Double) -> Double {
    resolveDurationMs(durationSteps: Double(durationSteps), duration: Double(duration), bpm: bpm)
  }
}

extension Project {
  /// `stampDurationSteps`: idempotent; stamps at the authored tempo.
  public mutating func stampDurationSteps() {
    let bpm = tempo > 0 ? tempo : 120
    for id in nets.keys {
      for bid in nets[id]!.bindings.keys {
        var m = nets[id]!.bindings[bid]!
        if m.durationSteps > 0 { continue }
        if let wire = nets[id]!.wireDurationMs {
          guard let ms = wire[bid] else { continue }
          m.durationSteps = durationStepsFromMs(ms, bpm: bpm)
        } else {
          if m.duration <= 0 { continue }
          m.durationSteps = durationStepsFromMs(Double(m.duration), bpm: bpm)
        }
        nets[id]!.bindings[bid] = m
      }
    }
  }
}
