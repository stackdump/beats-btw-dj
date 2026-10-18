import Testing

@testable import DJCore

// `RestSchedule`: the runner's rests (`.dropGap`, and 6.2's gestures), built at prepare and read
// with a cursor on the audio thread. Renders of small projects through a linear master,
// 120 BPM: a step is 0.125 s.

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

/// Four bars of buildup into four of drop, kick on the beats, an offbeat bass, or each alone.
func restProject(kick: Bool = true, bass: Bool = true) -> Project {
  var p = Project()
  p.tempo = 120
  if kick { p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50) }
  if bass { p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100) }
  p.structure = [Section(name: "buildup", steps: 64), Section(name: "drop", steps: 64)]
  return p
}

private func options(_ fixes: DJMusicality.Fixes, rests: RestSchedule? = nil) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.trackRests = rests
  return o
}

private func play(_ r: WaveRunner, seconds: Double) -> [Float] {
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

private func render(
  _ p: Project, _ o: WaveOptions, startTick: Int = 0, seconds: Double = 10
) -> [Float] {
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: startTick))
  r.play()
  return play(r, seconds: seconds)
}

private func rmsDB(_ x: [Float], _ a: Int, _ b: Int) -> Double { rmsDB(x[a..<b]) }

struct RestScheduleTests {
  typealias Entry = RestSchedule.Entry

  /// Overlapping gestures become disjoint stretches, each with every mask that covers it;
  /// empty stretches and empty masks go.
  @Test func mergingMakesDisjointStretches() {
    let s = RestSchedule(merging: [
      Entry(from: 8, to: 16, mask: .kick),
      Entry(from: 0, to: 12, mask: .bass),
      Entry(from: 20, to: 20, mask: .drums),
      Entry(from: 30, to: 40, mask: []),
      Entry(from: 40, to: 44, mask: .melody),
    ])
    #expect(
      s.entries == [
        Entry(from: 0, to: 8, mask: .bass), Entry(from: 8, to: 12, mask: [.bass, .kick]),
        Entry(from: 12, to: 16, mask: .kick), Entry(from: 40, to: 44, mask: .melody),
      ])
    #expect(RestSchedule(merging: []).isEmpty && RestSchedule.empty.isEmpty)
  }

  /// `.dropGap` is the drop gaps exactly: the rhythm section for `dropGapSteps` from each.
  @Test func dropGapIsTheGaps() {
    let edm = TrackSpec(genre: "edm", seed: 42, structure: "extended").project()
    let gaps = DJMusicality.dropGaps(edm)
    #expect(!gaps.isEmpty)
    let s = RestSchedule.build(edm, fixes: .dropGap)
    #expect(
      s.entries
        == gaps.map { Entry(from: $0, to: $0 + DJMusicality.dropGapSteps, mask: .rhythm) })
    #expect(RestSchedule.build(edm, fixes: []).isEmpty)
    #expect(
      RestSchedule.build(edm, fixes: .all.subtracting([.dropGap, .kickOut])).isEmpty,
      "stubs: no rests")
    #expect(RestSchedule.build(edm, fixes: .all.subtracting(.kickOut)) == s)
    #expect(
      RestSchedule.build(edm, fixes: .all)
        == RestSchedule(merging: s.entries + DJMusicality.kickOutRests(edm)))
  }

  /// A lane's class: the drop gap rests kick, non-fill drums and bass, nothing else.
  @Test func laneClasses() {
    typealias C = RestSchedule.Class
    #expect(C.of(kind: "kick", group: "drums", net: "kick") == .kick)
    #expect(C.of(kind: "snare", group: "drums", net: "snare") == .drums)
    #expect(C.of(kind: "openhat", group: "drums", net: "hihat") == .drums)
    #expect(C.of(kind: "crash", group: "drums", net: "fill-1").isEmpty)
    #expect(C.of(kind: "kick", group: "drums", net: "fill-2").isEmpty)
    #expect(C.of(kind: "tonal", group: "bass", net: "bass") == .bass)
    #expect(C.of(kind: "tonal", group: "harmony", net: "harmony") == .harmony)
    #expect(C.of(kind: "tonal", group: "melody", net: "melody-0") == .melody)
    #expect(C.of(kind: "tonal", group: "arp", net: "arp") == .arp)
    #expect(C.of(kind: "tonal", group: "lead2", net: "x") == .tonal)
    #expect(C.rhythm.isDisjoint(with: C.melodic))
  }

  /// The cursor reads what a scan reads: walking forward, after a jump back, after a reset,
  /// and starting anywhere.
  @Test func cursorMatchesAScan() {
    let s = RestSchedule(merging: [
      Entry(from: 4, to: 8, mask: .kick), Entry(from: 6, to: 10, mask: .bass),
      Entry(from: 60, to: 64, mask: .rhythm), Entry(from: 64, to: 80, mask: .melody),
    ])
    var c = RestSchedule.Cursor()
    for t in 0..<100 { #expect(c.mask(at: t, in: s) == s.mask(at: t), "step \(t)") }
    for t in [70, 5, 9, 62, 0, 99, 63, 64] {
      #expect(c.mask(at: t, in: s) == s.mask(at: t), "jump to \(t)")
    }
    c.reset()
    for t in 50..<90 { #expect(c.mask(at: t, in: s) == s.mask(at: t), "step \(t)") }
    var empty = RestSchedule.Cursor()
    #expect(empty.mask(at: 5, in: .empty).isEmpty)
  }

  /// A gesture rests only its classes: the kick out for a bar, the bass playing on, and the
  /// render before it untouched.
  @Test func aScheduleRestsItsClassesOnly() {
    let s = RestSchedule(merging: [Entry(from: 16, to: 32, mask: .kick)])
    let both = render(restProject(), options([.dropGap], rests: s), seconds: 6)
    let plain = render(restProject(), options([], rests: .empty), seconds: 6)
    let bassOnly = render(restProject(kick: false), options([]), seconds: 6)
    #expect(Array(both[0..<(16 * step)]) == Array(plain[0..<(16 * step)]))
    // in the bar the kick is out (past the last kick's tail) only the bass plays
    let a = 16 * step + step / 2
    let b = 32 * step
    #expect(abs(rmsDB(both, a, b) - rmsDB(bassOnly, a, b)) < 0.5)
    #expect(rmsDB(plain, a, b) > rmsDB(both, a, b) + 1)
  }

  /// `trackRests` is what plays: given, `prepare` does not build one (`.dropGap` on with no
  /// rests renders as without it).
  @Test func trackRestsReplaceTheBuild() {
    let p = restProject()
    // (compared as Bools: a failing #expect on two renders would print half a million floats)
    let unscheduled = render(p, options([.dropGap], rests: .empty)) == render(p, options([]))
    #expect(unscheduled)
    let built = RestSchedule.build(p, fixes: .dropGap)
    let same = render(p, options([.dropGap], rests: built)) == render(p, options([.dropGap]))
    #expect(same)
    #expect(WaveRunner.prepare(p, sampleRate: sr, opts: options([.dropGap])).rests == built)
  }

  /// Starting past the top (a section launch) and stopping then playing again (the tick goes
  /// back to 0) both find the gap where it is.
  @Test func cursorFollowsStartsAndStops() {
    let p = restProject()
    let gapped = render(p, options([.dropGap]))
    let gap = 60 * step
    // a start at step 48 plays what the full render plays from 48, on the same tick grid
    let late = render(p, options([.dropGap]), startTick: 48, seconds: 4)
    let plainLate = render(p, options([]), startTick: 48, seconds: 4)
    let g = 12 * step
    #expect(
      rmsDB(late, g + step / 4, g + 4 * step) < rmsDB(plainLate, g + step / 4, g + 4 * step) - 20)
    // play past the gap, stop, play again from the top: the second pass rests too
    let o = options([.dropGap])
    let r = WaveRunner(sampleRate: sr, opts: o)
    r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
    r.play()
    _ = play(r, seconds: 10)
    r.stop()
    r.play()
    let again = play(r, seconds: 10)
    let inGap = rmsDB(again, gap + step / 4, gap + 4 * step)
    #expect(abs(inGap - rmsDB(gapped, gap + step / 4, gap + 4 * step)) < 1)
    #expect(inGap < rmsDB(again, gap - 4 * step, gap) - 20)
  }
}

@MainActor
struct RestScheduleDeckTests {
  /// Another start of the same song (a section launch) plays the song's rest schedule.
  @Test func sectionJumpsKeepTheSongsRests() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "edm", seed: 42, structure: "standard"))
    let song = try #require(deck.wave.latest)
    #expect(!song.rests.isEmpty)
    #expect(deck.sameSongOptions(deck.waveOptions).trackRests == song.rests)
    #expect(await deck.jumpToSection(2))
    let launched = try #require(deck.wave.latest)
    #expect(launched.generation > song.generation && launched.rests == song.rests)
  }
}
