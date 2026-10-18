import Testing

@testable import DJCore

// `.riser` (`Riser.swift`): a noise riser over the last two bars of each buildup into a drop.
// Renders of small projects through a linear master, 120 BPM: a step is 0.125 s.

private let sr = 48_000.0
private let step = Int(0.125 * sr)

private func ring(_ group: String, channel: Int, _ notes: [(step: Int, note: Int)], ms: Int)
  -> NetBundle
{
  var n = NetBundle.ring(16)
  for x in notes { n.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: ms) }
  n.track.channel = channel
  n.track.group = group
  return n
}

/// Four bars of buildup into four of drop: kick on the beats, an offbeat bass. The riser
/// window is steps 32 ..< 64.
private func riserProject(_ sections: [Section]? = nil) -> Project {
  var p = Project()
  p.tempo = 120
  p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50)
  p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100)
  p.structure =
    sections ?? [Section(name: "buildup", steps: 64), Section(name: "drop", steps: 64)]
  return p
}

private func options(_ fixes: DJMusicality.Fixes) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  return o
}

/// Left and right of `p` from `startTick`, for `seconds`.
private func render(
  _ p: Project, _ fixes: DJMusicality.Fixes, startTick: Int = 0, seconds: Double = 12
) -> (l: [Float], r: [Float]) {
  let o = options(fixes)
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: startTick))
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

/// `a - b`, sample by sample.
private func minus(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 - $1 } }

private func rmsDB(_ x: [Float], _ a: Int, _ b: Int) -> Double { rmsDB(x[a..<b]) }

struct RiserTests {
  /// The flag is the registry's: in `Fixes.all` and by name, and never in the parity options.
  @Test func flagIsRegistered() {
    #expect(DJMusicality.Fixes.all.contains(.riser))
    #expect(DJMusicality.Fixes.named["riser"] == .riser)
    #expect(!WaveOptions().musicality.contains(.riser))
    #expect(WaveOptions.extended.musicality.contains(.riser))
  }

  /// The last two bars of each buildup that lands on a drop or chorus; a short buildup whole;
  /// nothing into a breakdown, nothing out of a verse.
  @Test func windowsAreTheBuildupsLastTwoBars() {
    #expect(DJMusicality.riserWindows(riserProject()) == [32..<64])
    let short = riserProject([
      Section(name: "intro", steps: 32), Section(name: "buildup", steps: 16),
      Section(name: "chorus", steps: 64), Section(name: "buildup", steps: 64),
      Section(name: "breakdown", steps: 32), Section(name: "verse", steps: 32),
      Section(name: "drop", steps: 32),
    ])
    #expect(DJMusicality.riserWindows(short) == [32..<48])
    #expect(DJMusicality.riserWindows(Project()).isEmpty)
    let edm = TrackSpec(genre: "edm", seed: 42, structure: "extended").project()
    #expect(!DJMusicality.riserWindows(edm).isEmpty)
    let prepared = WaveRunner.prepare(edm, sampleRate: sr, opts: options([.riser]))
    #expect(prepared.riser != nil)
    #expect(WaveRunner.prepare(edm, sampleRate: sr, opts: options([])).riser == nil)
  }

  /// The sweep's ends are the spec's: 300 Hz at −30 dB to 8 kHz at −12 dB.
  @Test func sweepEnds() {
    let a = RiserSpec.at(0)
    let b = RiserSpec.at(1)
    #expect(abs(a.hz - 300) < 1e-9 && abs(a.db + 30) < 1e-9)
    #expect(abs(b.hz - 8000) < 1e-6 && abs(b.db + 12) < 1e-9)
    #expect(RiserSpec.at(0.5).hz > 1500 && RiserSpec.at(0.5).hz < 1600)
  }

  /// The high band climbs through the window: by more than 9 dB, beat after beat (ρ ≥ 0.9).
  @Test func highBandRises() {
    let p = riserProject()
    let on = render(p, [.riser])
    let rises = RiserRise.measure(left: on.l, right: on.r, sampleRate: sr, project: p)
    #expect(rises.count == 1)
    let rise = rises.first
    #expect((rise?.riseDB ?? 0) >= 9, "rise \(rise?.riseDB ?? 0) dB")
    #expect((rise?.spearman ?? 0) >= 0.9, "ρ \(rise?.spearman ?? 0)")
    print("riserRiseDB \(rise?.riseDB ?? 0) spearman \(rise?.spearman ?? 0)")
    // without it the band is flat (the same kick and bass every beat)
    let off = render(p, [])
    let flat = RiserRise.measure(left: off.l, right: off.r, sampleRate: sr, project: p)
    #expect(abs(flat.first?.riseDB ?? 99) < 3)
  }

  /// Before the first window the render is the bytes it was without the riser; two renders
  /// are identical.
  @Test func silentBeforeItsWindowAndDeterministic() {
    let p = riserProject()
    let on = render(p, [.riser])
    let off = render(p, [])
    let before = 32 * step
    #expect(Array(on.l[0..<before]) == Array(off.l[0..<before]))
    #expect(Array(on.r[0..<before]) == Array(off.r[0..<before]))
    let again = render(p, [.riser])
    // (compared as Bools: a failing #expect on two renders would print a million floats)
    let same = again.l == on.l && again.r == on.r
    #expect(same)
    #expect(on.l != off.l)
  }

  /// It climbs to −12 dB and cuts at the drop: nothing of it a few ms into the drop.
  @Test func cutsAtTheDrop() {
    let p = riserProject()
    let only = minus(render(p, [.riser]).l, render(p, []).l)
    let drop = 64 * step
    let last = rmsDB(only, drop - 4 * step, drop)
    #expect(abs(last - RiserSpec.toDB) < 2.5, "last beat \(last) dB")
    let first = rmsDB(only, 32 * step + step / 2, 36 * step)
    #expect(abs(first - (-27.75)) < 3, "first beat \(first) dB")
    #expect(rmsDB(only, drop + Int(0.03 * sr), drop + 8 * step) < -100)
  }

  /// A start inside the window (a section jump) plays the riser where the song has it.
  @Test func aJumpStartsInPhase() {
    let p = riserProject()
    let full = minus(render(p, [.riser]).l, render(p, []).l)
    let late = minus(
      render(p, [.riser], startTick: 48, seconds: 4).l, render(p, [], startTick: 48, seconds: 4).l)
    for beat in 0..<4 {
      let a = beat * 4 * step + step / 2
      let b = (beat + 1) * 4 * step
      let want = rmsDB(full, 48 * step + a, 48 * step + b)
      #expect(abs(rmsDB(late, a, b) - want) < 1.5, "beat \(beat)")
    }
    // a start on the drop plays none of it
    let atDrop = minus(
      render(p, [.riser], startTick: 64, seconds: 2).l, render(p, [], startTick: 64, seconds: 2).l)
    #expect(rmsDB(atDrop, 0, atDrop.count) < -100)
  }

  /// `.stereo` gives it a side that widens through the window; without, it is mono.
  @Test func widensUnderStereo() {
    let p = riserProject()
    let mono = render(p, [.riser])
    #expect(mono.l == mono.r)
    let wide = render(p, [.riser, .stereo])
    let plain = render(p, [.stereo])
    let side = zip(minus(wide.l, plain.l), minus(wide.r, plain.r)).map { ($0 - $1) / 2 }
    let early = rmsDB(side, 32 * step + step / 2, 40 * step)
    let late = rmsDB(side, 56 * step, 64 * step)
    #expect(early > -80 && late > early + 9, "side \(early) → \(late) dB")
  }

  /// `.space` sends it to the room: a tail rings on into the drop.
  @Test func sendsToTheRoom() {
    let p = riserProject()
    let dry = minus(render(p, [.riser]).l, render(p, []).l)
    let wet = minus(render(p, [.riser, .space]).l, render(p, [.space]).l)
    let drop = 64 * step
    let a = drop + Int(0.03 * sr)
    let b = drop + Int(0.3 * sr)
    #expect(rmsDB(dry, a, b) < -100)
    #expect(rmsDB(wet, a, b) > -60, "room tail \(rmsDB(wet, a, b)) dB")
  }

  /// Spearman's ρ: 1 rising, −1 falling, ties by their mean rank.
  @Test func spearman() {
    #expect(abs(RiserRise.spearman([1, 2, 3, 4]) - 1) < 1e-12)
    #expect(abs(RiserRise.spearman([4, 3, 2, 1]) + 1) < 1e-12)
    #expect(RiserRise.spearman([1, 3, 2, 4]) > 0.7)
    #expect(RiserRise.spearman([2, 2]) == 0)
  }
}
