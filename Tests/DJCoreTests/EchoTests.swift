import Testing

@testable import DJCore

// `DJMusicality.Fixes.echo`: the tempo-synced ping-pong delay, measured on stereo renders of one
// short lead note through a linear master.

private let sr = 48_000.0

/// One lead note, a sixteenth long, on the first step of a 4-bar ring.
private func leadOnce(tempo: Double = 120, group: String = "melody") -> Project {
  var p = Project()
  p.tempo = tempo
  var n = NetBundle.ring(64)
  n.bind(0, note: 72, channel: 4, velocity: 110, duration: 0)
  n.bindings["t0"]?.durationSteps = 1
  n.track.channel = 4
  n.track.group = group
  p.nets[group] = n
  return p
}

private func render(
  _ p: Project, _ fixes: DJMusicality.Fixes, echo: EchoSpec?, seconds: Double = 2,
  samplers: SamplerBank? = nil
) -> (l: [Float], r: [Float]) {
  var o = samplers.map { WaveOptions.extended(samplers: $0, seed: 7) } ?? WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.echo = echo
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

/// RMS (dB) of `x` in a 60 ms window starting `t` seconds after the note (the note lands on the
/// first tick, a sample in).
private func at(_ x: [Float], _ t: Double) -> Double {
  let a = Int(t * sr)
  return rmsDB(x[a..<(a + Int(0.06 * sr))])
}

struct EchoTests {
  /// Dotted eighths at 120 BPM are 375 ms: the first repeat comes back on the left, the second
  /// on the right, each quieter than the last; dry, there is nothing there at all.
  @Test func repeatsPingPongOnTheBeatGrid() {
    let spec = EchoSpec(steps: 3, feedback: 0.42, wet: 0.32, damping: 5000)
    let dry = render(leadOnce(), [.stereo], echo: spec)
    let full = render(leadOnce(), [.stereo, .echo], echo: spec)
    // the echo alone: what the fix adds to the dry render
    let wet = (l: zip(full.l, dry.l).map { $0 - $1 }, r: zip(full.r, dry.r).map { $0 - $1 })
    #expect(at(wet.l, 0.1) < -120, "nothing before the first repeat")
    #expect(at(dry.l, 0.375) < at(wet.l, 0.375) - 20, "the dry note has died by the first repeat")
    let first = (l: at(wet.l, 0.375), r: at(wet.r, 0.375))
    let second = (l: at(wet.l, 0.75), r: at(wet.r, 0.75))
    let third = (l: at(wet.l, 1.125), r: at(wet.r, 1.125))
    #expect(first.l > -60 && first.l > first.r + 10, "first repeat L \(first.l) R \(first.r)")
    #expect(second.r > second.l + 10, "second repeat L \(second.l) R \(second.r)")
    #expect(third.l > third.r + 10, "third repeat L \(third.l) R \(third.r)")
    #expect(second.r < first.l - 3 && third.l < second.r - 3, "repeats fall")
    // between the repeats, quiet (a 60 ms window halfway between)
    #expect(at(wet.l, 0.55) < first.l - 20)
  }

  /// The delay follows the tempo: at 140 BPM a dotted eighth is 321 ms.
  @Test func theDelayFollowsTheTempo() {
    let spec = EchoSpec(steps: 3, feedback: 0.42, wet: 0.32, damping: 5000)
    let dry = render(leadOnce(tempo: 140), [.stereo], echo: spec)
    let full = render(leadOnce(tempo: 140), [.stereo, .echo], echo: spec)
    let wet = zip(full.l, dry.l).map { $0 - $1 }
    let t = 3 * 60 / (140.0 * 4)
    #expect(at(wet, t) > -60 && at(wet, t - 0.07) < -120, "the repeat lands at \(t) s")
  }

  /// Only the lead and arp echo: a bass or pad note renders bit-identically with the echo on,
  /// and genres without one (jazz, techno) get none.
  @Test func onlyLeadsEcho() {
    let spec = EchoSpec.forGenre("trance")!
    for group in ["bass", "harmony"] {
      let a = render(leadOnce(group: group), [.stereo], echo: spec)
      let b = render(leadOnce(group: group), [.stereo, .echo], echo: spec)
      #expect(a.l == b.l && a.r == b.r, "\(group)")
    }
    #expect(EchoSpec.forGenre("jazz") == nil && EchoSpec.forGenre("techno") == nil)
    #expect(EchoSpec.forGenre("ambient")!.steps > EchoSpec.forGenre("trance")!.steps)
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(track.prepared.echo == EchoSpec.forGenre("trance"))
    let jazz = PreparedTrack(
      spec: TrackSpec(genre: "jazz", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(jazz.prepared.echo == nil)
  }

  /// A sampled lead echoes too: its slot renders on its own, its send reaches the echo a block
  /// late. Apple's GM square lead (`dls:80`, on every Mac), one short note: by the first repeat
  /// the dry render has died away and the echo stands at least 15 dB over it.
  @Test func sampledLeadsEcho() throws {
    let spec = EchoSpec.forGenre("trance")!
    var p = leadOnce()
    p.nets["melody"]?.track.sound.option = "dls:80"
    let bank = SamplerBank(sampleRate: sr)
    var o = WaveOptions.extended(samplers: bank, seed: 7)
    o.musicality = [.stereo, .echo]
    o.echo = spec
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: o)
    let lane = try #require(prepared.lanes.first { $0.netId == "melody" })
    try #require(lane.samplerSlot >= 0, "the lead plays Apple's GM bank")
    #expect(prepared.echoSlots == 1 << UInt64(lane.samplerSlot))
    #expect(
      prepared.slotEcho[lane.samplerSlot] == Float(EchoSpec.send(kind: "tonal", group: "melody")))
    let dry = render(p, [.stereo], echo: spec, samplers: bank)
    let full = render(p, [.stereo, .echo], echo: spec, samplers: bank)
    #expect(at(dry.l, 0.02) > -40, "the sampled note plays")
    let wet = (l: zip(full.l, dry.l).map { $0 - $1 }, r: zip(full.r, dry.r).map { $0 - $1 })
    let first = at(wet.l, 0.375)
    let second = at(wet.r, 0.75)
    #expect(first > at(dry.l, 0.375) + 15, "first repeat \(first) dB, dry \(at(dry.l, 0.375)) dB")
    #expect(first > at(wet.r, 0.375) + 10, "the first repeat comes back on the left")
    #expect(second > at(wet.l, 0.75) + 10, "the second on the right")
    // without the echo, a sampled lead is not taken off its group path for nothing
    let plain = WaveRunner.prepare(
      p, sampleRate: sr,
      opts: {
        var q = o
        q.musicality = [.stereo]
        return q
      }())
    #expect(plain.echoSlots == 0)
  }

  /// A delay a hair over a whole sample (120 bpm one ulp down: 18000.000000000004 samples) put
  /// the read at exactly the buffer's length when the write head reached that sample: `-ε +
  /// count` rounds to `count`. It crashed the live app on the audio thread (index out of range).
  @Test func aDelayAHairOverAWholeSampleReadsInsideTheLine() {
    let echo = PingPong(sampleRate: 48_000)
    echo.tune(EchoSpec.forGenre("trance"), bpm: 120.0.nextDown)
    var peak = 0.0
    for i in 0..<60_000 {
      let (l, r) = echo.process(i < 480 ? 0.5 : 0)
      peak = max(peak, abs(l), abs(r))
    }
    #expect(peak > 0 && peak.isFinite)
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct EchoRealTimeTests {
  /// The echo renders without allocating: a whole trance song, stereo.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theEchoDoesNotAllocate() {
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
    #expect(track.prepared.echo != nil)
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }

  /// Sampled leads' echo sends (a slot at a time, through the fifo) allocate nothing: a trance
  /// deck with its sampler bank, other block sizes and a live note.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func sampledEchoDoesNotAllocate() throws {
    let src = WaveDeckSource(sampleRate: sr)
    let spec = TrackSpec(genre: "trance", seed: 42, structure: "minimal")
    let track = PreparedTrack(
      spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers, seed: spec.seed))
    let p = track.prepared
    try #require(p.echoSlots != 0, "a sampled slot that echoes")
    src.load(p)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int, frames: Int = 512) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n {
            src.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
      }
    }
    run(100)
    let report = countAllocations {
      run(1000)
      run(200, frames: 128)
      src.noteOn(72, velocity: 100)
      run(50)
      src.allNotesOff()
      run(50)
    }
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")
  }
}
