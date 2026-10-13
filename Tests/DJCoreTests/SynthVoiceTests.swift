import Testing

@testable import DJCore

// `DJMusicality.Fixes.subtractive`: band-limited saw / square tables and a filter envelope per
// voice, measured on mono renders of one-note projects through a linear master. 120 BPM.

private let sr = 48_000.0

private func oneNote(
  _ group: String, note: Int, velocity: Int = 100, steps: Int = 8, channel: Int = 6,
  at step: Int = 0, instrument: String = ""
) -> Project {
  var p = Project()
  p.tempo = 120
  var n = NetBundle.ring(64)
  n.bind(step, note: note, channel: channel, velocity: velocity, duration: 0)
  n.bindings["t\(step)"]?.durationSteps = steps
  n.track.channel = channel
  n.track.group = group
  n.track.instrument = instrument
  p.nets[group] = n
  return p
}

private func render(
  _ p: Project, _ fixes: DJMusicality.Fixes, seconds: Double = 1.2, instruments: Bool = false
) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  if instruments { o.instruments = .shared }
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var out = [Float](repeating: 0, count: Int(seconds * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(256, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n)
      off += n
    }
  }
  return out
}

private func secs(_ s: Double) -> Int { Int(s * sr) }

/// Harmonic `h` of `f0` against the fundamental, dB, in the window `a…b` seconds.
private func harmonic(_ x: [Float], _ f0: Double, _ h: Int, _ a: Double, _ b: Double) -> Double {
  let w = x[secs(a)..<secs(b)]
  return toneDB(w, f0 * Double(h), sampleRate: sr) - toneDB(w, f0, sampleRate: sr)
}

struct SynthVoiceTests {
  /// A bass note (A1, 55 Hz) used to stop at its 8th harmonic (440 Hz): nothing to hear it by
  /// on a small speaker. Now its upper harmonics are there on the attack, and they close away
  /// as the note plays (the filter envelope), where before the timbre never moved.
  @Test func aBassNoteHasHarmonicsThatCloseAway() {
    let f0 = midiHz(33)
    let p = oneNote("bass", note: 33, steps: 8)
    let before = render(p, [])
    let after = render(p, .subtractive)
    // the 12th harmonic (660 Hz) at the attack
    let h12Before = harmonic(before, f0, 12, 0.02, 0.10)
    let h12After = harmonic(after, f0, 12, 0.02, 0.10)
    #expect(h12Before < -60, "before: h12 \(h12Before) dB")
    #expect(h12After > -40, "after: h12 \(h12After) dB")
    // the 8th harmonic (440 Hz), attack against 0.5 s in
    let fallBefore = harmonic(before, f0, 8, 0.02, 0.10) - harmonic(before, f0, 8, 0.5, 0.58)
    let fallAfter = harmonic(after, f0, 8, 0.02, 0.10) - harmonic(after, f0, 8, 0.5, 0.58)
    #expect(abs(fallBefore) < 2, "before: h8 moved \(fallBefore) dB")
    #expect(fallAfter > 10, "after: h8 fell \(fallAfter) dB")
  }

  /// An accent sounds like one: a lead note struck harder is brighter, not only louder.
  @Test func harderNotesAreBrighter() {
    let f0 = midiHz(69)
    func brightness(_ v: Int, _ fixes: DJMusicality.Fixes) -> Double {
      harmonic(render(oneNote("melody", note: 69, velocity: v, steps: 4), fixes), f0, 7, 0.01, 0.06)
    }
    let flat = brightness(120, []) - brightness(50, [])
    let shaped = brightness(120, .subtractive) - brightness(50, .subtractive)
    #expect(abs(flat) < 0.5, "before: \(flat) dB")
    #expect(shaped > 3, "after: the 7th harmonic \(shaped) dB stronger at velocity 120 than 50")
  }

  /// Every table only holds partials its highest note can play under Nyquist (no aliasing),
  /// and the low tables hold far more than beats' 8.
  @Test func tablesStayUnderNyquist() {
    let t = MipTables(wave: "saw", sampleRate: sr)
    let size = waveTableSize
    func partial(_ k: Int, _ n: Int) -> Double {
      cycleHarmonic(t.samples[(k * (size + 1))..<(k * (size + 1) + size)], n)
    }
    for k in 0..<t.top.count where t.top[k] < sr / 2 {
      let limit = Int(0.5 * sr / t.top[k])
      if limit + 1 < size / 2 {
        #expect(partial(k, limit + 1) < 1e-4, "table \(k) holds partial \(limit + 1)")
      }
    }
    #expect(partial(0, 100) > 1e-3)  // 20…40 Hz: up to 128 partials
    #expect(t.top.first! <= 40 && t.top.last! >= 20_000)
  }

  /// Pads (the soft table), strings (Karplus-Strong) and drums play exactly as before.
  @Test func otherVoicesAreUntouched() {
    let pad = oneNote("harmony", note: 60, steps: 8, channel: 7)
    #expect(render(pad, []) == render(pad, .subtractive))
    let guitar = oneNote("melody", note: 64, steps: 4, instrument: "acoustic-guitar")
    var o = WaveOptions()
    o.instruments = .shared
    #expect(FilterEnvelope.forVoice(o.instruments!.voice(instrument: "acoustic-guitar", group: "melody"), group: "melody") == nil)
    #expect(render(guitar, [], instruments: true) == render(guitar, .subtractive, instruments: true))
    let kick = oneNote("drums", note: 36, steps: 1, channel: 10)
    #expect(render(kick, []) == render(kick, .subtractive))
    #expect(FilterEnvelope.forVoice(tonalVoice(instrument: "", group: "bass"), group: "bass") == .bass)
    #expect(FilterEnvelope.forVoice(tonalVoice(instrument: "piano", group: "melody"), group: "melody") == .pluck)
  }
}

private func renderStereo(_ p: Project, _ fixes: DJMusicality.Fixes, seconds: Double = 1.5)
  -> (l: [Float], r: [Float])
{
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var l = [Float](repeating: 0, count: Int(seconds * sr))
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

/// Correlation of left and right over `a…b` seconds: 1 for a mono or panned source.
private func correlation(_ x: (l: [Float], r: [Float]), _ a: Double, _ b: Double) -> Double {
  var lr = 0.0
  var ll = 0.0
  var rr = 0.0
  for i in secs(a)..<secs(b) {
    let l = Double(x.l[i])
    let r = Double(x.r[i])
    lr += l * r
    ll += l * l
    rr += r * r
  }
  return lr / max((ll * rr).squareRoot(), 1e-30)
}

struct UnisonTests {
  /// A held pad note is two oscillators 7 cents either side: its 4th harmonic (C5: 2093 Hz)
  /// splits into two partials 17 Hz apart, where it was one.
  @Test func aPadNoteIsADetunedPair() {
    let p = oneNote("harmony", note: 72, steps: 16, channel: 7)
    let h4 = midiHz(72) * 4
    func split(_ x: [Float]) -> Double {
      let w = x[secs(0.2)..<secs(1.2)]
      return toneDB(w, h4 * exp2(7.0 / 1200), sampleRate: sr) - toneDB(w, h4, sampleRate: sr)
    }
    let before = split(render(p, [], seconds: 1.3))
    let after = split(render(p, .unison, seconds: 1.3))
    #expect(before < -10, "before: +7 cents is \(before) dB against the note")
    #expect(after > 3, "after: +7 cents is \(after) dB against the note")
    // equal power: as loud as one oscillator
    let level =
      rmsDB(render(p, .unison, seconds: 1.3)[...]) - rmsDB(render(p, [], seconds: 1.3)[...])
    #expect(abs(level) < 1.5, "level moved \(level) dB")
  }

  /// With `.stereo` the pair spreads: a held pad note was one point in the field (left and right
  /// perfectly correlated), now it is wide; it folds to mono without cancelling, and a low pad
  /// note stays in the middle.
  @Test func aPadNoteIsWideAndFoldsToMono() {
    let high = oneNote("harmony", note: 72, steps: 16, channel: 7)
    let before = correlation(renderStereo(high, .stereo), 0.2, 1.2)
    let wide = renderStereo(high, [.stereo, .unison])
    let after = correlation(wide, 0.2, 1.2)
    #expect(before > 0.999, "before: L/R correlation \(before)")
    #expect(after < 0.9, "after: L/R correlation \(after)")
    let mono = zip(wide.l, wide.r).map { ($0 + $1) / 2 }
    let stereoPower = (rmsDB(wide.l[...]) + rmsDB(wide.r[...])) / 2
    #expect(rmsDB(mono[...]) > stereoPower - 1.5, "the mono fold lost level")
    let low = oneNote("harmony", note: 48, steps: 16, channel: 7)
    let lowCorr = correlation(renderStereo(low, [.stereo, .unison]), 0.2, 1.2)
    #expect(lowCorr > 0.999, "a C3 pad note: L/R correlation \(lowCorr)")
  }

  /// Basses and plucks keep one oscillator; saw leads get the pair (mono: they are filtered).
  @Test func whoGetsAPair() {
    let bass = oneNote("bass", note: 33, steps: 8)
    #expect(render(bass, []) == render(bass, .unison))
    #expect(Unison.cents(tonalVoice(instrument: "", group: "melody"), group: "melody") == 6)
    #expect(Unison.cents(tonalVoice(instrument: "piano", group: "melody"), group: "melody") == nil)
    #expect(Unison.cents(tonalVoice(instrument: "", group: "harmony"), group: "harmony") == 7)
    #expect(Unison.cents(tonalVoice(instrument: "", group: "bass"), group: "bass") == nil)
    let lead = oneNote("melody", note: 69, steps: 8)
    let s = renderStereo(lead, [.stereo, .unison, .subtractive])
    #expect(s.l == s.r)
  }
}

struct KickTuneTests {
  /// The kick's tail lands on the key: for a track in A it rings at A1 (55 Hz), in C at G1 (the
  /// fifth, 49 Hz: C1 is too low, C2 too high), in D at A1 too; it was 48 Hz in every key.
  @Test(arguments: [(57, 55.0), (60, 49.0), (65, 43.65), (62, 55.0)])
  func theKickRingsInTheKey(root: Int, expected: Double) {
    var p = oneNote("drums", note: 36, steps: 1, channel: 10)
    p.rootNote = root
    let hz = KickTuning.hz(root: root)!
    let tail = { (x: [Float], near: Double) in
      partialPeak(x[secs(0.2)..<secs(0.45)], near: near, sampleRate: sr)
    }
    let before = tail(render(p, []), 48)
    let after = tail(render(p, .kickTune), hz)
    #expect(abs(cents(before, 48)) < 15, "before: \(before) Hz")
    #expect(abs(cents(after, hz)) < 15, "after: \(after) Hz, tuned to \(hz)")
    // the root or the fifth, an octave either side of 50 Hz
    let pc = (Int((12 * log2d(hz / 440)).rounded()) + 69) % 12
    #expect(pc == root % 12 || pc == (root + 7) % 12)
    #expect(hz > 35 && hz < 75)
    #expect(abs(cents(hz, expected)) < 1, "\(hz)")
  }

  /// Without a key (a raw project) the kick stays as beats has it.
  @Test func noKeyNoChange() {
    let p = oneNote("drums", note: 36, steps: 1, channel: 10)
    #expect(p.rootNote == nil)
    #expect(render(p, []) == render(p, .kickTune))
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SynthVoiceRealTimeTests {
  /// The filtered voices render without allocating: a whole song, stereo.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func filteredVoicesDoNotAllocate() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: sr)
    let r = WaveRunner(sampleRate: sr, opts: .extended)
    r.load(prepared: track.prepared)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = l
    l.withUnsafeMutableBufferPointer { lb in
      rr.withUnsafeMutableBufferPointer { rb in
        for _ in 0..<200 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<3000 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(track.prepared.lanes.contains { $0.fAmount > 0 })
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
