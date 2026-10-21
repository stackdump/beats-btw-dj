import Foundation

// A Standard MIDI File → a piano roll (`PianoRoll`) → a raw-`nets` share (`dj_import`).
// Reads format 0 / 1 files (ticks per quarter; SMPTE time is refused), keeps notes, program
// changes, the first tempo and time signature, quantises onto sixteenth steps and sorts the
// channels into the deck's roles (kick snare hihat clap bass melody harmony arp). Everything the
// grid can't hold is counted and reported, never silently dropped: tempo changes, drums with no
// role, notes past three at one step, notes outside the excerpt.
//
// Pure: bytes in, a `MidiImport.Result` out. The app reads the file and loads the envelope;
// it never publishes (a raw-nets share embeds the notes: mind the file's licence).

public enum MidiImportError: Error, Equatable, CustomStringConvertible {
  case notMidi
  case smpte
  case noNotes
  case bad(String)
  public var description: String {
    switch self {
    case .notMidi: return "not a Standard MIDI File (no MThd header)"
    case .smpte: return "SMPTE-timed MIDI files are not supported (ticks per quarter only)"
    case .noNotes: return "the file has no notes"
    case .bad(let m): return m
    }
  }
}

public enum MidiImport {
  public struct RawNote: Equatable {
    public var start: Int  // ticks
    public var end: Int
    public var pitch: Int
    public var velocity: Int
  }

  /// One (track, channel) stream of notes, as the file has it.
  public struct Source {
    public var track: Int
    public var channel: Int  // 0…15
    public var name: String
    public var program: Int?
    public var notes: [RawNote]
    public var key: String { "\(track):\(channel + 1)" }
    public var isDrums: Bool { channel == 9 }
  }

  public struct Parsed {
    public var format: Int
    public var ticksPerQuarter: Int
    public var tempos: [(tick: Int, microsPerQuarter: Int)]
    public var timeSignature: (numerator: Int, denominator: Int)?
    public var title: String?
    public var sources: [Source]
    public var lastTick: Int
  }

  // MARK: parse

  public static func parse(_ data: Data) throws -> Parsed {
    let b = [UInt8](data)
    var pos = 0
    func u32(_ at: Int) -> Int {
      Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
    func u16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
    guard b.count >= 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else {
      throw MidiImportError.notMidi
    }
    let headerLen = u32(4)
    let format = u16(8)
    let division = u16(12)
    guard division & 0x8000 == 0, division > 0 else { throw MidiImportError.smpte }
    pos = 8 + headerLen

    var out = Parsed(
      format: format, ticksPerQuarter: division, tempos: [], timeSignature: nil, title: nil,
      sources: [], lastTick: 0)
    var trackIndex = 0
    while pos + 8 <= b.count {
      let isTrack = b[pos] == 0x4D && b[pos + 1] == 0x54 && b[pos + 2] == 0x72 && b[pos + 3] == 0x6B
      let len = u32(pos + 4)
      let body = pos + 8
      let end = min(b.count, body + len)
      pos = body + len
      guard isTrack else { continue }
      parseTrack(b, from: body, to: end, index: trackIndex, into: &out)
      trackIndex += 1
    }
    out.tempos.sort { $0.tick < $1.tick }
    guard out.sources.contains(where: { !$0.notes.isEmpty }) else { throw MidiImportError.noNotes }
    return out
  }

  private static func parseTrack(
    _ b: [UInt8], from start: Int, to end: Int, index: Int, into out: inout Parsed
  ) {
    var p = start
    var tick = 0
    var running: UInt8 = 0
    var trackName: String?
    var programs: [Int: Int] = [:]
    var open: [Int: [(tick: Int, vel: Int)]] = [:]  // channel << 8 | pitch → FIFO of starts
    var notes: [Int: [RawNote]] = [:]  // channel → notes

    func vlq() -> Int? {
      var v = 0
      for _ in 0..<4 {
        guard p < end else { return nil }
        let c = Int(b[p])
        p += 1
        v = v << 7 | (c & 0x7F)
        if c & 0x80 == 0 { return v }
      }
      return v
    }
    func close(_ ch: Int, _ pitch: Int, at t: Int) {
      let k = ch << 8 | pitch
      guard var q = open[k], !q.isEmpty else { return }
      let s = q.removeFirst()
      open[k] = q
      notes[ch, default: []].append(
        RawNote(start: s.tick, end: max(t, s.tick), pitch: pitch, velocity: s.vel))
    }

    while p < end {
      guard let delta = vlq() else { break }
      tick += delta
      guard p < end else { break }
      var status = b[p]
      if status & 0x80 != 0 {
        p += 1
        if status < 0xF0 { running = status }
      } else {
        status = running  // running status: this byte is data
        if status == 0 { break }
      }
      switch status {
      case 0xFF:
        guard p < end else { break }
        let type = b[p]
        p += 1
        guard let len = vlq(), p + len <= end else {
          p = end
          continue
        }
        let d = Array(b[p..<(p + len)])
        p += len
        switch type {
        case 0x03:
          if trackName == nil { trackName = String(decoding: d, as: UTF8.self) }
        case 0x51 where len == 3:
          out.tempos.append((tick, Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2])))
        case 0x58 where len >= 2:
          if out.timeSignature == nil {
            out.timeSignature = (Int(d[0]), 1 << Int(min(d[1], 6)))
          }
        case 0x2F: p = end
        default: break
        }
      case 0xF0, 0xF7:
        guard let len = vlq() else {
          p = end
          continue
        }
        p += len
      default:
        let kind = status & 0xF0
        let ch = Int(status & 0x0F)
        let need = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
        guard p + need <= end else {
          p = end
          continue
        }
        let d1 = Int(b[p])
        let d2 = need == 2 ? Int(b[p + 1]) : 0
        p += need
        switch kind {
        case 0x90 where d2 > 0:
          open[ch << 8 | d1, default: []].append((tick, d2))
        case 0x90, 0x80:
          close(ch, d1, at: tick)
        case 0xC0:
          if programs[ch] == nil { programs[ch] = d1 }
        default: break
        }
      }
    }
    for (k, q) in open { for _ in q { close(k >> 8, k & 0xFF, at: tick) } }
    out.lastTick = max(out.lastTick, tick)
    if out.title == nil, index == 0, let n = trackName, !n.isEmpty { out.title = n }
    for ch in notes.keys.sorted() {
      out.sources.append(
        Source(
          track: index, channel: ch, name: trackName ?? "", program: programs[ch],
          notes: notes[ch]!.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }))
    }
  }

  // MARK: roles

  static let drumRole: [Int: (role: String, note: Int)] = [
    35: ("kick", 36), 36: ("kick", 36),
    37: ("snare", 38), 38: ("snare", 38), 40: ("snare", 38),
    39: ("clap", 39),
    42: ("hihat", 42), 44: ("hihat", 42), 46: ("hihat", 46),
  ]

  /// beats' instrument names for a GM program (0-based); nil = the role's default.
  static func instrument(program: Int?) -> String? {
    guard let p = program else { return nil }
    switch p {
    case 0...3: return "piano"
    case 4, 5: return "electric-piano"
    case 6: return "harpsichord"
    case 7: return "clavinet"
    case 8, 10: return "music-box"
    case 9, 11: return "vibes"
    case 12, 13: return "marimba"
    case 14: return "fm-bell"
    case 16...23: return "organ"
    case 24, 25: return "acoustic-guitar"
    case 26, 27, 31: return "electric-guitar"
    case 28: return "muted-pluck"
    case 29, 30: return "distorted-guitar"
    case 32, 33, 34: return "bass"
    case 35, 38, 39: return "sub-bass"
    case 36, 37: return "rubber-bass"
    case 40...45, 48...51: return "strings"
    case 46: return "pluck"
    case 52...54: return "choir"
    case 56, 59: return "trumpet"
    case 57, 58, 60...63: return "brass"
    case 64...71: return "sax"
    case 72...79: return "flute"
    case 80: return "square-lead"
    case 81: return "supersaw"
    case 82...87: return "lead"
    case 88...95: return "warm-pad"
    case 104: return "sitar"
    case 114: return "steel-drum"
    default: return nil
    }
  }

  /// Role for a pitched source from its program and notes (a user `map` overrides this).
  static func role(of s: Source, stepTicks: Double) -> String {
    if let p = s.program {
      if (32...39).contains(p) { return "bass" }
      if (88...95).contains(p) || (48...54).contains(p) { return "harmony" }
    }
    let mean = Double(s.notes.reduce(0) { $0 + $1.pitch }) / Double(max(1, s.notes.count))
    if mean < 50 { return "bass" }
    var onsets: [Int: Int] = [:]
    for n in s.notes { onsets[Int((Double(n.start) / stepTicks).rounded()), default: 0] += 1 }
    let chordy = Double(onsets.values.filter { $0 > 1 }.count) / Double(max(1, onsets.count))
    return chordy > 0.35 ? "harmony" : "melody"
  }

  // MARK: import

  public struct Options {
    public var from = 0  // first bar (0-based)
    public var bars = 16
    public var tempo: Double?
    public var map: [String: String] = [:]  // "track:channel" or "channel" → role, or "skip"
    public var name: String?
    public var source: String?  // provenance / licence text, kept in the share's note
    public init() {}
  }

  public struct Part {
    public var role: String
    public var from: String  // source key
    public var program: Int?
    public var instrument: String?
    public var notes: Int
  }

  public struct Result {
    public var envelope: JSONValue
    public var summary: JSONValue
  }

  public static let maxBars = 64

  public static func convert(_ data: Data, file: String, options o: Options = .init()) throws
    -> Result
  {
    let m = try parse(data)
    let tpq = m.ticksPerQuarter
    let stepTicks = Double(tpq) / 4
    let sig = m.timeSignature ?? (4, 4)
    let stepsPerBar = max(1, 16 * sig.numerator / max(1, sig.denominator))
    guard (0...64).contains(o.from), o.bars >= 1, o.bars <= maxBars else {
      throw MidiImportError.bad("`from` must be ≥ 0 and `bars` 1…\(maxBars)")
    }
    let totalBars = Int((Double(m.lastTick) / stepTicks / Double(stepsPerBar)).rounded(.up))
    let window = (o.from * stepsPerBar)..<((o.from + o.bars) * stepsPerBar)
    let bars = min(o.bars, max(1, totalBars - o.from))
    let steps = bars * stepsPerBar

    var warnings: [String] = []
    var dropped: [String: Int] = [:]
    var parts: [String: [JSONValue]] = [:]
    var partInfo: [String: Part] = [:]
    var instrumentFor: [String: String] = [:]
    var sourcesJSON: [JSONValue] = []

    for s in m.sources where !s.notes.isEmpty {
      let override = o.map[s.key] ?? o.map["\(s.channel + 1)"]
      if override == "skip" {
        sourcesJSON.append(srcJSON(s, role: "skip", kept: 0))
        continue
      }
      var kept = 0
      var role = ""
      if s.isDrums {
        for n in s.notes {
          let step = Int((Double(n.start) / stepTicks).rounded())
          guard window.contains(step) else {
            dropped["outsideExcerpt", default: 0] += 1
            continue
          }
          guard let d = drumRole[n.pitch] else {
            dropped["drumsWithoutARole", default: 0] += 1
            continue
          }
          parts[d.role, default: []].append(
            .array([.int(step - window.lowerBound), .int(d.note), .int(1), .int(n.velocity)]))
          partInfo[d.role] = Part(
            role: d.role, from: s.key, program: nil, instrument: nil, notes: 0)
          kept += 1
        }
        sourcesJSON.append(srcJSON(s, role: "drums", kept: kept))
        continue
      }
      role = override ?? Self.role(of: s, stepTicks: stepTicks)
      guard PianoRoll.roles[role] != nil, PianoRoll.roles[role]?.drumNote == nil else {
        throw MidiImportError.bad(
          "`map` role \(role) for \(s.key): use bass, melody, harmony, arp or skip")
      }
      for n in s.notes {
        let step = Int((Double(n.start) / stepTicks).rounded())
        guard window.contains(step) else {
          dropped["outsideExcerpt", default: 0] += 1
          continue
        }
        let rel = step - window.lowerBound
        let dur = max(1, Int((Double(n.end - n.start) / stepTicks).rounded()))
        parts[role, default: []].append(
          .array([.int(rel), .int(n.pitch), .int(min(dur, steps - rel)), .int(n.velocity)]))
        kept += 1
      }
      if partInfo[role] == nil {
        partInfo[role] = Part(
          role: role, from: s.key, program: s.program, instrument: nil, notes: 0)
        if let i = instrument(program: s.program) { instrumentFor[role] = i }
      } else {
        partInfo[role]!.from += "+" + s.key
      }
      sourcesJSON.append(srcJSON(s, role: role, kept: kept))
    }

    // At most three notes start on one step per role: more would be dozens of sibling rings.
    var rolls = JSONObject()
    for role in parts.keys.sorted() {
      var byStep: [Int: [JSONValue]] = [:]
      for n in parts[role]! { byStep[n.array![0].int ?? 0, default: []].append(n) }
      var notes: [JSONValue] = []
      for step in byStep.keys.sorted() {
        var here = byStep[step]!
        here.sort { ($0.array![1].int ?? 0) < ($1.array![1].int ?? 0) }
        if role != "bass" { here.reverse() }  // keep the top voices; a bass keeps its lowest
        var seen = Set<Int>()
        here = here.filter { seen.insert($0.array![1].int ?? 0).inserted }
        if here.count > 3 { dropped["polyphonyOverThree", default: 0] += here.count - 3 }
        notes += here.prefix(3)
      }
      var part = JSONObject([("notes", .array(notes))])
      if let i = instrumentFor[role] { part["instrument"] = .string(i) }
      rolls[role] = .object(part)
      partInfo[role]?.notes = notes.count
    }
    guard !rolls.entries.isEmpty else {
      throw MidiImportError.bad("no notes fall in bars \(o.from + 1)–\(o.from + bars)")
    }

    let bpm: Double
    if let t = o.tempo {
      bpm = t
    } else if let first = m.tempos.first {
      bpm = 60_000_000 / Double(first.microsPerQuarter)
    } else {
      bpm = 120
    }
    let clamped = min(300, max(40, bpm))
    if clamped != bpm { warnings.append("tempo \(Int(bpm)) BPM clamped to \(Int(clamped))") }
    if m.tempos.count > 1 && o.tempo == nil {
      warnings.append("\(m.tempos.count) tempo changes: only the first is kept")
    }
    if sig.numerator != 4 || sig.denominator != 4 {
      warnings.append(
        "time signature \(sig.numerator)/\(sig.denominator): bars are \(stepsPerBar) steps")
    }
    if totalBars - o.from > bars {
      warnings.append(
        "excerpt: bars \(o.from + 1)–\(o.from + bars) of \(totalBars); use `from` / `bars` for more"
      )
    }

    let title =
      o.name ?? m.title
      ?? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    var params = JSONObject([
      ("name", .string(title)), ("tempo", .number(clamped)), ("steps", .int(steps)),
      ("parts", .object(rolls)),
    ])
    let envelope = try PianoRoll.envelope(.object(params))
    var env = envelope.object ?? JSONObject()
    var note = "Imported from \(URL(fileURLWithPath: file).lastPathComponent)"
    if let src = o.source, !src.isEmpty { note += " — \(src)" }
    env["note"] = .string(note)
    params["name"] = .string(title)

    let summary: JSONValue = .object(
      JSONObject([
        ("file", .string(URL(fileURLWithPath: file).lastPathComponent)),
        ("title", .string(title)), ("format", .int(m.format)),
        ("tempo", .number(clamped)),
        ("timeSignature", .string("\(sig.numerator)/\(sig.denominator)")),
        ("totalBars", .int(totalBars)), ("from", .int(o.from)), ("bars", .int(bars)),
        ("steps", .int(steps)),
        (
          "parts",
          .array(
            partInfo.keys.sorted().map { r in
              let p = partInfo[r]!
              var j = JSONObject([
                ("role", .string(r)), ("from", .string(p.from)), ("notes", .int(p.notes)),
              ])
              if let i = instrumentFor[r] { j["instrument"] = .string(i) }
              return .object(j)
            })
        ),
        ("sources", .array(sourcesJSON)),
        (
          "dropped",
          .object(JSONObject(dropped.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) }))
        ),
        ("warnings", .array(warnings.map { .string($0) })),
      ]))
    return Result(envelope: .object(env), summary: summary)
  }

  private static func srcJSON(_ s: Source, role: String, kept: Int) -> JSONValue {
    var j = JSONObject([
      ("key", .string(s.key)), ("track", .int(s.track)), ("channel", .int(s.channel + 1)),
      ("notes", .int(s.notes.count)), ("role", .string(role)), ("kept", .int(kept)),
    ])
    if !s.name.isEmpty { j["name"] = .string(s.name) }
    if let p = s.program { j["program"] = .int(p) }
    return .object(j)
  }
}
