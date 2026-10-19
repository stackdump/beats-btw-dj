import Darwin
import Testing

@testable import DJCore

// `DJMusicality.Fixes.stereo`: parts placed in the stereo field by a mid/side pan in the runner,
// measured on renders (linear master, so left + right is exactly twice the mono mix).

private let sr = 48_000.0

/// A four-on-the-floor kick, off-beat hats and a held pad chord at 120 BPM.
private func kitAndPad(kick: Bool = true, hats: Bool = true, pad: Bool = true) -> Project {
  var k = NetBundle.ring(16)
  for step in [0, 4, 8, 12] { k.bind(step, note: 36, channel: 10, velocity: 100, duration: 50) }
  k.track.channel = 10
  k.track.group = "drums"
  var h = NetBundle.ring(16)
  for step in [2, 6, 10, 14] { h.bind(step, note: 42, channel: 10, velocity: 90, duration: 50) }
  h.track.channel = 10
  h.track.group = "drums"
  var c = NetBundle.ring(16)
  for (v, note) in [60, 64, 67].enumerated() {
    c.bind(v, note: note, channel: 7, velocity: 90, duration: 1950)
  }
  c.track.channel = 7
  c.track.group = "harmony"
  var p = Project()
  p.tempo = 120
  if kick { p.nets["kick"] = k }
  if hats { p.nets["hihat"] = h }
  if pad { p.nets["harmony"] = c }
  return p
}

/// Two seconds, stereo (or mono with `right: false`), linear master.
private func render(_ p: Project, fixes: DJMusicality.Fixes, right: Bool = true) -> (
  l: [Float], r: [Float]
) {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  let runner = WaveRunner(sampleRate: sr, opts: o)
  runner.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  runner.play()
  var l = [Float](repeating: 0, count: Int(2 * sr))
  var r = l
  l.withUnsafeMutableBufferPointer { lb in
    r.withUnsafeMutableBufferPointer { rb in
      var off = 0
      while off < lb.count {
        let n = min(256, lb.count - off)
        runner.process(lb.baseAddress! + off, right ? rb.baseAddress! + off : nil, frames: n)
        off += n
      }
    }
  }
  return (l, r)
}

private func energy(_ x: [Double]) -> Double { x.reduce(0) { $0 + $1 * $1 } }

struct StereoTests {
  /// The kick stays dead centre, hats lean right, the pad's notes spread both ways; the mono
  /// sum is the mono mix.
  @Test func partsSitWhereTheyBelong() {
    let kick = render(kitAndPad(hats: false, pad: false), fixes: .stereo)
    #expect(sameSamples(kick.l, kick.r) == .identical, "kick in the middle")
    let hats = render(kitAndPad(kick: false, pad: false), fixes: .stereo)
    #expect(energy(hats.l.map(Double.init)) > 2 * energy(hats.r.map(Double.init)), "hats right")
    let pad = render(kitAndPad(kick: false, hats: false), fixes: .stereo)
    let side = zip(pad.l, pad.r).map { (Double($0) - Double($1)) / 2 }
    let mid = zip(pad.l, pad.r).map { (Double($0) + Double($1)) / 2 }
    #expect(ampDB((energy(side) / energy(mid)).squareRoot()) > -20, "the pad is wide")
    let all = render(kitAndPad(), fixes: .stereo)
    let mono = render(kitAndPad(), fixes: .stereo, right: false).l
    var worst = 0.0
    for i in 0..<mono.count {
      worst = max(worst, abs((Double(all.l[i]) + Double(all.r[i])) / 2 - Double(mono[i])))
    }
    #expect(worst < 1e-6, "mono sum = mono mix (worst \(worst))")
  }

  /// The sampler bus's side signal loses its lows (a sine in one channel only: its side is
  /// more than 20 dB down at 60 Hz, within 1 dB at 2 kHz) and its mid is untouched.
  @Test func samplerLowsGoMono() {
    for (hz, lo, hi) in [(60.0, -200.0, -20.0), (2000.0, -1.0, 1.0)] {
      var f = SideHighpass(hz: 150, sampleRate: sr)
      var sIn = 0.0
      var sOut = 0.0
      var worstMid = 0.0
      for i in 0..<Int(sr) {
        var l = Float(0.5 * sin(2 * Double.pi * hz * Double(i) / sr))
        var r: Float = 0
        let mid = (Double(l) + Double(r)) / 2
        let side = (Double(l) - Double(r)) / 2
        f.process(&l, &r)
        guard i > Int(sr / 4) else { continue }  // settled
        sIn += side * side
        sOut += ((Double(l) - Double(r)) / 2) * ((Double(l) - Double(r)) / 2)
        worstMid = max(worstMid, abs((Double(l) + Double(r)) / 2 - mid))
      }
      let db = 10 * log10(sOut / sIn)
      #expect(db > lo && db < hi, "\(hz) Hz: side \(db) dB")
      #expect(worstMid < 1e-6)
    }
  }

  /// Without `.stereo` both channels carry the same signal, exactly as before.
  @Test func offIsMono() {
    let a = render(kitAndPad(), fixes: [])
    #expect(sameSamples(a.l, a.r) == .identical)
    #expect(sameSamples(a.l, render(kitAndPad(), fixes: [], right: false).l) == .identical)
  }

  /// A whole track through the deck's options: a wide mix (side 5–25 dB under mid) whose low
  /// end is mono (side more than 30 dB under mid below 150 Hz), pads reaching down to C3
  /// included (lofi, jazz).
  ///
  /// Without `.layerBudget` (6.2): its rests leave the first 12 s of minimal lofi and jazz to the
  /// drums and bass (side −30 / −29 dB with it, −17 / −23 without), so with it this would measure
  /// the arrangement, not where the parts sit. Width under the budget is the same per part.
  @Test(arguments: ["trance", "lofi", "jazz"])
  func aTrackIsWideAboveAndMonoBelow(genre: String) {
    let m = deckMetrics(genre, without: .layerBudget)
    #expect(m.sideDB > -25 && m.sideDB < -5, "\(genre): side \(m.sideDB) dB")
    #expect(m.lowSideDB < -30, "\(genre): low side \(m.lowSideDB) dB")
    #expect(m.clipped == 0)
  }

  /// Ambient's pads sit low and long: narrower (`VoiceDesign.padWidth`) and with the unison
  /// pair's side highpassed higher (`padSideHz`), the low end stays mono (side 35 dB or more
  /// under mid below 150 Hz, where full width left it at −26) while the mix is still wide.
  @Test func ambientPadsKeepTheirLowsMono() {
    let design = WaveOptions.extended.forGenre("ambient").voiceDesign
    #expect(design.padWidth < 1 && design.padSideHz > Unison.sideHz)
    let m = deckMetrics("ambient")
    #expect(m.lowSideDB <= -35, "ambient: low side \(m.lowSideDB) dB")
    #expect(m.sideDB >= -20, "ambient: side \(m.sideDB) dB")
    #expect(m.clipped == 0)
  }
}

/// Sampled instruments' width (`DJMusicality.sampledWidth`, ROADMAP 6.6): set per slot by the
/// instrument's catalog category, the bass part mono whatever it plays.
struct SampledWidthTests {
  @Test func theTableByCategory() {
    typealias W = DJMusicality.SampledWidth
    let w = DJMusicality.sampledWidth
    #expect(w("bass.electric", "melody") == W(width: 0, sideHz: nil))
    #expect(w("synth.pluck", "bass") == W(width: 0, sideHz: nil), "the bass part is mono")
    #expect(w(nil, "bass").width == 0)
    #expect(w("keys.piano", "harmony") == W(width: 1.2, sideHz: DJMusicality.sampledSideHz))
    #expect(w("pad", "harmony") == W(width: 1.2, sideHz: 300))
    #expect(w("guitar.acoustic", "harmony") == W(width: 0.8, sideHz: nil))
    #expect(w("synth.lead", "melody") == W(width: 0.6, sideHz: nil))
    #expect(w("strings", "harmony") == .asLoaded)
    #expect(w(nil, "melody") == .asLoaded)
    #expect(!DJMusicality.sampledWidthSource.isEmpty, "the table names its source")
  }

  /// A prepared track's sampled slots carry their instrument's width; none without `.stereo`.
  @Test func slotsCarryTheirWidth() throws {
    let src = WaveDeckSource(sampleRate: sr)
    let spec = TrackSpec(genre: "country", seed: 7, structure: "minimal")
    let p = PreparedTrack(
      spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers, seed: spec.seed)
    ).prepared
    try #require(p.widthSlots != 0, "a sampled slot with a width (needs installed sounds)")
    var seen = Set<Int>()
    for lane in p.lanes where lane.isTonal && lane.samplerSlot >= 0 && lane.netId != "<live>" {
      guard let group = p.sampledGroups[lane.netId], seen.insert(lane.samplerSlot).inserted
      else { continue }
      let want = DJMusicality.sampledWidth(
        category: VoiceCatalog.shared.categoryOf[lane.instrument], group: group)
      #expect(p.slotWidth[lane.samplerSlot] == Float(want.width), "\(lane.netId)")
      #expect((p.sideSlots >> UInt64(lane.samplerSlot)) & 1 == (want.sideHz != nil ? 1 : 0))
    }
    var o = WaveOptions.extended(samplers: src.samplers, seed: spec.seed)
    o.musicality.remove(.stereo)
    let flat = PreparedTrack(spec: spec, sampleRate: sr, opts: o).prepared
    #expect(flat.widthSlots == 0 && flat.sideSlots == 0)
  }

  /// A sampled track through the deck: wide above (side no more than 20 dB under mid), mono
  /// below 150 Hz (side 30 dB or more under mid), and it folds to mono losing at most 1 dB.
  @Test(arguments: ["country", "lofi", "trance"])
  func sampledTracksAreWideAboveAndMonoBelow(genre: String) throws {
    let src = WaveDeckSource(sampleRate: sr)
    let spec = TrackSpec(genre: genre, seed: 42, structure: "minimal")
    let track = PreparedTrack(
      spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers, seed: spec.seed))
    try #require(track.prepared.widthSlots != 0, "\(genre): no sampled slot with a width")
    let m = sampledDeckMetrics(src, track)
    print(
      "\(genre): side \(m.sideDB) dB, low side \(m.lowSideDB) dB, fold \(m.spectrum.monoFoldDB) dB")
    #expect(m.lowSideDB <= -30, "\(genre): low side \(m.lowSideDB) dB")
    #expect(m.sideDB >= -20, "\(genre): side \(m.sideDB) dB")
    #expect(m.spectrum.monoFoldDB >= -1, "\(genre): mono fold \(m.spectrum.monoFoldDB) dB")
    #expect(m.clipped == 0)
  }
}

/// Twelve seconds of a sampled track through its deck.
private func sampledDeckMetrics(_ source: WaveDeckSource, _ track: PreparedTrack) -> AudioMetrics {
  source.load(track.prepared)
  source.play()
  var l = [Float](repeating: 0, count: Int(12 * sr))
  var r = l
  l.withUnsafeMutableBufferPointer { lb in
    r.withUnsafeMutableBufferPointer { rb in
      var off = 0
      while off < lb.count {
        let n = min(512, lb.count - off)
        source.render(frames: n, left: lb.baseAddress! + off, right: rb.baseAddress! + off)
        off += n
      }
    }
  }
  return AudioMetrics(left: l, right: r, sampleRate: sr)
}

/// Twelve seconds of `genre` seed 42 through the deck's options and the deck (its limiter holds
/// the peaks the track's loudness gain brings).
private func deckMetrics(_ genre: String, without: DJMusicality.Fixes = []) -> AudioMetrics {
  var opts = WaveOptions.extended
  opts.musicality.subtract(without)
  let track = PreparedTrack(
    spec: TrackSpec(genre: genre, seed: 42, structure: "minimal"), sampleRate: sr, opts: opts)
  let source = WaveDeckSource(sampleRate: sr, opts: opts)
  source.load(track.prepared)
  source.play()
  var l = [Float](repeating: 0, count: Int(12 * sr))
  var r = l
  l.withUnsafeMutableBufferPointer { lb in
    r.withUnsafeMutableBufferPointer { rb in
      var off = 0
      while off < lb.count {
        let n = min(512, lb.count - off)
        source.render(frames: n, left: lb.baseAddress! + off, right: rb.baseAddress! + off)
        off += n
      }
    }
  }
  return AudioMetrics(left: l, right: r, sampleRate: sr)
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct StereoRealTimeTests {
  /// The side signal is a few multiply-adds a sample into preallocated buffers.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func stereoDoesNotAllocate() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: sr)
    let runner = WaveRunner(sampleRate: sr, opts: .extended)
    runner.load(prepared: track.prepared)
    runner.play()
    var l = [Float](repeating: 0, count: 128)
    var r = l
    l.withUnsafeMutableBufferPointer { lb in
      r.withUnsafeMutableBufferPointer { rb in
        for _ in 0..<200 { runner.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        r.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<3000 { runner.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
