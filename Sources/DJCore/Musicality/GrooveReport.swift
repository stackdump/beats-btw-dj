import Foundation

/// One onset as the runner played it (`WaveOptions.onHit`): sample-exact, after the groove
/// (`DJMusicality.Fixes.groove`) held it back and humanize moved its velocity.
public struct HitRecord: Sendable, Equatable {
  /// The sample it plays on, counted like the render's frames (`process`'s `startFrame`).
  public var frame: Int64
  /// The sample of its tick: where it would have played straight. `frame - gridFrame` is how
  /// late the groove played it.
  public var gridFrame: Int64
  /// The graph's tick after the fire (1-based, as `NoteEvent.tick`); a tick is a sixteenth.
  public var tick: Int
  public var net: String
  public var note: Int
  /// The lane's MIDI channel (-1 for none).
  public var channel: Int
  /// The lane's kind (`kick`, `snare`, `clap`, `hat`, `openhat`, `crash`, `tonal`, `v`).
  public var kind: String
  /// The velocity played (after humanize).
  public var velocity: Int

  public init(
    frame: Int64, gridFrame: Int64, tick: Int, net: String, note: Int, channel: Int,
    kind: String, velocity: Int
  ) {
    self.frame = frame
    self.gridFrame = gridFrame
    self.tick = tick
    self.net = net
    self.note = note
    self.channel = channel
    self.kind = kind
    self.velocity = velocity
  }

  /// The sixteenth of its bar, 0…15.
  public var step: Int { ((tick - 1) % 16 + 16) % 16 }
  public var delayFrames: Int64 { frame - gridFrame }
  /// A drum lane (not a tonal one or a voice override).
  public var isDrum: Bool { kind != "tonal" && kind != "v" }
}

/// Collects a render's `HitRecord`s: `attach` it to the options a runner (or a deck's net
/// source) is made with, render, read `records`. Offline only: it appends to an array on the
/// render thread.
public final class HitLog: @unchecked Sendable {
  public private(set) var records: [HitRecord] = []
  public init() {}

  public func record(_ hit: HitRecord) { records.append(hit) }

  /// Sets `opts.onHit` to record here.
  public func attach(_ opts: inout WaveOptions) {
    opts.onHit = { [self] in record($0) }
  }
}

/// How a render's hits sit against the grid (ROADMAP 6.5, exit M6), from its `HitRecord`s:
/// what the groove (swing, humanize, later a template) did, measured on what played.
public struct GrooveReport: Sendable, Equatable {
  /// One lane kind's hits.
  public struct Voice: Sendable, Equatable {
    public var hits = 0
    /// Mean count of distinct velocities at each of its bar positions (positions it hits at
    /// least twice): 1 = every hit at a position is the same strength.
    public var distinctVelocitiesPerPosition = 0.0
    /// Mean lateness, ms, and its standard deviation.
    public var meanDelayMs = 0.0
    public var sdDelayMs = 0.0
  }

  public var hits = 0
  public var drumHits = 0
  /// `Voice.distinctVelocitiesPerPosition` over every drum (kind, position) hit twice or more.
  public var distinctVelocitiesPerPosition = 0.0
  /// How much of the drums' timing is a fixed pattern by bar position: 1 − the variance of
  /// the delay within a (kind, position) over its total variance. 1 = every bar plays the same
  /// offsets (straight, swing, a template), 0 = the offsets are noise. 1 when nothing moves.
  public var consistency = 1.0
  /// Linn's ratio, measured: where the off-beat sixteenth of a pair starts, as a share of the
  /// pair (0.5 straight, 0.66 triplet), from the mean delay of the odd steps against the even
  /// ones, every hit. nil without hits on both.
  public var swingRatio: Double?
  /// Mean lateness of every hit, ms, and its standard deviation.
  public var microtimingMs = 0.0
  public var microtimingSDMs = 0.0
  public var voices: [String: Voice] = [:]

  public init() {}

  /// `bpm` is the tempo the hits were played at (a tick is 15000 / bpm ms).
  public init(_ records: [HitRecord], sampleRate: Double, bpm: Double) {
    hits = records.count
    guard !records.isEmpty, sampleRate > 0 else { return }
    let msPerFrame = 1000 / sampleRate
    let delays = records.map { Double($0.delayFrames) * msPerFrame }
    (microtimingMs, microtimingSDMs) = Self.meanSD(delays)

    // swing: odd steps against even ones, in pairs of two sixteenths
    var on: [Double] = []
    var off: [Double] = []
    for (r, d) in zip(records, delays) {
      if r.step % 2 == 1 { off.append(d) } else { on.append(d) }
    }
    if !on.isEmpty && !off.isEmpty {
      let pairMs = 2 * 15_000 / (bpm > 0 ? bpm : 120)
      swingRatio = 0.5 + (Self.meanSD(off).0 - Self.meanSD(on).0) / pairMs
    }

    // by kind and position
    struct Cell {
      var delays: [Double] = []
      var velocities: Set<Int> = []
    }
    var cells: [String: [Cell]] = [:]
    for (r, d) in zip(records, delays) {
      cells[r.kind, default: [Cell](repeating: Cell(), count: 16)][r.step].delays.append(d)
      cells[r.kind]![r.step].velocities.insert(r.velocity)
    }
    var drumDistinct: [Double] = []
    var drumDelays: [Double] = []
    var within = 0.0
    for (kind, row) in cells {
      var v = Voice()
      var distinct: [Double] = []
      var all: [Double] = []
      for c in row where !c.delays.isEmpty {
        all += c.delays
        if c.delays.count >= 2 { distinct.append(Double(c.velocities.count)) }
      }
      v.hits = all.count
      v.distinctVelocitiesPerPosition =
        distinct.isEmpty ? 0 : distinct.reduce(0, +) / Double(distinct.count)
      (v.meanDelayMs, v.sdDelayMs) = Self.meanSD(all)
      voices[kind] = v
      guard kind != "tonal" && kind != "v" else { continue }
      drumHits += all.count
      drumDistinct += distinct
      drumDelays += all
      for c in row where c.delays.count >= 2 {
        let m = Self.meanSD(c.delays).0
        within += c.delays.reduce(0) { $0 + ($1 - m) * ($1 - m) }
      }
    }
    if !drumDistinct.isEmpty {
      distinctVelocitiesPerPosition = drumDistinct.reduce(0, +) / Double(drumDistinct.count)
    }
    let m = Self.meanSD(drumDelays).0
    let total = drumDelays.reduce(0) { $0 + ($1 - m) * ($1 - m) }
    // below (1 µs)² per hit nothing moved
    if total > 1e-6 * Double(max(1, drumDelays.count)) { consistency = max(0, 1 - within / total) }
  }

  static func meanSD(_ x: [Double]) -> (Double, Double) {
    guard !x.isEmpty else { return (0, 0) }
    let m = x.reduce(0, +) / Double(x.count)
    let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    return (m, v.squareRoot())
  }

  /// For JSON (`djctl render`'s `groove` block), rounded to 3 places.
  public var dictionary: [String: Any] {
    var d: [String: Any] = [
      "hits": hits, "drumHits": drumHits,
      "distinctVelocitiesPerPosition": round3(distinctVelocitiesPerPosition),
      "consistency": round3(consistency), "microtimingMs": round3(microtimingMs),
      "microtimingSDMs": round3(microtimingSDMs),
    ]
    if let swingRatio { d["swingRatio"] = (swingRatio * 10_000).rounded() / 10_000 }
    d["voices"] = voices.mapValues {
      [
        "hits": $0.hits, "distinctVelocitiesPerPosition": round3($0.distinctVelocitiesPerPosition),
        "meanDelayMs": round3($0.meanDelayMs), "sdDelayMs": round3($0.sdDelayMs),
      ] as [String: Any]
    }
    return d
  }
}
