import Foundation

// A piano roll → a raw-`nets` share envelope (`dj_compose`). The caller (an LLM, a script) writes
// the notes; this turns each part into a step-sequencer net the deck plays as given:
// a ring of N sixteenth-step places, one token, and the transition leaving place i carries the
// MIDI binding of the note that starts on step i (no binding = a rest). Rings of one song share
// the same length, so the parts stay in phase. The envelope then goes the way `loadShare` takes
// any raw-nets share (`ShareSource`), so it records, replays and gets a CID like one.
//
// Not part of `compose()` (beats' coordinate system stays byte-identical): the notes are the
// configuration, and a raw-nets deck gets no musicality pass.

public enum PianoRollError: Error, Equatable, CustomStringConvertible {
  case bad(String)
  public var description: String {
    switch self {
    case .bad(let m): return m
    }
  }
}

public enum PianoRoll {
  /// A role's defaults: net id = role, its channel (beats' own), instrument, and the GM note a
  /// drum part plays when a note leaves `note` out.
  struct RoleDefaults {
    var channel: Int
    var instrument: String
    var drumNote: Int?
  }

  static let roles: [String: RoleDefaults] = [
    "kick": .init(channel: 10, instrument: "drums", drumNote: 36),
    "snare": .init(channel: 11, instrument: "drums", drumNote: 38),
    "hihat": .init(channel: 12, instrument: "drums", drumNote: 42),
    "clap": .init(channel: 13, instrument: "drums", drumNote: 39),
    "bass": .init(channel: 6, instrument: "sub-bass", drumNote: nil),
    "melody": .init(channel: 4, instrument: "square-lead", drumNote: nil),
    "harmony": .init(channel: 7, instrument: "warm-pad", drumNote: nil),
    "arp": .init(channel: 5, instrument: "electric-piano", drumNote: nil),
  ]

  public static let maxSteps = 1024

  struct Note {
    var step: Int
    var note: Int
    var duration: Int
    var velocity: Int
  }

  /// `params`: `{name?, tempo?, swing?, steps?, inspiredBy?, brief?, layers?, parts: {role: {instrument?, channel?, notes}}}`.
  /// A note is `[step, note, dur?, vel?]` or `{step, note?, dur?, vel?}` (steps count sixteenths
  /// from 0; `dur` in sixteenths; drum parts may leave `note` out). Returns the envelope.
  public static func envelope(_ params: JSONValue) throws -> JSONValue {
    guard let parts = params["parts"]?.object, !parts.entries.isEmpty else {
      throw PianoRollError.bad(
        "`parts` is required: {role: {instrument?, notes: [[step, note, dur?, vel?], …]}}, "
          + "roles kick snare hihat clap bass melody harmony arp")
    }
    // A part is one segment or an array of them: {from?, every?, until?, notes}. Without `every`
    // the notes sit at `from` + their step; with it the pattern repeats every `every` steps from
    // `from` up to `until` (default: the roll's end), so a bar of drums is written once.
    struct Segment {
      var notes: [Note]
      var from: Int
      var every: Int?
      var until: Int?
    }
    func int(_ v: JSONValue?) -> Int? { v?.double.map { Int($0.rounded()) } }
    var parsed: [(id: String, defaults: RoleDefaults, instrument: String, segments: [Segment])] = []
    for (id, part) in parts.entries {
      let d =
        roles[id] ?? RoleDefaults(channel: 1, instrument: "piano", drumNote: nil)
      let list = part.array ?? [part]
      guard !list.isEmpty else { throw PianoRollError.bad("part `\(id)` is an empty list") }
      var segments: [Segment] = []
      var d2 = d
      var instrument = d.instrument
      for (k, seg) in list.enumerated() {
        let from = int(seg["from"]) ?? 0
        let every = int(seg["every"])
        guard from >= 0, every == nil || every! >= 1 else {
          throw PianoRollError.bad("part `\(id)`: `from` must be ≥ 0 and `every` ≥ 1 step")
        }
        segments.append(
          Segment(
            notes: try self.notes(of: seg, in: id, drumNote: d.drumNote), from: from,
            every: every, until: int(seg["until"])))
        if k == 0 || seg["instrument"] != nil, let i = seg["instrument"]?.string { instrument = i }
        if let ch = int(seg["channel"]) { d2.channel = min(16, max(1, ch)) }
      }
      parsed.append((id, d2, instrument, segments))
    }

    let explicit = int(params["steps"])
    if let explicit, !(1...maxSteps).contains(explicit) {
      throw PianoRollError.bad("`steps` must be 1…\(maxSteps) (sixteenths; 16 = one bar)")
    }
    var longest = 0
    for p in parsed {
      for seg in p.segments {
        if seg.every != nil {
          guard let end = seg.until ?? explicit else {
            throw PianoRollError.bad(
              "part `\(p.id)`: a repeating pattern (`every`) needs `until` or the roll's `steps`")
          }
          longest = max(longest, end)
        } else {
          longest = max(longest, seg.from + (seg.notes.map { $0.step + $0.duration }.max() ?? 0))
        }
      }
    }
    let steps = explicit ?? (longest <= 0 ? 16 : (longest + 15) / 16 * 16)
    guard steps <= maxSteps else {
      throw PianoRollError.bad("the roll is \(steps) steps; the most is \(maxSteps) (64 bars)")
    }
    // expand the segments into one note list per part
    var expanded: [(id: String, defaults: RoleDefaults, instrument: String, notes: [Note])] = []
    for p in parsed {
      var notes: [Note] = []
      for seg in p.segments {
        if let every = seg.every {  // a pattern repeated from `from` up to `until`
          let bound = min(steps, seg.until ?? steps)
          var offset = seg.from
          while offset < bound {
            for n in seg.notes where offset + n.step < bound {
              var m = n
              m.step = offset + n.step
              m.duration = min(n.duration, steps - m.step)
              notes.append(m)
            }
            offset += every
          }
        } else {
          for n in seg.notes {
            let at = seg.from + n.step
            guard at < steps else {
              throw PianoRollError.bad("a note starts on step \(at), past `steps` \(steps)")
            }
            var m = n
            m.step = at
            m.duration = min(n.duration, steps - at)
            notes.append(m)
          }
        }
      }
      expanded.append((p.id, p.defaults, p.instrument, notes))
    }
    let parsedNotes = expanded

    var nets = JSONObject()
    for p in parsedNotes {
      // One note starts per step per net: chord tones (notes on the same step) spill into
      // sibling nets (`melody-b`, …) grouped under the same role, played together.
      var lanes: [[Int: Note]] = []
      for n in p.notes.sorted(by: { ($0.step, $0.note) < ($1.step, $1.note) }) {
        if let i = lanes.firstIndex(where: { $0[n.step] == nil }) {
          lanes[i][n.step] = n
        } else {
          lanes.append([n.step: n])
        }
      }
      if lanes.isEmpty { lanes = [[:]] }
      for (i, lane) in lanes.enumerated() {
        let id = i == 0 ? p.id : "\(p.id)-\(Character(UnicodeScalar(97 + min(i, 25))!))"
        nets[id] = ring(
          steps: steps, lane: lane, channel: p.defaults.channel, instrument: p.instrument,
          group: i == 0 ? nil : (p.id, id))
      }
    }

    var env = JSONObject()
    // `dj_inspired`: an original piece in an artist's general style. The share says so, so the
    // provenance travels with the notes (a style read, never a transcription).
    let inspiredBy = params["inspiredBy"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    env["name"] = .string(
      params["name"]?.string ?? inspiredBy.map { "\($0)-style (original)" } ?? "Piano roll")
    if let inspiredBy {
      var note = "Original piece inspired by \(inspiredBy): style only, no melody or lyric taken."
      if let brief = params["brief"]?.string, !brief.isEmpty { note += " Brief: \(brief)" }
      env["note"] = .string(note)
    }
    if let t = params["tempo"]?.double {
      guard t >= 40 && t <= 300 else { throw PianoRollError.bad("`tempo` must be 40…300 BPM") }
      env["tempo"] = .number(t)
    }
    if let s = params["swing"]?.double { env["swing"] = .number(s) }
    env["nets"] = .object(nets)
    // library sounds that come in over the track as parallel tracks (`LoopLayers`)
    let layers = try LoopLayers.parse(params["layers"] ?? params[LoopLayers.envelopeKey])
    if !layers.isEmpty { env[LoopLayers.envelopeKey] = LoopLayers.json(layers) }
    return .object(env)
  }

  static func notes(of part: JSONValue, in id: String, drumNote: Int?) throws -> [Note] {
    guard let list = part["notes"]?.array else {
      throw PianoRollError.bad("part `\(id)` needs `notes`: [[step, note, dur?, vel?], …]")
    }
    func int(_ v: JSONValue?) -> Int? { v?.double.map { Int($0.rounded()) } }
    var out: [Note] = []
    for (k, raw) in list.enumerated() {
      let step: Int?
      var note: Int?
      var dur: Int?
      var vel: Int?
      if let a = raw.array {
        step = int(a.first)
        note = a.count > 1 ? int(a[1]) : nil
        dur = a.count > 2 ? int(a[2]) : nil
        vel = a.count > 3 ? int(a[3]) : nil
      } else {
        step = int(raw["step"])
        note = int(raw["note"])
        dur = int(raw["dur"] ?? raw["duration"])
        vel = int(raw["vel"] ?? raw["velocity"])
      }
      guard let step, step >= 0 else {
        throw PianoRollError.bad("part `\(id)` note \(k): `step` must be an integer ≥ 0")
      }
      guard let n = note ?? drumNote, (0...127).contains(n) else {
        throw PianoRollError.bad("part `\(id)` note \(k): `note` must be a MIDI number 0…127")
      }
      out.append(
        Note(
          step: step, note: n, duration: max(1, dur ?? (drumNote == nil ? 2 : 1)),
          velocity: min(127, max(1, vel ?? 100))))
    }
    return out
  }

  static func ring(
    steps: Int, lane: [Int: Note], channel: Int, instrument: String,
    group: (role: String, id: String)?
  ) -> JSONValue {
    var places = JSONObject()
    var transitions = JSONObject()
    var arcs: [JSONValue] = []
    for i in 0..<steps {
      places["p\(i)"] = .object(
        i == 0 ? JSONObject([("initial", .array([.number(1)]))]) : JSONObject())
      var t = JSONObject()
      if let n = lane[i] {
        t["midi"] = .object(
          JSONObject([
            ("note", .int(n.note)), ("channel", .int(channel)), ("velocity", .int(n.velocity)),
            ("durationSteps", .int(n.duration)),
          ]))
      }
      transitions["t\(i)"] = .object(t)
      arcs.append(
        .object(JSONObject([("source", .string("p\(i)")), ("target", .string("t\(i)"))])))
      arcs.append(
        .object(
          JSONObject([("source", .string("t\(i)")), ("target", .string("p\((i + 1) % steps)"))])))
    }
    var track = JSONObject([("channel", .int(channel)), ("instrument", .string(instrument))])
    if group != nil { track["group"] = .string(group!.role) }
    var net = JSONObject([
      ("track", .object(track)), ("places", .object(places)),
      ("transitions", .object(transitions)), ("arcs", .array(arcs)),
    ])
    if let group {
      net["riffGroup"] = .string(group.role)
      net["riffVariant"] = .string(String(group.id.split(separator: "-").last ?? "b"))
    }
    return .object(net)
  }
}
