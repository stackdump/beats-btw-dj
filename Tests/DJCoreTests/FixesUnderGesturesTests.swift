import Testing

@testable import DJCore

// ROADMAP 6.7, the fixes under performance, part two: what the runner fixes do under a DJ's
// gestures — role mutes and net macros (the duck, the trims), master macros stacked on
// `.energy`'s lowpass, the turntable brake and a hand on the platter against the room and the
// echo's tails. Each pair is either held to what it should do, or written down as intended
// (docs/musicality-notes.md §19).
//
// Found this way and fixed:
// - a stop under the turntable brake let what the stopped record held (voices, the room, the
//   sampled sends in `sendFifo`) fade back in after the cancel: `WaveRunner.silence`, called by
//   `WaveDeckSource` on a stop while the brake is on.
// - a dry song froze the echo's (and the shimmer's) line instead of running it: the next song
//   with an echo, maybe many minutes later, began with the repeats of the last one.
// Left (disabled below, by class): "echo reset" — `PingPong` has no reset, so the echo's
// repeats still come back in after a stop under the brake.

private let sr = 48_000.0
private let block = 240  // 0.9 s is a whole number of blocks

// MARK: runner level (linear master, as DuckTests)

/// A four-on-the-floor kick and a pad chord held for the bar, at 120 BPM (a beat is 0.5 s).
private func kickAndPad(pad: Bool = true, kick: Bool = true) -> Project {
  var k = NetBundle.ring(16)
  for step in [0, 4, 8, 12] { k.bind(step, note: 36, channel: 10, velocity: 100, duration: 50) }
  k.track.channel = 10
  k.track.group = "drums"
  var h = NetBundle.ring(16)
  for (v, note) in [60, 64, 67].enumerated() {
    h.bind(v, note: note, channel: 7, velocity: 90, duration: 1950)
  }
  h.track.channel = 7
  h.track.group = "harmony"
  var p = Project()
  p.tempo = 120
  if kick { p.nets["kick"] = k }
  if pad { p.nets["harmony"] = h }
  return p
}

/// `seconds` of `p` at duck `depth`, mono; `setup` runs before play, `at(frame)` before each
/// block.
private func render(
  _ p: Project, depth: Double, seconds: Double = 4, setup: (WaveRunner) -> Void = { _ in },
  at: (WaveRunner, Int) -> Void = { _, _ in }
) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.duckDepth = depth
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  setup(r)
  r.play()
  var out = [Float](repeating: 0, count: Int(seconds * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      at(r, off)
      let n = min(block, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n)
      off += n
    }
  }
  return out
}

private func secs(_ s: Double) -> Int { Int(s * sr) }

private func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
  var m: Float = 0
  for i in 0..<min(a.count, b.count) { m = max(m, abs(a[i] - b[i])) }
  return m
}

/// One lead note, a sixteenth long, on the first step of a 4-bar ring (none: a silent ring).
private func leadOnce(note: Bool = true) -> Project {
  var p = Project()
  p.tempo = 120
  var n = NetBundle.ring(64)
  if note {
    n.bind(0, note: 72, channel: 4, velocity: 110, duration: 0)
    n.bindings["t0"]?.durationSteps = 1
  }
  n.track.channel = 4
  n.track.group = "melody"
  p.nets["melody"] = n
  return p
}

// MARK: deck level (the app's options, as TurntableBrakeTests)

private let rate = 22_050.0
private let deckBlock = 128

/// A deck playing `genre` (seed 42) with the app's options and the genre's settings, synth
/// voices only; `drop` takes fixes out.
private func deck(
  _ genre: String, structure: String = "minimal", drop: DJMusicality.Fixes = []
) -> WaveDeckSource {
  var o = WaveOptions.extended.forGenre(genre)
  o.musicality.subtract(drop)
  if drop.contains(.echo) { o.echo = nil }
  let src = WaveDeckSource(sampleRate: rate, opts: o)
  let p = TrackSpec(genre: genre, seed: 42, structure: structure).project()
  src.load(WaveRunner.prepare(p, sampleRate: rate, opts: o))
  src.play()
  return src
}

/// Render `srcs` side by side, `blocks` blocks of 128; `at(b)` runs before block `b`. Returns
/// each source's mid (L + R) / 2.
private func render(
  _ srcs: [WaveDeckSource], blocks: Int, at: (Int) -> Void = { _ in }
) -> [[Float]] {
  var outs = [[Float]](repeating: [], count: srcs.count)
  var l = [Float](repeating: 0, count: deckBlock)
  var r = [Float](repeating: 0, count: deckBlock)
  for b in 0..<blocks {
    at(b)
    for (i, src) in srcs.enumerated() {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          src.render(frames: deckBlock, left: lp.baseAddress!, right: rp.baseAddress!)
        }
      }
      outs[i] += zip(l, r).map { ($0 + $1) / 2 }
    }
  }
  return outs
}

private func blocks(_ s: Double) -> Int { Int(s * rate) / deckBlock }
private func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }

struct FixesUnderGesturesTests {
  // MARK: role mutes and net macros

  /// The duck follows the kick you hear: with the kick's role muted the pad plays exactly as it
  /// does with no kick at all (no pumping under a silent kick).
  @Test func aMutedKickDucksNothing() {
    let muted = render(kickAndPad(), depth: 0.5, setup: { $0.setMute("kick", true) })
    let padAlone = render(kickAndPad(kick: false), depth: 0.5)
    #expect(rmsDB(padAlone[...]) > -60, "the pad plays")
    #expect(maxDiff(muted, padAlone) < 1e-5)
  }

  /// A breakdown (the drums muted by the macro) lets the pad swell back to its undipped level
  /// within a beat of the last kick, and stay there.
  @Test func aBreakdownLetsThePadSwellBack() {
    let fire = secs(0.9)
    let broken = render(
      kickAndPad(), depth: 0.5,
      at: { r, off in if off == fire { r.fireMacro(.breakdown, ticks: 64) } })
    let plain = render(kickAndPad(kick: false), depth: 0)
    for (a, b) in [(1.6, 2.4), (2.4, 3.2), (3.2, 3.9)] {
      let x = rmsDB(broken[secs(a)..<secs(b)])
      let y = rmsDB(plain[secs(a)..<secs(b)])
      #expect(abs(x - y) < 0.2, "\(a)–\(b) s: \(x) vs \(y) dB")
    }
  }

  /// Intended: a mute is a gesture, not a remix. The trims (`.balance`), the slots' gains and
  /// the track's loudness stay where prepare put them while roles are muted and unmuted.
  @Test func roleMutesLeaveTheTrims() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "techno", seed: 42, structure: "minimal"), sampleRate: rate)
    let p = track.prepared
    let before = p.lanes.map(\.voiceState)
    let gain = p.gain
    let slots = p.slotGain
    let r = WaveRunner(sampleRate: rate, opts: .extended.forGenre("techno"))
    r.load(prepared: p)
    r.play()
    var l = [Float](repeating: 0, count: deckBlock)
    let roles = Set(p.lanes.map(\.netId)).filter { !$0.isEmpty }
    l.withUnsafeMutableBufferPointer { b in
      for (i, role) in roles.sorted().enumerated() {
        r.setRoleMuted(hash: strHash(role), i % 2 == 0)
        r.setMute(role, i % 2 == 1)
        for _ in 0..<40 { r.process(b.baseAddress!, nil, frames: deckBlock) }
      }
    }
    #expect(p.lanes.map(\.voiceState) == before)
    #expect(p.gain == gain)
    #expect(p.slotGain == slots)
  }

  // MARK: master macros on `.energy`

  /// Intended: the master lowpass (a mixer insert, after the runner) and `.energy`'s tonal
  /// lowpass (in the runner) are in series; a sweep stacked on the curve ends where the curve
  /// has the deck, as loud as a deck that never swept (± 0.5 dB).
  @Test func theMasterSweepComesBackToTheEnergyCurve() {
    let swept = deck("techno", structure: "standard")
    let ref = deck("techno", structure: "standard")
    let fire = 40
    let out = render(
      [swept, ref], blocks: fire + blocks(9.5),
      at: { b in if b == fire { swept.fire(.sweepLp, bars: 1) } })
    #expect(!swept.isActive(.sweepLp), "the sweep has run out")
    let a = (fire + blocks(8.5)) * deckBlock
    let b = (fire + blocks(9.5)) * deckBlock
    let x = rmsDB(out[0][a..<b])
    let y = rmsDB(out[1][a..<b])
    #expect(y > -60, "the deck plays")
    #expect(abs(x - y) < 0.5, "\(x) vs \(y) dB")
  }

  // MARK: the room and the echo against stops, the brake and the hand

  /// A dry song runs the echo's line empty: an echo song after it does not begin with the
  /// repeats of the one before (they died away under the dry song).
  @Test func anEchoTurnedOffDiesAwayBeforeTheNextEchoSong() {
    let spec = EchoSpec(steps: 3, feedback: 0.42, wet: 0.32, damping: 5000)
    var o = WaveOptions()
    o.master = "linear"
    o.musicality = [.stereo, .echo]
    var dry = o
    o.echo = spec
    dry.echo = nil
    let r = WaveRunner(sampleRate: sr, opts: o)
    var l = [Float](repeating: 0, count: block)
    var rr = l
    func run(_ seconds: Double) -> [Float] {
      var out: [Float] = []
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<secs(seconds) / block {
            r.process(lb.baseAddress!, rb.baseAddress!, frames: block)
            out += lb
          }
        }
      }
      return out
    }
    r.load(prepared: WaveRunner.prepare(leadOnce(), sampleRate: sr, opts: o))
    r.play()
    let first = run(0.5)  // the note and its first repeat
    #expect(rmsDB(first[...]) > -60, "the echo song plays")
    r.stop()
    r.load(prepared: WaveRunner.prepare(leadOnce(note: false), sampleRate: sr, opts: dry))
    r.play()
    _ = run(8)  // a dry song: 21 repeat times
    r.stop()
    r.load(prepared: WaveRunner.prepare(leadOnce(note: false), sampleRate: sr, opts: o))
    r.play()
    let next = run(2)
    #expect(rmsDB(next[...]) < -110, "stale repeats: \(rmsDB(next[...])) dB")
  }

  /// A stop under the brake (in its stopped quarter) ends the record there: nothing it held —
  /// voices, the room, the sends in flight — fades back in after the cancel.
  @Test func aStopUnderTheBrakeLeavesNothingToComeBack() {
    let src = deck("techno", drop: [.echo])
    let fire = blocks(3)
    let stop = fire + blocks(1.8)  // a bar at 120 BPM is 2 s; stopped from 1.5 s
    var braking = false
    let out = render(
      [src], blocks: stop + blocks(1.5),
      at: { b in
        if b == fire { src.fire(.vinylBrake) }
        if b == stop {
          braking = src.isActive(.vinylBrake)
          src.stop()
        }
      })[0]
    #expect(braking, "the brake was on")
    #expect(rmsDB(out[..<(fire * deckBlock)]) > -50, "the deck played")
    let after = out[((stop + 1) * deckBlock)...]
    #expect(peak(after) < 1e-5, "stale audio after the stop: peak \(peak(after))")
  }

  /// The same with the echo on: its repeats are what the stopped record held too.
  @Test(
    .disabled(
      "echo reset: PingPong (Echo.swift) has no reset, so a stop under the brake lets the frozen repeats back in"
    ))
  func aStopUnderTheBrakeSilencesTheEcho() {
    let src = deck("trance")
    let fire = blocks(3)
    let stop = fire + blocks(1.8)
    let out = render(
      [src], blocks: stop + blocks(1.5),
      at: { b in
        if b == fire { src.fire(.vinylBrake) }
        if b == stop { src.stop() }
      })[0]
    let after = out[((stop + 1) * deckBlock)...]
    #expect(peak(after) < 1e-5, "stale echo after the stop: peak \(peak(after))")
  }

  /// Intended: a plain stop lets the tails ring out, as a deck's room does (no click to
  /// silence), and they die away.
  @Test func aStopWithoutTheBrakeLetsTheRoomRingOut() {
    let src = deck("techno", drop: [.echo])
    let stop = blocks(4)
    let out = render([src], blocks: stop + blocks(2.5), at: { b in if b == stop { src.stop() } })[0]
    let s = (stop + 1) * deckBlock
    let early = rmsDB(out[s..<(s + Int(0.2 * rate))])
    let late = rmsDB(out[(s + Int(2 * rate))..<(s + Int(2.4 * rate))])
    #expect(early > -80, "the room rings on: \(early) dB")
    #expect(late < early - 10, "and dies away: \(early) → \(late) dB")
  }

  /// Intended: a still hand on the platter holds the net clock, fires nothing, and lets what
  /// was playing (voices, room) ring out in real time; let go, the deck plays on.
  @Test func aStillHandLetsTheTailsRingOut() {
    let src = deck("techno")
    let hand = blocks(3)
    let off = hand + blocks(2.5)
    var held = 0.0
    var heldEnd = 0.0
    let out = render(
      [src], blocks: off + blocks(1),
      at: { b in
        if b == hand { src.freeze() }
        if b == hand + 2 { held = Double(src.tick) + src.tickPhase }
        if b == off {
          heldEnd = Double(src.tick) + src.tickPhase
          src.release()
        }
      })[0]
    #expect(held == heldEnd, "the clock held: \(held) → \(heldEnd)")
    let s = (hand + 1) * deckBlock
    let early = rmsDB(out[s..<(s + Int(0.1 * rate))])
    let late = rmsDB(out[(s + Int(2 * rate))..<(s + Int(2.4 * rate))])
    #expect(late < early, "the tails die away under the hand: \(early) → \(late) dB")
    #expect(Double(src.tick) + src.tickPhase > heldEnd, "let go, the deck plays on")
  }
}
