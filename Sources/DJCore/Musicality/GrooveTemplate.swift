import Foundation

/// A family's groove template (ROADMAP 6.5): for each drum voice and each sixteenth of a 4/4
/// bar, how late a human drummer plays it (ms) and how hard (a velocity scale around 1), plus
/// a swing ratio that depends on tempo. Distilled from the Groove MIDI Dataset (CC BY 4.0) by
/// `scripts/groove-templates.py` into `Resources/beats/grooves.json` (`make groove-templates`),
/// checked in like `tables.json`; the file's `provenance` says how.
///
/// Offsets are never negative: the runner can hold a note back, not play it before its tick,
/// so a template is measured relative to the family's downbeat kick and hits ahead of it play
/// on the tick. A position with fewer than `minHits` hits in the dataset is neutral (0 ms, ×1).
///
/// Data only: nothing plays it yet. `prepared(bpm:sampleRate:)` builds the fixed arrays a
/// render reads (off the audio thread; reading a `Prepared` never allocates).
public struct GrooveTemplate: Equatable, Sendable {
  /// The drum voices a template has, in the file's order. MIDI notes fold onto them the way the
  /// dataset's kit (Roland TD-11) does, plus beats' clap (39) as a snare.
  public enum Voice: Int, CaseIterable, Sendable {
    case kick, snare, hihat, openHat, ride

    public var name: String { ["kick", "snare", "hihat", "openHat", "ride"][rawValue] }

    public init?(note: Int) {
      switch note {
      case 35, 36: self = .kick
      case 37, 38, 39, 40: self = .snare
      case 22, 42, 44: self = .hihat
      case 26, 46: self = .openHat
      case 51, 53, 59: self = .ride
      default: return nil
      }
    }
  }

  /// Linn's swing ratio: where the off-beat member of a pair starts, as a share of the pair
  /// (0.50 straight … 0.66 triplet). The pair is two sixteenths (`.sixteenth`) or two eighths
  /// (`.eighth`, the jazz family).
  public struct Swing: Equatable, Sendable {
    public enum Grid: String, Sendable {
      case sixteenth = "16th"
      case eighth = "8th"
    }
    public static let straight = 0.50
    public static let triplet = 0.66

    public var grid: Grid
    public var intercept: Double
    public var perBpm: Double
    /// The tempi the line was fitted over; outside it the ratio holds at the edge.
    public var bpmRange: ClosedRange<Double>

    /// `intercept + perBpm × bpm`, bpm clamped to `bpmRange`, ratio to straight … triplet.
    public func ratio(bpm: Double) -> Double {
      let b = min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound)
      return min(max(intercept + perBpm * b, Self.straight), Self.triplet)
    }

    /// Sixteenths in a pair.
    public var pairSteps: Int { grid == .eighth ? 4 : 2 }

    /// The off-beat member's delay in ms at `bpm`: (ratio − ½) of the pair.
    public func delayMs(bpm: Double) -> Double {
      let sixteenthMs = 15_000 / bpm
      return (ratio(bpm: bpm) - Self.straight) * Double(pairSteps) * sixteenthMs
    }
  }

  public static let steps = 16
  /// beats' structure.js family order (`BeatsTables.family(of:)`).
  public static let familyNames = ["dance", "song", "jazz", "chill"]

  public var family: String
  public var index: Int
  /// The dataset styles averaged into it, and how many files they had.
  public var styles: [String]
  public var files: Int
  public var swing: Swing
  /// `[voice][step]`, ms late, 0 … `maxOffsetMs`.
  public var offsetMs: [[Double]]
  /// `[voice][step]`, mean velocity there / the voice's mean velocity.
  public var velocity: [[Double]]
  /// `[voice][step]`, the dataset's hit count behind each cell.
  public var hits: [[Int]]

  public static let maxOffsetMs = 15.0
  public static let velocityRange = 0.25...1.75

  public func offsetMs(_ voice: Voice, step: Int) -> Double {
    offsetMs[voice.rawValue][step & (Self.steps - 1)]
  }

  public func velocity(_ voice: Voice, step: Int) -> Double {
    velocity[voice.rawValue][step & (Self.steps - 1)]
  }

  // MARK: table

  /// Every family's template, by name.
  public static let all: [String: GrooveTemplate] = {
    do { return try parse(Data(loadText().utf8)).templates } catch {
      fatalError("groove templates: \(error)")
    }
  }()

  /// The template for a family (`BeatsTables.family(of:)`'s index).
  public static func family(index: Int) -> GrooveTemplate? {
    all.values.first { $0.index == index }
  }

  /// The template a genre plays with: its beats family's (an unknown genre is beats' default
  /// family, song).
  public static func forGenre(_ genre: String) -> GrooveTemplate? {
    family(index: BeatsTables.shared.family(of: genre))
  }

  static func loadText() throws -> String {
    // In DJApp.app the tables sit in Contents/Resources/beats (scripts/bundle-app.sh).
    guard
      let url = Bundle.main.url(
        forResource: "grooves", withExtension: "json", subdirectory: "beats")
        ?? Bundle.module.url(forResource: "grooves", withExtension: "json", subdirectory: "beats")
    else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "beats/grooves.json"]) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  struct File: Decodable {
    struct Provenance: Decodable {
      var url: String
      var sha256: String
      var license: String
      var minHits: Int
    }
    struct SwingJSON: Decodable {
      var grid: String
      var intercept: Double
      var perBpm: Double
      var bpmRange: [Double]
    }
    struct VoiceJSON: Decodable {
      var offsetMs: [Double]
      var velocity: [Double]
      var hits: [Int]
    }
    struct Family: Decodable {
      var index: Int
      var styles: [String]
      var files: Int
      var swing: SwingJSON
      var voices: [String: VoiceJSON]
    }
    var provenance: Provenance
    var voices: [String]
    var families: [String: Family]
  }

  struct Parsed {
    var provenance: File.Provenance
    var templates: [String: GrooveTemplate]
  }

  static func parse(_ data: Data) throws -> Parsed {
    let f = try JSONDecoder().decode(File.self, from: data)
    func bad(_ why: String) -> Error {
      CocoaError(
        .fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "grooves.json: \(why)"])
    }
    guard f.voices == Voice.allCases.map(\.name) else { throw bad("voices \(f.voices)") }
    var out: [String: GrooveTemplate] = [:]
    for (name, fam) in f.families {
      guard let grid = Swing.Grid(rawValue: fam.swing.grid), fam.swing.bpmRange.count == 2,
        fam.swing.bpmRange[0] <= fam.swing.bpmRange[1]
      else { throw bad("\(name) swing") }
      var off: [[Double]] = []
      var vel: [[Double]] = []
      var hits: [[Int]] = []
      for v in Voice.allCases {
        guard let c = fam.voices[v.name], c.offsetMs.count == steps, c.velocity.count == steps,
          c.hits.count == steps
        else { throw bad("\(name).\(v.name)") }
        off.append(c.offsetMs)
        vel.append(c.velocity)
        hits.append(c.hits)
      }
      out[name] = GrooveTemplate(
        family: name, index: fam.index, styles: fam.styles, files: fam.files,
        swing: Swing(
          grid: grid, intercept: fam.swing.intercept, perBpm: fam.swing.perBpm,
          bpmRange: fam.swing.bpmRange[0]...fam.swing.bpmRange[1]),
        offsetMs: off, velocity: vel, hits: hits)
    }
    return Parsed(provenance: f.provenance, templates: out)
  }

  // MARK: prepared

  /// A template at one tempo and sample rate, flattened into fixed arrays (`voice × 16 + step`)
  /// with the swing folded into each off-beat step's delay. Built off the audio thread; its
  /// lookups only index.
  public struct Prepared: Sendable {
    public let bpm: Double
    public let sampleRate: Double
    /// The swing ratio at `bpm`.
    public let swingRatio: Double
    /// Samples late, microtiming + swing.
    public let delaySamples: [Double]
    public let velocityScale: [Double]

    @inline(__always) static func cell(_ voice: Voice, _ step: Int) -> Int {
      voice.rawValue * GrooveTemplate.steps + (step & (GrooveTemplate.steps - 1))
    }

    /// How late (samples) `voice` plays on bar step `step` (any step: taken mod 16).
    @inline(__always) public func delay(_ voice: Voice, step: Int) -> Double {
      delaySamples[Self.cell(voice, step)]
    }

    @inline(__always) public func velocity(_ voice: Voice, step: Int) -> Double {
      velocityScale[Self.cell(voice, step)]
    }
  }

  public func prepared(bpm: Double, sampleRate: Double) -> Prepared {
    let swingMs = swing.delayMs(bpm: bpm)
    let half = swing.pairSteps / 2
    var delay = [Double](repeating: 0, count: Voice.allCases.count * Self.steps)
    var vel = [Double](repeating: 1, count: delay.count)
    for v in Voice.allCases {
      for s in 0..<Self.steps {
        let ms = offsetMs[v.rawValue][s] + (s % swing.pairSteps == half ? swingMs : 0)
        delay[Prepared.cell(v, s)] = ms / 1000 * sampleRate
        vel[Prepared.cell(v, s)] = velocity[v.rawValue][s]
      }
    }
    return Prepared(
      bpm: bpm, sampleRate: sampleRate, swingRatio: swing.ratio(bpm: bpm), delaySamples: delay,
      velocityScale: vel)
  }
}
