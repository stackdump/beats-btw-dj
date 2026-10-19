import Foundation

/// The mix targets the musicality fixes aim at (ROADMAP 6.1), as data that names its source:
/// `Resources/beats/targets.json`. Per part, genre or family each number carries a `source`
/// (`"rule-of-thumb (pre-6.1)"` until a measurement replaces it) and, where a reference corpus
/// gives one, a `band` (the range it should fall in). `Loudness`, `MixBalance`, `SpaceSpec` and
/// `DJMusicality.stereoPlacement` and `HFTilt` read their numbers from here.
///
/// Hand-edited, not generated (`make beats-tables` writes only `tables.json`). Loaded once
/// (`shared`, a static let) at prepare: never touch it first on the audio thread.
public struct MixTargets: Sendable {
  /// A number and where it came from; `band` is `[low, high]` when there is one.
  public struct Target: Decodable, Equatable, Sendable {
    public var value: Double?
    public var band: [Double]?
    public var source: String

    public var range: ClosedRange<Double>? {
      guard let band, band.count == 2, band[0] <= band[1] else { return nil }
      return band[0]...band[1]
    }
  }

  public struct GainRange: Decodable, Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var source: String
  }

  public struct Level: Decodable, Equatable, Sendable {
    /// What the probe's two bars read under a whole track's integrated loudness:
    /// `Loudness.targetDB` = `LevelMatch.referenceLUFS` + this.
    public var probeOffsetDB: Target
    public var gainRange: GainRange
  }

  public struct Balance: Decodable, Equatable, Sendable {
    /// Each part's level against the others (`MixBalance.parts`), K-weighted dB.
    public var `default`: [String: Target]
    /// Per-family overrides of single parts (`chill`'s, ROADMAP 6.6; `MixBalance.entry(family:)`
    /// says which a family uses).
    public var families: [String: [String: Target]]
    public var maxTrimDB: Target
  }

  public struct Room: Decodable, Equatable, Sendable {
    public var seconds: Double
    public var wet: Double
    public var damping: Double
    public var source: String
    /// What this room's return measured against the dry mix (`djctl render <g> 42 --synth
    /// --room`'s `roomReturnDB`), dB; nil = not measured (its family's band cannot move it).
    public var returnDB: Target?

    public var spec: SpaceSpec { SpaceSpec(seconds: seconds, wet: wet, damping: damping) }
  }

  /// A family's room settings (6.6): the band its return should land in and the pad shimmer.
  public struct FamilyRoom: Decodable, Equatable, Sendable {
    /// The room return against the dry mix, dB: `band` from references; empty until measured.
    public var returnDB: Target?
    /// The pad shimmer's level (`.shimmer`, `Shimmer`): its octave-up path into the room.
    public var shimmer: Target?
  }

  public struct Rooms: Decodable, Equatable, Sendable {
    public var `default`: Room
    public var genres: [String: Room]
    /// Each lane's send to the room (`SpaceSpec.send`), keyed by drum kind or tonal group
    /// (`tonal`: any other tonal group; `sampler`: the sampled instruments' bus).
    public var sends: [String: Target]?
    /// By family name (`GrooveTemplate.familyNames`).
    public var families: [String: FamilyRoom]?
  }

  /// A lane's place in the field (`stereoPlacement`), keyed by drum kind or tonal group.
  public struct Placement: Decodable, Equatable, Sendable {
    public var pan: Double
    public var spread: Double
    public var source: String
  }

  public var loudness: Level
  public var balance: Balance
  public var space: Rooms
  public var stereo: [String: Placement]
  /// Reference bands per metric (`lufs`, `lra`, `truePeak`, `slope`, `side`) and family, to be
  /// filled from a reference corpus; empty (a source, no value) until then.
  public var bands: [String: [String: Target]]
  /// `.hfTilt`'s lowpass on the bright drum voices (`HFTilt`), Hz, by family, with a
  /// `default` for a family that has none.
  public var hfTilt: [String: Target]

  public static let metrics = ["lufs", "lra", "truePeak", "slope", "side"]

  // MARK: lookups (off the audio thread)

  /// The balance targets for a family (`BeatsTables.family(of:)`'s name): the default, with the
  /// family's overrides.
  public func balanceDB(family: String? = nil) -> [String: Double] {
    var out = balance.default.compactMapValues(\.value)
    if let family, let o = balance.families[family] {
      for (k, t) in o { if let v = t.value { out[k] = v } }
    }
    return out
  }

  /// A genre's room, else the default one. When its family has a return band (6.1's
  /// references) and the room a measured `returnDB`, its `wet` is scaled so the return lands in
  /// the band (the return is linear in `wet`: ×k is +20·log10 k dB); else as the table has it.
  public func room(genre: String) -> SpaceSpec {
    let r = space.genres[genre] ?? space.default
    var spec = r.spec
    if let band = space.families?[Self.familyName(genre)]?.returnDB?.range,
      let measured = r.returnDB?.value
    {
      let to = min(max(measured, band.lowerBound), band.upperBound)
      if to != measured { spec.wet *= pow(10, (to - measured) / 20) }
    }
    return spec
  }

  /// The pad shimmer's level for a genre's family (`.shimmer`); 0 = none.
  public func shimmer(genre: String) -> Double {
    max(0, space.families?[Self.familyName(genre)]?.shimmer?.value ?? 0)
  }

  /// How much of itself a lane sends to the room, from `space.sends` (by drum kind, or, tonal, by
  /// group, then `tonal`); nil when the table has no entry.
  public func send(kind: String, group: String) -> Double? {
    guard let sends = space.sends else { return nil }
    if kind == "tonal" { return (sends[group] ?? sends["tonal"])?.value }
    return sends[kind]?.value
  }

  /// `BeatsTables.family(of:)`'s name for a genre.
  static func familyName(_ genre: String) -> String {
    let i = BeatsTables.shared.family(of: genre)
    let names = GrooveTemplate.familyNames
    return names.indices.contains(i) ? names[i] : names[1]
  }

  /// Where a lane sits: by its drum kind, or, tonal, by its group; centred otherwise.
  public func placement(kind: String, group: String) -> (pan: Double, spread: Double) {
    let key = kind == "tonal" ? group : kind
    guard let p = stereo[key] else { return (0, 0) }
    return (p.pan, p.spread)
  }

  /// The band for `metric` in `family`, when one has been measured.
  public func band(_ metric: String, family: String) -> ClosedRange<Double>? {
    bands[metric]?[family]?.range
  }

  /// The integrated loudness (LUFS) a family's tracks are brought to (ROADMAP 6.6): the middle
  /// of its `lufs` band once the reference corpus has measured one, else the app's single
  /// reference, `LevelMatch.referenceLUFS`. Every band is empty so far, so every family plays
  /// at −12: one level is what a crossfade between two families needs (a level jump at the
  /// fader is the thing 6.6 removes), and a per-family target only replaces it with numbers.
  public func integratedLUFS(family: String?) -> Double {
    guard let family, let r = band("lufs", family: family) else { return LevelMatch.referenceLUFS }
    return (r.lowerBound + r.upperBound) / 2
  }

  /// `.hfTilt`'s cutoff for `family`, else the default's.
  public func hfTiltHz(family: String) -> Double? {
    hfTilt[family]?.value ?? hfTilt["default"]?.value
  }

  /// What the mix's long-term slope (`Spectrum.slopeDBPerOct`) should fall in for `family`: the
  /// measured band when the corpus gives one, else research M7's rule of thumb (falling: −6 …
  /// −1 dB/oct; realism-2026-10.md).
  public func slopeBand(family: String) -> ClosedRange<Double> {
    band("slope", family: family) ?? Self.slopeRuleOfThumb
  }

  /// [RULE-OF-THUMB] M7: a falling slope (mastered records sit about −2.5 … −4.5 dB/oct).
  public static let slopeRuleOfThumb: ClosedRange<Double> = -6 ... -1
  /// [RULE-OF-THUMB] M7: "no HF bump": 12.5 / 16 kHz at most this far over the slope's fit.
  public static let maxHFBumpDB = 2.0

  // MARK: table

  public static let shared: MixTargets = {
    do { return try parse(Data(loadText().utf8)) } catch { fatalError("mix targets: \(error)") }
  }()

  static func loadText() throws -> String {
    // In DJApp.app the tables sit in Contents/Resources/beats (scripts/bundle-app.sh).
    guard
      let url = Bundle.main.url(
        forResource: "targets", withExtension: "json", subdirectory: "beats")
        ?? Bundle.module.url(forResource: "targets", withExtension: "json", subdirectory: "beats")
    else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "beats/targets.json"]) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  struct File: Decodable {
    var loudness: Level
    var balance: Balance
    var space: Rooms
    var stereo: [String: Placement]
    var bands: [String: [String: Target]]
    var hfTilt: [String: Target]
  }

  static func parse(_ data: Data) throws -> MixTargets {
    let f = try JSONDecoder().decode(File.self, from: data)
    func bad(_ why: String) -> Error {
      CocoaError(
        .fileReadCorruptFile, userInfo: [NSDebugDescriptionErrorKey: "targets.json: \(why)"])
    }
    guard f.loudness.probeOffsetDB.value != nil else { throw bad("loudness.probeOffsetDB") }
    guard f.loudness.gainRange.min > 0, f.loudness.gainRange.min <= f.loudness.gainRange.max
    else { throw bad("loudness.gainRange") }
    for part in MixBalance.parts where f.balance.default[part]?.value == nil {
      throw bad("balance.default.\(part)")
    }
    guard f.balance.maxTrimDB.value != nil else { throw bad("balance.maxTrimDB") }
    for (name, t) in f.bands.values.flatMap(\.self) where t.band != nil && t.range == nil {
      throw bad("bands \(name)")
    }
    guard let hz = f.hfTilt["default"]?.value, hz > 0 else { throw bad("hfTilt.default") }
    for (name, t) in f.hfTilt where !(t.value.map { $0 > 0 } ?? true) {
      throw bad("hfTilt.\(name)")
    }
    for (name, fam) in f.space.families ?? [:] {
      if let t = fam.returnDB, t.band != nil, t.range == nil { throw bad("space.families.\(name)") }
    }
    return MixTargets(
      loudness: f.loudness, balance: f.balance, space: f.space, stereo: f.stereo, bands: f.bands,
      hfTilt: f.hfTilt)
  }
}
