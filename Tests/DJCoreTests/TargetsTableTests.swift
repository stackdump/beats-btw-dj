import Testing

@testable import DJCore

// Mix targets as data (ROADMAP 6.1): Resources/beats/targets.json, read by MixTargets. The
// table started as the constants the code held; these hold it to them exactly (a JSON Double
// that rounds differently would move a render), name a source for every number, and keep the
// reference bands' slots in place for the corpus to fill.

@Suite struct TargetsTableTests {
  static let preSixOne = "rule-of-thumb (pre-6.1)"

  @Test func loudnessIsTheCalibratedConstant() {
    #expect(Loudness.targetDB == LevelMatch.referenceLUFS - 0.4)
    #expect(Loudness.range.min == 0.25)
    #expect(Loudness.range.max == 8.0)
    #expect(!MixTargets.shared.loudness.probeOffsetDB.source.isEmpty)
  }

  @Test func balanceIsTheRuleOfThumb() {
    let old: [String: Double] = [
      "kick": 0, "bass": -3, "lead": -4, "snare": -6, "pad": -7, "arp": -8, "hats": -10,
    ]
    #expect(MixBalance.targetDB == old)
    #expect(Set(MixBalance.targetDB.keys) == Set(MixBalance.parts))
    #expect(MixBalance.maxTrimDB == 6.0)
    #expect(MixTargets.shared.balanceDB(family: "dance") == old)
    for (part, t) in MixTargets.shared.balance.default {
      #expect(t.source.hasPrefix(Self.preSixOne), "\(part)")
    }
  }

  @Test func roomsAreTheRuleOfThumb() {
    func old(_ name: String) -> SpaceSpec {
      switch name {
      case "ambient": SpaceSpec(seconds: 4.0, wet: 0.27, damping: 5000)
      case "trance", "synthwave": SpaceSpec(seconds: 2.4, wet: 0.45, damping: 7500)
      case "edm": SpaceSpec(seconds: 2.0, wet: 0.38, damping: 7000)
      case "techno", "house", "garage": SpaceSpec(seconds: 1.3, wet: 0.33, damping: 6000)
      case "funk", "disco": SpaceSpec(seconds: 1.0, wet: 0.22, damping: 5500)
      case "lofi": SpaceSpec(seconds: 1.8, wet: 0.16, damping: 3500)
      case "jazz", "bossa": SpaceSpec(seconds: 1.6, wet: 0.19, damping: 4500)
      case "dnb", "dubstep", "trap": SpaceSpec(seconds: 1.6, wet: 0.33, damping: 6500)
      default: SpaceSpec(seconds: 1.5, wet: 0.3, damping: 6000)
      }
    }
    #expect(SpaceSpec.room == old("none"))
    for g in BeatsTables.shared.genreIDs + ["wrapped", "none"] {
      #expect(SpaceSpec.forGenre(g) == old(g), "\(g)")
    }
    for (g, r) in MixTargets.shared.space.genres {
      #expect(r.source.hasPrefix(Self.preSixOne), "\(g)")
      #expect(SpaceSpec.forGenre(g) == old(g), "\(g)")
    }
  }

  @Test func stereoPlacementIsTheRuleOfThumb() {
    func old(_ kind: String, _ group: String) -> (Double, Double) {
      switch kind {
      case "hat", "openhat": return (0.3, 0)
      case "crash": return (-0.3, 0)
      case "tonal":
        switch group {
        case "harmony": return (0, 0.5)
        case "arp": return (0, 0.45)
        default: return (0, 0)
        }
      default: return (0, 0)
      }
    }
    let kinds = ["kick", "snare", "clap", "hat", "openhat", "crash", "tom", "tonal"]
    let groups = ["bass", "harmony", "pad", "melody", "arp", "kick", "hihat", ""]
    for k in kinds {
      for g in groups {
        let now = DJMusicality.stereoPlacement(kind: k, group: g)
        let was = old(k, g)
        #expect(now.pan == was.0 && now.spread == was.1, "\(k) \(g)")
      }
    }
    for (k, p) in MixTargets.shared.stereo { #expect(p.source.hasPrefix(Self.preSixOne), "\(k)") }
  }

  @Test func bandsAreThereAndEmpty() {
    let t = MixTargets.shared
    #expect(Set(t.bands.keys) == Set(MixTargets.metrics))
    for m in MixTargets.metrics {
      #expect(Set(t.bands[m]!.keys) == Set(GrooveTemplate.familyNames), "\(m)")
      for f in GrooveTemplate.familyNames {
        let b = t.bands[m]![f]!
        #expect(b.value == nil && b.band == nil && !b.source.isEmpty, "\(m).\(f)")
        #expect(t.band(m, family: f) == nil)
      }
    }
  }

  @Test func parseRejectsAMissingPart() throws {
    #expect(throws: (any Error).self) { try targetsWithoutBalancePart("hats") }
    // and the untouched file parses to what `shared` holds
    #expect(try targetsTable().balanceDB() == MixTargets.shared.balanceDB())
  }

  /// `make beats-tables` regenerates tables.json only: targets.json is hand-edited data.
  @Test func beatsTablesWritesOnlyTablesJSON() throws {
    let script = try repoText("scripts/beats-tables.mjs")
    #expect(script.contains("beats/tables.json"))
    #expect(!script.contains("targets.json"))
    #expect(!script.contains("grooves.json"))
  }
}
