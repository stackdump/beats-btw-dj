import Testing

@testable import DJCore

// `.arpDensity` (p64-arp-density): the arp's rate follows the melody's onset density bar by
// bar (busy → sixteenths, sparse → eighths, rest → quarters), the section's energy where no
// melody plays, a step busier into each phrase's fourth bar and through buildups. Bars an arp
// slot leaves silent stay silent; every note is still the bar's chord.

private let genres = ["trance", "edm", "synthwave"]
private let seeds: [Double] = [7, 42, 99]

private func played(_ genre: String, _ seed: Double, fixes: DJMusicality.Fixes = .all)
  -> Project
{
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  return DJMusicality.apply(spec.project(), spec: spec, fixes: fixes)
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

/// Distinct onset ticks of `group` in each song bar it plays in.
private func onsetsByBar(_ p: Project, _ group: String) -> [Int: Int] {
  let ticks = Set(NoteLog.capture(p).filter { $0.group == group }.map(\.tick))
  var out: [Int: Int] = [:]
  for t in ticks { out[(t - 1) / 16, default: 0] += 1 }
  return out
}

/// The section name each song bar falls in.
private func sectionOfBar(_ p: Project) -> [Int: String] {
  var out: [Int: String] = [:]
  var at = 0
  for s in p.structure {
    for b in stride(from: at, to: at + s.steps, by: 16) { out[b / 16] = s.name }
    at += s.steps
  }
  return out
}

private func pearson(_ xs: [Double], _ ys: [Double]) -> Double? {
  guard xs.count == ys.count, xs.count > 2 else { return nil }
  let n = Double(xs.count)
  let mx = xs.reduce(0, +) / n
  let my = ys.reduce(0, +) / n
  var sxy = 0.0
  var sxx = 0.0
  var syy = 0.0
  for (x, y) in zip(xs, ys) {
    sxy += (x - mx) * (y - my)
    sxx += (x - mx) * (x - mx)
    syy += (y - my) * (y - my)
  }
  guard sxx > 0, syy > 0 else { return 0 }
  return sxy / (sxx * syy).squareRoot()
}

/// Pooled over every song: (melody onsets, arp notes) in each bar where both play.
private func pairs(fixes: DJMusicality.Fixes) -> (melody: [Double], arp: [Double]) {
  var xs: [Double] = []
  var ys: [Double] = []
  for genre in genres {
    for seed in seeds {
      let p = played(genre, seed, fixes: fixes)
      let melody = onsetsByBar(p, "melody")
      for (bar, n) in onsetsByBar(p, "arp").sorted(by: { $0.key < $1.key }) {
        guard let m = melody[bar] else { continue }
        xs.append(Double(m))
        ys.append(Double(n))
      }
    }
  }
  return (xs, ys)
}

struct ArpDensityTests {
  /// With the flag the arp's notes per bar follow the melody's onsets (r ≥ 0.5); without it
  /// the figure keeps one rate and the two are unrelated (|r| < 0.2).
  @Test func arpRateFollowsTheMelodysDensity() throws {
    let on = pairs(fixes: .all)
    let off = pairs(fixes: .all.subtracting(.arpDensity))
    let rOn = try #require(pearson(on.melody, on.arp))
    let rOff = try #require(pearson(off.melody, off.arp))
    #expect(rOn >= 0.5, "r = \(rOn) over \(on.arp.count) bars with .arpDensity")
    #expect(abs(rOff) < 0.2, "r = \(rOff) over \(off.arp.count) bars without")
  }

  /// Buildups get busier: with the flag a buildup's arp plays at least as many notes a bar as
  /// the rest of the song's arp, and more than it did without the flag somewhere. "Buildup" is
  /// `EnergyCurve.rampSections` (buildup, pre-chorus), as `arpDensityRates` reads it: these
  /// genres' composer brings the arp in at the drop / chorus, so of the songs here only a
  /// synthwave pre-chorus (seed 99) has an arp in a ramp section.
  @Test func buildupsGetBusier() {
    var busier = 0
    var checked = 0
    for genre in genres {
      for seed in seeds {
        let on = played(genre, seed)
        let off = played(genre, seed, fixes: .all.subtracting(.arpDensity))
        let section = sectionOfBar(on)
        func mean(_ p: Project, buildup: Bool) -> Double? {
          let bars = onsetsByBar(p, "arp").filter {
            EnergyCurve.rampSections.contains(section[$0.key] ?? "") == buildup
          }
          guard !bars.isEmpty else { return nil }
          return Double(bars.values.reduce(0, +)) / Double(bars.count)
        }
        guard let b = mean(on, buildup: true), let rest = mean(on, buildup: false),
          let before = mean(off, buildup: true)
        else { continue }
        checked += 1
        #expect(b >= rest, "\(genre)/\(seed): buildup \(b) a bar, the rest \(rest)")
        if b > before { busier += 1 }
      }
    }
    #expect(checked > 0, "no song with an arp in a buildup")
    #expect(busier > 0, "no buildup got busier")
  }

  /// The arp plays in exactly the bars it did (silent slot bars stay silent), on the chord.
  @Test(arguments: genres)
  func silentBarsStaySilentAndNotesKeepTheChord(genre: String) throws {
    for seed in seeds {
      let on = played(genre, seed)
      let off = played(genre, seed, fixes: .all.subtracting(.arpDensity))
      #expect(
        Set(onsetsByBar(on, "arp").keys) == Set(onsetsByBar(off, "arp").keys), "\(genre)/\(seed)")
      #expect(try #require(report(on).arpChordTones) == 1, "\(genre)/\(seed)")
    }
  }

  /// Every rate is one of the three levels, and the rates vary within a song — unless the
  /// melody is busy (`arpBusyOnsets`) in every bar the arp plays outside a phrase's fourth bar,
  /// where the rule itself says sixteenths throughout (edm: the composer's drop melody has five
  /// or more onsets in each of those bars, for every seed here).
  @Test func ratesAreQuartersEighthsOrSixteenths() {
    var pooled = Set<Int>()
    for genre in genres {
      let spec = TrackSpec(genre: genre, seed: 42, structure: "standard")
      let p = DJMusicality.apply(
        spec.project(), spec: spec, fixes: .all.subtracting([.arpeggio, .arpDensity]))
      let rates = DJMusicality.arpDensityRates(p, seed: 42, genre: genre)
      let all = rates.values.flatMap(\.values)
      #expect(!all.isEmpty, "\(genre): no arp rates")
      #expect(all.allSatisfy { DJMusicality.arpDensityLevels.contains($0) }, "\(genre)")
      pooled.formUnion(all)
      if Set(all).count == 1 {
        let melody = DJMusicality.melodyOnsetsByBar(p)
        var starts: [Int] = []
        var at = 0
        for s in p.structure {
          starts.append(at)
          at += s.steps
        }
        let calm = DJMusicality.slotWindows(p, role: "arp").values.joined().flatMap { w in
          stride(from: w.start, to: w.end, by: 16).filter { step in
            (step - starts[w.section]) / 16 % 4 != 3
              && !EnergyCurve.rampSections.contains(w.sectionName)
              && (melody[step / 16] ?? 0) < DJMusicality.arpBusyOnsets
          }
        }
        #expect(
          all.first == DJMusicality.arpDensityLevels.last && calm.isEmpty,
          "\(genre): one rate everywhere \(Set(all)), calm bars \(calm.map { $0 / 16 })")
      }
    }
    #expect(pooled.count > 1, "one rate in every genre \(pooled)")
  }

  /// The direction lives in one constant and follows the melody; levels run sparse to busy.
  @Test func directionIsOneConstant() {
    #expect(DJMusicality.arpDensityDirection == 1)
    #expect(DJMusicality.arpDensityLevels == [4, 2, 1])
  }

  /// Without `.arpeggio` the flag does nothing; it is in `Fixes.all` and named.
  @Test func needsArpeggioAndIsListed() {
    let a = played("trance", 42, fixes: .all.subtracting(.arpeggio))
    let b = played("trance", 42, fixes: .all.subtracting([.arpeggio, .arpDensity]))
    #expect(a.canonicalJSON == b.canonicalJSON)
    #expect(DJMusicality.Fixes.all.contains(.arpDensity))
    #expect(DJMusicality.Fixes.named["arpDensity"] == .arpDensity)
  }
}
