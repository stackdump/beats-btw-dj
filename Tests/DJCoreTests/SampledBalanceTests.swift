import Darwin
import Testing

@testable import DJCore

// `.balance` reaching sampled parts (`SampledBalance`, ROADMAP 6.6): each sampler slot plays at
// the part's trim less its instrument's measured gap to the synth voice, and `djctl render
// --balance`'s sampled path (`MixBalance.measure(samplers:)`) hears it.

private let sr = 48_000.0

private func track(_ genre: String, _ seed: Double, bank: SamplerBank?, fixes: DJMusicality.Fixes)
  -> PreparedTrack
{
  var o = WaveOptions.extended(samplers: bank)
  o.musicality = fixes
  return PreparedTrack(
    spec: TrackSpec(genre: genre, seed: seed, structure: "minimal"), sampleRate: sr, opts: o)
}

/// The tonal lanes that play a sampler, with their group.
private func sampledLanes(_ p: WaveProject) -> [(lane: Lane, group: String)] {
  p.lanes.compactMap { lane in
    guard lane.kind == "tonal", lane.samplerSlot >= 0, let g = p.sampledGroups[lane.netId]
    else { return nil }
    return (lane, g)
  }
}

private func db(_ x: Double) -> Double { 20 * log10(x) }

struct SampledBalanceTests {
  /// The trim less the gap, clamped; unmeasured, the trim alone. The probe then stands in at
  /// the trimmed synth voice's level unless the clamp left some of the gap.
  @Test func gainIsTheTrimLessTheGapClamped() {
    #expect(SampledBalance.gainDB(trimDB: 3, partLevelDB: -5) == 8)
    #expect(SampledBalance.gainDB(trimDB: -2, partLevelDB: 4) == -6)
    #expect(SampledBalance.gainDB(trimDB: 2, partLevelDB: nil) == 2)
    #expect(SampledBalance.gainDB(trimDB: 6, partLevelDB: -20) == SampledBalance.rangeDB)
    #expect(SampledBalance.gainDB(trimDB: -6, partLevelDB: 20) == -SampledBalance.rangeDB)
    let fit = SampledBalance.probeLevel(trimDB: 3, partLevelDB: -5, group: "bass", gainDB: 8)
    #expect(abs(fit - 1) < 1e-9)
    // clamped at +12 against a 20 dB gap: the sampler sits 8 dB under its trimmed voice
    let short = SampledBalance.probeLevel(trimDB: 0, partLevelDB: -20, group: "bass", gainDB: 12)
    #expect(abs(db(short) + 8) < 1e-9)
    // unmeasured: the palette's average gap, as before
    let avg = SampledBalance.probeLevel(trimDB: 2, partLevelDB: nil, group: "harmony", gainDB: 2)
    #expect(abs(avg - Loudness.sampledPartLevel(group: "harmony")) < 1e-9)
    let other = SampledBalance.probeLevel(trimDB: 0, partLevelDB: nil, group: "x", gainDB: 0)
    #expect(abs(other - Loudness.sampledPartLevel(group: "melody")) < 1e-9)
  }

  /// A deck's prepared project gives each sampled slot the trim of its part less the slot's
  /// measured part level, marks exactly the non-unity slots, and the loudness probe stands each
  /// sampled net in where its sampler now sits.
  @Test(arguments: ["country", "lofi", "jazz"])
  func preparedSlotsCarryTheirGain(genre: String) throws {
    let bank = SamplerBank(sampleRate: sr, partLevelCache: tempPartLevelCache())
    let t = track(genre, 7, bank: bank, fixes: .all)
    let p = t.prepared
    let sampled = sampledLanes(p)
    try #require(!sampled.isEmpty, "\(genre): a sampled part to measure")
    let trims = p.balance ?? [:]
    var seen: Set<Int> = []
    for (lane, group) in sampled {
      let slot = lane.samplerSlot
      let trim = MixBalance.part(kind: "tonal", group: group).flatMap { trims[$0] } ?? 0
      // (the slot's level against this net's own synth voice, `ownPartLevelDB`)
      let level = p.sampledPartDB[lane.netId]
      #expect((level == nil) == (bank.slotPartLevelDB(slot, group: group) == nil))
      let want = SampledBalance.gainDB(trimDB: trim, partLevelDB: level)
      // a slot two nets share keeps the first's gain
      if seen.insert(slot).inserted {
        #expect(abs(db(Double(p.slotGain[slot])) - want) < 1e-3, "\(genre) \(lane.netId)")
      }
      let bit: UInt64 = 1 << UInt64(slot)
      #expect((p.gainSlots & bit != 0) == (abs(p.slotGain[slot] - 1) > 1e-4))
      let stand = try #require(p.probeLevels[lane.netId])
      if level != nil && abs(want) < SampledBalance.rangeDB {
        #expect(abs(db(stand)) < 1e-3, "\(genre) \(lane.netId): the probe plays it as trimmed")
      }
    }
    for slot in 0..<64 where !seen.contains(slot) {
      #expect(p.slotGain[slot] == 1, "\(genre): slot \(slot) plays nothing here")
    }
  }

  /// Without `.balance` every slot stays at unity, and the probe plays each sampled part at
  /// its slot's measured part level (the palette average only where none was measured).
  @Test func withoutBalanceSlotsStayAtUnity() throws {
    let bank = SamplerBank(sampleRate: sr, partLevelCache: tempPartLevelCache())
    let p = track("country", 7, bank: bank, fixes: DJMusicality.Fixes.all.subtracting(.balance))
      .prepared
    let sampled = sampledLanes(p)
    try #require(!sampled.isEmpty)
    #expect(p.gainSlots == 0)
    #expect(p.slotGain.allSatisfy { $0 == 1 })
    for (lane, group) in sampled {
      let level = p.sampledPartDB[lane.netId]
      #expect(level != nil && bank.slotPartLevelDB(lane.samplerSlot, group: group) != nil)
      #expect(
        p.probeLevels[lane.netId]
          == Loudness.sampledPartLevel(group: group, measuredDB: level))
    }
  }

  /// The synth path never gets slot gains (no bank), so parity and `--synth` are untouched.
  @Test func noBankNoSlotGains() {
    let p = track("country", 7, bank: nil, fixes: .all).prepared
    #expect(p.gainSlots == 0)
    #expect(p.probeLevels.isEmpty)
    let parity = WaveRunner.prepare(
      TrackSpec(genre: "country", seed: 7, structure: "minimal").project(), sampleRate: sr)
    #expect(parity.gainSlots == 0)
  }

  /// The sampled path of `--balance`: the deck's own instruments soloed against the mix sit
  /// within 2 dB (standard deviation) of their family's balance (`MixBalance.targets(family:)`),
  /// or no more than 1.25 dB worse than the same track on synth voices.
  ///
  /// (The slot gain puts a sampled part where its own trimmed synth voice sits, so the sampled
  /// mix can only be as balanced as the synth one, less what the ±12 dB slot range leaves.
  /// Measured at seed 42: synth 1.5 (jazz) … 2.5 dB (lofi: its trims stop at
  /// `MixBalance.maxTrimDB`, lead, bass and snare all +6), sampled within 2 dB except house
  /// 3.1 (Sub Tone Bass sits 10.5 dB under `sub-bass` on the probe and its +6 trim asks for
  /// 16.5 dB, past the range), lofi 2.9 and techno 2.1.)
  @Test(arguments: ["techno", "house", "lofi", "jazz", "country", "funk"])
  func sampledMixIsBalanced(genre: String) throws {
    let bank = SamplerBank(sampleRate: sr, partLevelCache: tempPartLevelCache())
    let t = track(genre, 42, bank: bank, fixes: .all)
    try #require(!sampledLanes(t.prepared).isEmpty, "\(genre): a sampled part")
    let family = MixBalance.family(genre: genre)
    let levels = MixBalance.measure(t.played, opts: t.opts, bars: 4, samplers: bank)
    let e = try #require(MixBalance.error(levels, family: family), "\(genre): \(levels)")
    let synth = try #require(
      MixBalance.error(MixBalance.measure(t.played, opts: t.opts, bars: 4), family: family))
    print(
      "\(genre) sampled balance error \(e) dB (synth \(synth)):",
      levels.sorted { $0.key < $1.key })
    #expect(
      e <= max(2, synth + 1.25),
      "\(genre): sampled balance error \(e) dB (synth \(synth)), \(levels)")
  }

  /// A slot's gain is what the part plays at: the same sampled solo with and without its slot
  /// gain differs by that gain (the synth lanes left out of both).
  @Test func flushAppliesTheSlotGain() throws {
    let bank = SamplerBank(sampleRate: sr, partLevelCache: tempPartLevelCache())
    let t = track("country", 7, bank: bank, fixes: .all)
    // a part every lane of which plays one sampler slot (so nothing else moves with the trim)
    let lanes = t.prepared.lanes.filter { $0.netId != "<live>" }
    func partOf(_ l: Lane) -> String? {
      MixBalance.part(kind: l.kind, group: t.played.nets[l.netId].map(DJMusicality.part) ?? "")
    }
    let (lane, group) = try #require(
      sampledLanes(t.prepared).first { s in
        let part = partOf(s.lane)
        return lanes.allSatisfy { l in
          partOf(l) != part || (l.kind == "tonal" && l.samplerSlot == s.lane.samplerSlot)
        }
      }, "a part played on one sampler alone")
    let part = try #require(MixBalance.part(kind: "tonal", group: group))
    let solo = MixBalance.solo(t.played, part)
    // from the busiest section, as `MixBalance.measure` listens: the song's opening 8 s can
    // leave the part out (`.layerBudget` rests the harmony pad in a sparse intro), and a solo
    // of silence has no level to compare
    let start = Loudness.busiestStart(t.played)
    func rms(balance: Bool) -> Double {
      var o = t.opts
      o.trackGain = 1
      o.master = "limit"
      // the whole track's trims, as the deck plays them (a solo prepared alone has none: its
      // slot would play at the trimless gain, not `t.prepared`'s)
      o.trackBalance = t.prepared.balance
      if !balance { o.musicality.remove(.balance) }
      MixBalance.silence(bank)
      let r = WaveRunner(sampleRate: sr, opts: o)
      r.load(prepared: WaveRunner.prepare(solo, sampleRate: sr, opts: o, startTick: start))
      r.play()
      var buf = [Float](repeating: 0, count: 512)
      var sum = 0.0
      buf.withUnsafeMutableBufferPointer { b in
        for _ in 0..<Int(8 * sr / 512) {
          r.process(b.baseAddress!, nil, frames: 512)
          for x in b { sum += Double(x) * Double(x) }
        }
      }
      return sum
    }
    let gainDB = db(Double(t.prepared.slotGain[lane.samplerSlot]))
    let on = rms(balance: true)
    let off = rms(balance: false)
    try #require(on > 0 && off > 0)
    let measured = 10 * log10(on / off)
    // (within a dB: round-robin samples and the energy curve's tonal lowpass vary a little)
    #expect(abs(measured - gainDB) < 1, "measured \(measured) dB, slot gain \(gainDB) dB")
  }
}
