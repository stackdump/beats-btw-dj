import Testing

@testable import DJCore

// The load-time bounds (150 ms, 1 s) are the acceptance for the app, which ships optimised: a
// debug build renders the probes 6 to 30 times slower (6 s for six lanes, measured), so there
// they would fail without saying anything. `make swift-rt-test-filter` checks them.
#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

/// Each sampled instrument's part levels, measured at load (`SamplerPartLevels`): General MIDI
/// programs, which every Mac has and which render the same every time.
struct SamplerPartLevelTests {
  let sr = 48_000.0
  /// Piano, fingered bass, strings, square lead, a pad.
  let programs = [0, 33, 48, 80, 89]

  func coldBank() -> SamplerBank { SamplerBank(sampleRate: sr, partLevelCache: nil) }

  @Test func everyPartIsMeasuredAndFinite() throws {
    let bank = coldBank()
    for p in programs {
      let slot = try #require(bank.slot(for: [.gm(p)]))
      let levels = bank.slotPartLevelDB(slot)
      #expect(Set(levels.keys) == Set(SamplerPartLevels.groups), "gm \(p): \(levels)")
      for (g, l) in levels {
        #expect(l.isFinite && abs(l) < 60, "gm \(p) \(g): \(l) dB")
      }
      print(
        "gm \(p):",
        levels.sorted { $0.key < $1.key }.map { "\($0.key) \(partLevelFormat("%+.1f", $0.value))" })
    }
  }

  @Test func measurementsAreDeterministic() throws {
    for p in programs {
      let a = coldBank()
      let b = coldBank()
      let sa = try #require(a.slot(for: [.gm(p)]))
      let sb = try #require(b.slot(for: [.gm(p)]))
      for g in SamplerPartLevels.groups {
        let la = try #require(a.slotPartLevelDB(sa, group: g))
        let lb = try #require(b.slotPartLevelDB(sb, group: g))
        #expect(abs(la - lb) <= 0.1, "gm \(p) \(g): \(la) vs \(lb)")
      }
    }
  }

  @Test func groupsWithoutAProbeTakeTheNearest() throws {
    let bank = coldBank()
    let slot = try #require(bank.slot(for: [.gm(48)]))
    #expect(
      bank.slotPartLevelDB(slot, group: "pad") == bank.slotPartLevelDB(slot, group: "harmony"))
    #expect(
      bank.slotPartLevelDB(slot, group: "lead") == bank.slotPartLevelDB(slot, group: "melody"))
    #expect(bank.slotPartLevelDB(slot + 1, group: "melody") == nil, "an empty slot")
    #expect(bank.slotPartLevelDB(-1, group: "melody") == nil)
  }

  @Test func kitsAndSkippedProbesMeasureNothing() throws {
    let bank = coldBank()
    bank.measuresPartLevels = false
    let slot = try #require(bank.slot(for: [.gm(0)]))
    #expect(bank.slotPartLevelDB(slot).isEmpty)
    #expect(
      SamplerPartLevels.cacheKey(.kit("/x.sf2", bank: 128, program: 0), sampleRate: sr) == nil)
  }

  /// Warm loads read the cache and land on the same levels; the file outlives the bank.
  @Test func theCacheRoundTrips() throws {
    let cache = tempPartLevelCache()
    defer { removePartLevelCache(cache) }
    let cold = SamplerBank(sampleRate: sr, partLevelCache: cache)
    let s1 = try #require(cold.slot(for: [.gm(33)]))
    let first = cold.slotPartLevelDB(s1)
    let key = try #require(SamplerPartLevels.cacheKey(.gm(33), sampleRate: sr))
    #expect(cache.levels(for: key) != nil)
    let reread = SamplerPartLevels.Cache(url: cache.url)
    #expect(reread.levels(for: key) == cache.levels(for: key))
    let warm = SamplerBank(sampleRate: sr, partLevelCache: reread)
    let s2 = try #require(warm.slot(for: [.gm(33)]))
    for g in SamplerPartLevels.groups {
      #expect(abs(first[g]! - warm.slotPartLevelDB(s2, group: g)!) <= 0.1, "\(g)")
    }
    #expect(
      SamplerPartLevels.cacheKey(.gm(33), sampleRate: 44_100) != key, "keyed by rate")
  }

  /// The probes add at most 150 ms to a load (cold cache; median of five).
  @Test(.enabled(if: optimized, "load times are only meaningful in optimized builds"))
  func probesAddLittleToALoad() throws {
    func loadSeconds(probes: Bool, program: Int) -> Double {
      let bank = coldBank()
      bank.measuresPartLevels = probes
      return secondsTaken { _ = bank.slot(for: [.gm(program)]) }
    }
    _ = SamplerPartLevels.groups.map { SamplerPartLevels.synthLevelDB(group: $0, sampleRate: sr) }
    var added: [Double] = []
    for p in programs {
      let without = loadSeconds(probes: false, program: p)
      let with = loadSeconds(probes: true, program: p)
      added.append(with - without)
    }
    let median = added.sorted()[added.count / 2]
    print("probes add", added.map { partLevelFormat("%.0f ms", $0 * 1000) })
    #expect(median <= 0.15, "median \(median * 1000) ms")
  }

  /// A track with six sampled lanes adds at most a second to its prepare, cold cache (the
  /// synth reference included).
  @Test func sixSampledLanesAddUnderASecond() throws {
    var insts: [SamplerInstrument] = []
    for p in [0, 25, 33, 48, 73, 89] {
      let i = try SamplerInstrument.lifecycle.withLock {
        try SamplerInstrument(source: .gm(p), sampleRate: 44_100)
      }
      i.normalize(sampleRate: 44_100)
      insts.append(i)
    }
    let seconds = secondsTaken {
      for i in insts { i.measurePartLevels(sampleRate: 44_100, cache: nil) }
    }
    print(partLevelFormat("six lanes: %.0f ms", seconds * 1000))
    if optimized { #expect(seconds <= 1, "\(seconds) s") }
    for i in insts { #expect(i.partLevelDB.count == SamplerPartLevels.groups.count) }
  }
}
