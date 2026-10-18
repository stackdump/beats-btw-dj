import Testing

@testable import DJCore

// ROADMAP 6.6: the room's level and the lanes' sends read from targets.json (`MixTargets`), a
// family's return band (6.1's references) moving `wet` into it, and the pad shimmer
// (`DJMusicality.Fixes.shimmer`, `Shimmer`). Stereo renders of small projects through a linear
// master, 120 BPM.

private let sr = 48_000.0

private func ring(_ group: String, channel: Int, _ notes: [(step: Int, note: Int)], ms: Int)
  -> NetBundle
{
  var n = NetBundle.ring(64)
  for x in notes { n.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: ms) }
  n.track.channel = channel
  n.track.group = group
  return n
}

/// One short chord on the first step of an 8-second ring, played by `group`.
private func chordOnce(_ group: String = "harmony", notes: [Int] = [60, 64, 67]) -> Project {
  var p = Project()
  p.tempo = 120
  p.nets[group] = ring(
    group, channel: 7, notes.enumerated().map { ($0.offset, $0.element) }, ms: 100)
  return p
}

private func render(_ p: Project, _ fixes: DJMusicality.Fixes, space: SpaceSpec? = nil)
  -> (l: [Float], r: [Float])
{
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.space = space
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var l = [Float](repeating: 0, count: Int(4 * sr))
  var rr = l
  l.withUnsafeMutableBufferPointer { lb in
    rr.withUnsafeMutableBufferPointer { rb in
      var off = 0
      while off < lb.count {
        let n = min(256, lb.count - off)
        r.process(lb.baseAddress! + off, rb.baseAddress! + off, frames: n)
        off += n
      }
    }
  }
  return (l, rr)
}

private func mid(_ x: (l: [Float], r: [Float])) -> [Float] { zip(x.l, x.r).map { ($0 + $1) / 2 } }
private func secs(_ s: Double) -> Int { Int(s * sr) }

private let pre61 = "rule-of-thumb (pre-6.1)"

@Suite struct RoomShimmerTests {
  /// The sends come from the table, and are what the code held before it.
  @Test func sendsAreTheTablesAndTheRuleOfThumb() {
    let keys: [(String, String)] = [
      ("tonal", "harmony"), ("tonal", "pad"), ("tonal", "arp"), ("tonal", "bass"),
      ("tonal", "melody"), ("tonal", "lead"), ("snare", "drums"), ("clap", "drums"),
      ("crash", "drums"), ("openhat", "drums"), ("hat", "drums"), ("kick", "drums"),
      ("tom", "drums"),
    ]
    for (kind, group) in keys {
      #expect(
        SpaceSpec.send(kind: kind, group: group)
          == SpaceSpec.ruleOfThumbSend(kind: kind, group: group), "\(kind)/\(group)")
    }
    #expect(SpaceSpec.samplerSend == 0.35)
    for (k, t) in MixTargets.shared.space.sends ?? [:] {
      #expect(t.source.hasPrefix(pre61), "\(k)")
    }
  }

  /// With every family's return band empty (as checked in) the rooms are the table's, and with
  /// the shimmer off a room has none: renders are what they were.
  @Test func emptyBandsLeaveTheRoomsAsTheyWere() {
    let t = MixTargets.shared
    for f in GrooveTemplate.familyNames {
      #expect(t.space.families?[f] != nil, "\(f)")
      #expect(t.space.families?[f]?.returnDB?.range == nil, "\(f)")
    }
    for g in BeatsTables.shared.genreIDs + ["none"] {
      let table = (t.space.genres[g] ?? t.space.default).spec
      #expect(t.room(genre: g) == table, "\(g)")
      #expect(SpaceSpec.forGenre(g) == table, "\(g)")
      #expect(SpaceSpec.forGenre(g).shimmer == 0)
      var shimmered = SpaceSpec.forGenre(g, shimmer: true)
      #expect(shimmered.shimmer == t.shimmer(genre: g))
      shimmered.shimmer = 0
      #expect(shimmered == table, "\(g)")
    }
  }

  /// A filled band moves `wet` so the measured return lands in it: ×10^(Δ/20) for a room
  /// outside, untouched inside (or with no measured return).
  @Test func aFilledBandScalesTheWetIntoIt() {
    var t = MixTargets.shared
    let band = MixTargets.Target(value: -11, band: [-12, -10], source: "test")
    t.space.families?["dance"]?.returnDB = band
    t.space.families?["chill"]?.returnDB = MixTargets.Target(
      value: -10, band: [-11, -5], source: "test")
    let trance = MixTargets.shared.space.genres["trance"]!
    let measured = trance.returnDB!.value!
    #expect(measured < -12)
    let want = trance.wet * dbAmp(-12 - measured)
    #expect(abs(t.room(genre: "trance").wet - want) < 1e-12)
    #expect(t.room(genre: "trance").seconds == trance.seconds)
    // ambient (−8) sits inside chill's band: unchanged
    let ambient = MixTargets.shared.space.genres["ambient"]!
    #expect(t.familyNameForTest("ambient") == "chill")
    #expect(t.room(genre: "ambient") == ambient.spec)
    // a genre the table has no measured return for: unchanged
    if let garage = MixTargets.shared.space.genres["garage"], garage.returnDB == nil {
      #expect(t.room(genre: "garage") == garage.spec)
    }
  }

  /// The band mapping's premise: the return is linear in `wet` (×k is +20·log10 k dB).
  @Test func theReturnIsLinearInWet() {
    let dry = render(chordOnce(), .stereo)
    let a = roomReturnDB(
      wet: render(
        chordOnce(), [.stereo, .space], space: SpaceSpec(seconds: 2, wet: 0.2, damping: 7000)),
      dry: dry)
    let b = roomReturnDB(
      wet: render(
        chordOnce(), [.stereo, .space], space: SpaceSpec(seconds: 2, wet: 0.4, damping: 7000)),
      dry: dry)
    #expect(abs((b - a) - ampDB(2)) < 0.2, "return \(a) → \(b) dB")
  }

  /// The shimmer is the pads': a lead's render is bit-identical with it on, a pad's is not.
  @Test func theShimmerIsPadOnly() {
    let room = SpaceSpec(seconds: 2, wet: 0.4, damping: 7000, shimmer: 0.3)
    let lead = chordOnce("melody")
    let a = render(lead, [.stereo, .space], space: room)
    let b = render(lead, [.stereo, .space, .shimmer], space: room)
    #expect(sameSamples(a.l, b.l) == .identical)
    #expect(sameSamples(a.r, b.r) == .identical)
    let pad = chordOnce()
    let c = render(pad, [.stereo, .space], space: room)
    let d = render(pad, [.stereo, .space, .shimmer], space: room)
    #expect(sameSamples(c.l, d.l) != .identical)
    // and the room's lanes send what they did: the lead's prepared sends are unchanged
    var o = WaveOptions()
    o.musicality = [.space, .shimmer]
    o.space = room
    let prepared = WaveRunner.prepare(chordOnce("melody"), sampleRate: sr, opts: o)
    #expect(prepared.lanes.allSatisfy { $0.shimmerSend == 0 })
    let padPrepared = WaveRunner.prepare(pad, sampleRate: sr, opts: o)
    #expect(padPrepared.lanes.contains { $0.shimmerSend > 0 && $0.shimmerSend == $0.send })
  }

  /// At level 0 (or with no room) the shimmer is not there at all: bit-identical.
  @Test func aZeroShimmerIsBitIdentical() {
    let room = SpaceSpec(seconds: 2, wet: 0.4, damping: 7000)
    let a = render(chordOnce(), [.stereo, .space], space: room)
    let b = render(chordOnce(), [.stereo, .space, .shimmer], space: room)
    #expect(sameSamples(a.l, b.l) == .identical)
    #expect(sameSamples(a.r, b.r) == .identical)
  }

  /// It is an octave up: in the tail, a lone A4 (440 Hz) pad has more at 880 Hz against 440
  /// with the shimmer than without.
  @Test func theShimmerAddsTheOctaveAbove() {
    let pad = chordOnce(notes: [69])
    let plain = mid(
      render(pad, [.stereo, .space], space: SpaceSpec(seconds: 2.4, wet: 0.45, damping: 7500)))
    let shim = mid(
      render(
        pad, [.stereo, .space, .shimmer],
        space: SpaceSpec(seconds: 2.4, wet: 0.45, damping: 7500, shimmer: 0.3)))
    let tail = secs(0.8)..<secs(1.6)
    let before = toneDB(plain[tail], 880, sampleRate: sr) - toneDB(plain[tail], 440, sampleRate: sr)
    let after = toneDB(shim[tail], 880, sampleRate: sr) - toneDB(shim[tail], 440, sampleRate: sr)
    #expect(after > before + 3, "880/440 in the tail: \(before) → \(after) dB")
  }

  /// The shimmer's level per family comes from the table, named by its source.
  @Test func shimmerLevelsByFamily() {
    for (f, r) in MixTargets.shared.space.families ?? [:] {
      #expect(r.shimmer?.value != nil, "\(f)")
      #expect(r.shimmer?.source.hasPrefix(pre61) == true, "\(f)")
    }
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(track.prepared.space == SpaceSpec.forGenre("trance", shimmer: true))
  }
}

extension MixTargets {
  fileprivate func familyNameForTest(_ genre: String) -> String { Self.familyName(genre) }
}
