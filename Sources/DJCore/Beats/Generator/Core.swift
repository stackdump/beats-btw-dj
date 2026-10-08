import Foundation

// Port of beats' generator/core.js: scales, accents, params, seeds.

public let majorIntervals = [0, 2, 4, 5, 7, 9, 11]

public func scaleIntervals(_ scaleFunctionName: String) -> [Int] {
  switch scaleFunctionName {
  case "MajorScale": [0, 2, 4, 5, 7, 9, 11]
  case "MinorScale": [0, 2, 3, 5, 7, 8, 10]
  case "DorianScale": [0, 2, 3, 5, 7, 9, 10]
  case "MixolydianScale": [0, 2, 4, 5, 7, 9, 10]
  case "PhrygianScale": [0, 1, 3, 5, 7, 8, 10]
  case "HarmonicMinScale": [0, 2, 3, 5, 7, 8, 11]
  case "PentatonicScale": [0, 2, 4, 7, 9]
  case "MinPentatonicScale": [0, 3, 5, 7, 10]
  case "BluesScale": [0, 3, 5, 6, 7, 10]
  default: [0, 2, 4, 5, 7, 9, 11]
  }
}

/// `scaleNotes`: MIDI notes over `octaves` octaves, dropping anything above 127.
public func scaleNotes(_ root: Int, _ intervals: [Int], octaves: Int = 2) -> [Int] {
  var notes: [Int] = []
  for oct in 0..<octaves {
    for interval in intervals {
      let note = root + oct * 12 + interval
      if note <= 127 { notes.append(note) }
    }
  }
  return notes
}

public func majorScale(_ root: Int) -> [Int] { scaleNotes(root, majorIntervals, octaves: 2) }

public enum Accent: Int {
  case none = 0
  case kick = 1
  case snare = 2
  case hihat = 3
}

/// `accentVelocity`
public func accentVelocity(step: Int, total: Int, base: Int, accent: Accent) -> Int {
  let jitter = ((step * 7 + 13) % 11) - 5
  switch accent {
  case .kick:
    switch step % 4 {
    case 0: return base + 20 + jitter
    case 2: return base + 8 + jitter
    default: return base - 15 + jitter
    }
  case .snare:
    return base + jitter
  case .hihat:
    return step % 2 == 0 ? base + 10 + jitter : base - 30 + jitter
  case .none:
    return base + jitter
  }
}

/// `clampVelocity`: MIDI range 1–127.
public func clampVelocity(_ v: Int) -> Int { v < 1 ? 1 : (v > 127 ? 127 : v) }

/// `drumSeed`: FNV-1a over UTF-16 code units, 64-bit, then `BigInt.asIntN(53)`.
public func drumSeed(_ genre: String) -> Double {
  var h: UInt64 = 0xcbf2_9ce4_8422_2325
  for u in genre.utf16 {
    h ^= UInt64(u)
    h = h &* 0x0000_0100_0000_01b3
  }
  let low = h & ((1 << 53) - 1)
  let signed = low >= (1 << 52) ? Int64(low) - (1 << 53) : Int64(low)
  return Double(signed)
}

// MARK: - Random sources

public protocol RandomSource {
  mutating func float64() -> Double
}
extension Mulberry32: RandomSource {}

/// The "simple LCG" variety.js uses for ghost notes / walking bass / call-response.
/// All arithmetic is done in doubles then ToInt32'd, exactly as JS does, so large
/// seeds lose precision in the same places.
public struct LCG: RandomSource {
  var state: Double
  public init(seed: Double) { state = seed }
  public mutating func float64() -> Double {
    let t = state * 1_664_525 + 1_013_904_223
    state = Double(jsToInt32(t) & 0x7fff_ffff)
    return state / 2_147_483_648
  }
  public mutating func intn(_ n: Int) -> Int { Int((float64() * Double(n)).rounded(.down)) }
}

// MARK: - Generation params (the loose JS params object)

public struct GenParams {
  public var scale: [Int] = []
  public var rootNote = 60
  public var channel = 1
  public var velocity = 100
  public var duration = 100
  public var density = 0.5
  public var steps: Int?
  public var seed = 0.0
  public var accent: Accent = .none
  public var chords: ChordProg?
  public var durationVariation = 0.0
  public var syncopation = 0.0
  public init() {}
}

// MARK: - Ring nets

/// Layout helper shared by every ring generator. Matches `ringLayout`.
func ringLayout(_ n: Int) -> (cx: Double, cy: Double, radius: Double) {
  var radius = Double(n) * 70.0 / (2 * Double.pi * 0.7)
  if radius < 150 { radius = 150 }
  return (radius + 80, radius + 80, radius)
}

extension NetBundle {
  /// The ring every generator builds: `p0..p(n-1)` (token on p0), `t0..t(n-1)`,
  /// arcs `pi → ti → p(i+1 mod n)`. Callers add bindings and the track.
  static func ring(_ n: Int) -> NetBundle {
    var nb = NetBundle()
    let (cx, cy, radius) = ringLayout(n)
    for i in 0..<n {
      let angle = Double(i) / Double(n) * 2 * Double.pi
      nb.places["p\(i)"] = Place(
        initial: [i == 0 ? 1 : 0], x: cx + radius * 0.7 * cos(angle),
        y: cy + radius * 0.7 * sin(angle), label: nil)
    }
    for i in 0..<n {
      let tAngle = (Double(i) + 0.5) / Double(n) * 2 * Double.pi
      nb.transitions["t\(i)"] = Transition(
        x: cx + radius * cos(tAngle), y: cy + radius * sin(tAngle), label: nil)
      nb.arcs.append(Arc(source: "p\(i)", target: "t\(i)", weight: [1], inhibit: false))
      nb.arcs.append(Arc(source: "t\(i)", target: "p\((i + 1) % n)", weight: [1], inhibit: false))
    }
    return nb
  }

  mutating func bind(_ transition: Int, note: Int, channel: Int, velocity: Int, duration: Int) {
    bindings["t\(transition)"] = MidiBinding(
      note: note, channel: channel, velocity: velocity, duration: duration, durationSteps: 0)
  }
}

func obj(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var o = JSONObject()
  for (k, v) in pairs { if let v { o[k] = v } }
  return .object(o)
}

func jsonArray(_ ints: [Int]) -> JSONValue { .array(ints.map { .int($0) }) }
