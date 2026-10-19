import Testing

@testable import DJCore

// Exit M7 (ROADMAP 6.6): crossfade without a level jump. Whole songs of twelve genres (seed 42,
// standard structure) as a deck plays them, on synth voices and on the deck's own samplers,
// land within `LevelMatch.maxSpreadLU` of each other; a centred A→B crossfade lands within
// `LevelMatch.crossfadeToleranceLU` of either deck alone. The integrated target is the family's
// `lufs` band (`MixTargets.integratedLUFS`) once measured; all bands are empty, so one target,
// `LevelMatch.referenceLUFS`. Slow (24 whole songs, debug builds far longer): run it alone,
// `make swift-test-filter FILTER=LoudnessSpreadTests`.

private let rate = 24_000.0
private let seed: Double = 42

/// The genres the matrix plays: the level surveys' twelve (`LevelMatchTests`).
private let spreadGenres = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz", "funk",
  "bossa", "country",
]

private func lufs(_ l: [Float], _ r: [Float]) -> Double? {
  IntegratedLoudness.integrated(left: l, right: r, sampleRate: rate)
}

private func f1(_ x: Double) -> String { String(format: "%.1f", x) }

/// A whole song as a net deck plays it: synth voices (`.extended`), or, with `bank`, its parts on
/// the deck's samplers.
private func song(_ genre: String, bank: SamplerBank? = nil) -> (OfflineRender, PreparedTrack) {
  let opts = bank.map { WaveOptions.extended(samplers: $0, seed: seed) } ?? .extended
  let source = WaveDeckSource(sampleRate: rate, opts: opts)
  let track = PreparedTrack(
    spec: TrackSpec(genre: genre, seed: seed, structure: "standard"), sampleRate: rate, opts: opts)
  return (OfflineRender(track: track, source: source, seconds: 400), track)
}

/// Every genre's integrated loudness on one path, printed (the numbers a tuning goes by), and
/// its spread (max − min, LU). The genres render on threads of their own (`parallelMap`, four at
/// a time: a sampled song holds its bank), so the matrix is not a full debug run's last hour.
private func matrix(sampled: Bool) -> (levels: [String: Double], spread: Double) {
  var levels: [String: Double] = [:]
  let path = sampled ? "sampled" : "synth"
  let measured = parallelMap(spreadGenres, width: 4) { genre -> (Double?, String) in
    let cache = tempPartLevelCache()
    defer { removePartLevelCache(cache) }
    let bank = sampled ? SamplerBank(sampleRate: rate, partLevelCache: cache) : nil
    let (r, track) = song(genre, bank: bank)
    let l = lufs(r.left, r.right)
    return (
      l,
      "gain \(f1(ampDB(track.prepared.gain))) dB, peak \(f1(r.metrics.peakDB)) dBFS"
    )
  }
  for (genre, (l, detail)) in zip(spreadGenres, measured) {
    guard let l else {
      Issue.record("\(path) \(genre): silent")
      continue
    }
    levels[genre] = l
    print(
      "LoudnessSpread \(path) \(genre.padding(toLength: 10, withPad: " ", startingAt: 0)) "
        + "\(f1(l)) LUFS (target \(f1(LevelMatch.targetLUFS(genre: genre)))), \(detail)")
  }
  let spread = (levels.values.max() ?? 0) - (levels.values.min() ?? 0)
  print("LoudnessSpread \(path): spread \(f1(spread)) LU over \(levels.count)")
  return (levels, spread)
}

@Suite(.serialized) struct LoudnessSpreadTests {
  /// One target while the reference bands are empty: every family's is the app's reference,
  /// and the probe aims at it (the deck's gain is unchanged by the per-family lookup).
  @Test func everyFamilyTakesTheSingleReferenceUntilItsBandIsMeasured() {
    for genre in spreadGenres + [nil] {
      let family = MixBalance.family(genre: genre)
      if genre != nil { #expect(family != nil, "\(genre ?? "nil")") }
      if let family { #expect(MixTargets.shared.band("lufs", family: family) == nil) }
      #expect(LevelMatch.targetLUFS(genre: genre) == LevelMatch.referenceLUFS)
      #expect(Loudness.targetDB(genre: genre) == Loudness.targetDB)
    }
  }

  /// A measured band moves its family's target to the band's middle; the others keep the
  /// reference.
  @Test func aMeasuredBandSetsItsFamilysTarget() throws {
    var t = MixTargets.shared
    t.bands["lufs"]?["chill"] = MixTargets.Target(value: nil, band: [-14, -12], source: "test")
    #expect(t.integratedLUFS(family: "chill") == -13)
    #expect(t.integratedLUFS(family: "dance") == LevelMatch.referenceLUFS)
    #expect(t.integratedLUFS(family: nil) == LevelMatch.referenceLUFS)
    #expect(MixBalance.family(genre: "techno") == "dance")
  }

  @Test func synthSongsSpreadWithinTwoLU() {
    let (levels, spread) = matrix(sampled: false)
    #expect(levels.count == spreadGenres.count)
    #expect(spread <= LevelMatch.maxSpreadLU, "synth LUFS spread \(spread) LU: \(levels)")
  }

  @Test func sampledSongsSpreadWithinTwoLU() {
    let (levels, spread) = matrix(sampled: true)
    #expect(levels.count == spreadGenres.count)
    #expect(spread <= LevelMatch.maxSpreadLU, "sampled LUFS spread \(spread) LU: \(levels)")
  }

  /// A dance track on A, a chill one on B (the families farthest apart before `.loudness`),
  /// unity knobs, mixed through the crossfader's own gains (`DJEngine.crossfadeGain`): at the
  /// centre the mix reads within 1 LU of A alone (fader at A) and of B alone (fader at B).
  @MainActor
  @Test func aCentredCrossfadeKeepsTheLevel() throws {
    let (a, _) = song("techno")
    let (b, _) = song("lofi")
    let n = min(a.left.count, b.left.count)
    try #require(n > Int(rate * 30))
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    func mix(at x: Double) -> (l: [Float], r: [Float]) {
      dj.crossfader = x
      let ga = Float(dj.crossfadeGain("A"))
      let gb = Float(dj.crossfadeGain("B"))
      var l = [Float](repeating: 0, count: n)
      var r = [Float](repeating: 0, count: n)
      for i in 0..<n {
        l[i] = ga * a.left[i] + gb * b.left[i]
        r[i] = ga * a.right[i] + gb * b.right[i]
      }
      return (l, r)
    }
    let onA = mix(at: 0)
    let onB = mix(at: 1)
    let centre = mix(at: 0.5)
    let la = try #require(lufs(onA.l, onA.r))
    let lb = try #require(lufs(onB.l, onB.r))
    let lc = try #require(lufs(centre.l, centre.r))
    print("LoudnessSpread crossfade: A \(f1(la)), B \(f1(lb)), centre \(f1(lc)) LUFS")
    #expect(abs(lc - la) <= LevelMatch.crossfadeToleranceLU, "centre \(lc) vs A \(la)")
    #expect(abs(lc - lb) <= LevelMatch.crossfadeToleranceLU, "centre \(lc) vs B \(lb)")
  }
}
