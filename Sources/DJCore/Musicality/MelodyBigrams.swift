import Foundation

/// A melody scale-degree bigram table (ROADMAP 6.4, contour by corpus): for each of the seven
/// diatonic degrees of the key, how likely a sung melody's next note is each degree. Counted
/// from the RS200 rock corpus's vocal transcriptions (de Clercq & Temperley, CC BY 4.0) by
/// `scripts/melody-bigrams.py` into `Resources/beats/melody-bigrams.json`
/// (`make melody-bigrams`), checked in like `tables.json`; the file's `provenance` says how.
///
/// Degrees are 0-based (0 = the tonic) and folded: b3 counts as 3, b7 as 7, so one table
/// covers rock's mixed major / minor. `next` includes repeated notes; `moves` is the same
/// distribution given that the melody moves (its diagonal is 0), which is what a pass picking
/// where a repeat or passing tone should go wants.
///
/// `.shape` (`MelodyShape.swift`) reads `moves` to place repeats and passing tones.
public struct MelodyBigrams: Equatable, Sendable {
  public static let degrees = 7

  /// The corpus's interval shares: same / neighbouring degree from the table (7 → 1 is a
  /// step), and 0 / 1–2 / more semitones from the pitches.
  public struct Stats: Equatable, Sendable {
    public var repeats: Double
    public var steps: Double
    public var stepsOfMoves: Double
    public var pitchRepeats: Double
    public var pitchSteps: Double
    public var pitchLeaps: Double
  }

  public var name: String
  public var songs: Int
  public var bigrams: Int
  /// How often each degree is sung.
  public var unigram: [Double]
  /// `[degree][next]`, P(next | degree); rows sum to 1.
  public var next: [[Double]]
  /// `[degree][next]`, P(next | degree, next ≠ degree); rows sum to 1, the diagonal is 0.
  public var moves: [[Double]]
  /// `[degree][next]`, the corpus's counts behind both.
  public var counts: [[Int]]
  public var stats: Stats

  @inline(__always) static func wrap(_ d: Int) -> Int { ((d % degrees) + degrees) % degrees }

  /// P(`to` | `from`), degrees taken mod 7 (so 7 is the tonic an octave up, −1 the 7th below).
  public func probability(from: Int, to: Int) -> Double {
    next[Self.wrap(from)][Self.wrap(to)]
  }

  /// The degree (0…6) most likely to follow `degree`; `moving` leaves the repeat out. Ties go
  /// to the lower degree.
  public func mostLikely(after degree: Int, moving: Bool = false) -> Int {
    let row = (moving ? moves : next)[Self.wrap(degree)]
    var best = 0
    for d in 1..<Self.degrees where row[d] > row[best] { best = d }
    return best
  }

  /// The table's share of steps (to a neighbouring degree), weighted by how often each degree
  /// is the first of a bigram.
  public var stepShare: Double {
    share { $0 != $1 && (Self.wrap($0 - $1) == 1 || Self.wrap($1 - $0) == 1) }
  }

  /// The table's share of repeated degrees, weighted like `stepShare`.
  public var repeatShare: Double { share { $0 == $1 } }

  func share(_ include: (Int, Int) -> Bool) -> Double {
    let rowTotals = counts.map { Double($0.reduce(0, +)) }
    let all = rowTotals.reduce(0, +)
    guard all > 0 else { return 0 }
    var s = 0.0
    for i in 0..<Self.degrees {
      for j in 0..<Self.degrees where include(i, j) { s += rowTotals[i] * next[i][j] }
    }
    return s / all
  }

  // MARK: table

  /// Every table in the file, by name (today only `default`).
  public static let all: [String: MelodyBigrams] = {
    do { return try parse(Data(loadText().utf8)).tables } catch {
      fatalError("melody bigrams: \(error)")
    }
  }()

  /// The corpus-wide table.
  public static var `default`: MelodyBigrams {
    guard let t = all["default"] else { fatalError("melody bigrams: no default table") }
    return t
  }

  static func loadText() throws -> String {
    // In DJApp.app the tables sit in Contents/Resources/beats (scripts/bundle-app.sh).
    guard
      let url = Bundle.main.url(
        forResource: "melody-bigrams", withExtension: "json", subdirectory: "beats")
        ?? Bundle.module.url(
          forResource: "melody-bigrams", withExtension: "json", subdirectory: "beats")
    else {
      throw CocoaError(
        .fileNoSuchFile, userInfo: [NSFilePathErrorKey: "beats/melody-bigrams.json"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  struct File: Decodable {
    struct Provenance: Decodable {
      var source: String
      var url: String
      var sha256: String
      var license: String
    }
    struct Pitch: Decodable {
      var repeats: Double
      var steps: Double
      var leaps: Double
    }
    struct StatsJSON: Decodable {
      var repeats: Double
      var steps: Double
      var stepsOfMoves: Double
      var pitch: Pitch
    }
    struct Table: Decodable {
      var songs: Int
      var notes: Int
      var bigrams: Int
      var unigram: [Double]
      var next: [[Double]]
      var moves: [[Double]]
      var counts: [[Int]]
      var stats: StatsJSON
    }
    var provenance: Provenance
    var degrees: [String]
    var tables: [String: Table]
  }

  struct Parsed {
    var provenance: File.Provenance
    var tables: [String: MelodyBigrams]
  }

  /// Rounding to 4 decimals leaves a row at most 7 × 0.00005 off 1.
  static let rowTolerance = 1e-3

  static func parse(_ data: Data) throws -> Parsed {
    let f = try JSONDecoder().decode(File.self, from: data)
    func bad(_ why: String) -> Error {
      CocoaError(
        .fileReadCorruptFile,
        userInfo: [NSDebugDescriptionErrorKey: "melody-bigrams.json: \(why)"])
    }
    guard f.degrees == (1...degrees).map(String.init) else { throw bad("degrees \(f.degrees)") }
    func square<T>(_ m: [[T]]) -> Bool {
      m.count == degrees && m.allSatisfy { $0.count == degrees }
    }
    func stochastic(_ m: [[Double]]) -> Bool {
      m.allSatisfy { row in
        row.allSatisfy { $0 >= 0 } && abs(row.reduce(0, +) - 1) <= rowTolerance
      }
    }
    var out: [String: MelodyBigrams] = [:]
    for (name, t) in f.tables {
      guard square(t.next), square(t.moves), square(t.counts), t.unigram.count == degrees,
        stochastic(t.next), stochastic(t.moves),
        (0..<degrees).allSatisfy({ t.moves[$0][$0] == 0 }),
        t.counts.joined().reduce(0, +) == t.bigrams
      else { throw bad(name) }
      out[name] = MelodyBigrams(
        name: name, songs: t.songs, bigrams: t.bigrams, unigram: t.unigram, next: t.next,
        moves: t.moves, counts: t.counts,
        stats: Stats(
          repeats: t.stats.repeats, steps: t.stats.steps, stepsOfMoves: t.stats.stepsOfMoves,
          pitchRepeats: t.stats.pitch.repeats, pitchSteps: t.stats.pitch.steps,
          pitchLeaps: t.stats.pitch.leaps))
    }
    return Parsed(provenance: f.provenance, tables: out)
  }
}
