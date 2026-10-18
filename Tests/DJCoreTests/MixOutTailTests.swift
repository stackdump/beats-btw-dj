import Testing

@testable import DJCore

// `MixOutTail` (`WaveOptions.tail`, ROADMAP 6.2 performable form): from its first tick only the
// drums-forward lanes play, the song's stop-transport is ignored, and the deck stops on the tail's
// last bar line. Small projects through a linear master, 120 BPM at 48 kHz: a step is 6000
// frames, so step k ticks at frame k × 6000 exactly.

private let sr = 48_000.0
private let step = Int(0.125 * sr)
private let block = 256

private func ring(_ group: String, channel: Int, _ notes: [(step: Int, note: Int)], ms: Int)
  -> NetBundle
{
  var n = NetBundle.ring(16)
  for x in notes { n.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: ms) }
  n.track.channel = channel
  n.track.group = group
  return n
}

/// Eight bars (four of verse, four of outro) of kick, snare, bass and a melody, ending in beats'
/// `struct-stop` (stop-transport on the last step). `melody: false` leaves the lead out.
func tailProject(melody: Bool = true) -> Project {
  var p = Project()
  p.tempo = 120
  p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50)
  p.nets["snare"] = ring("drums", channel: 10, [4, 12].map { ($0, 38) }, ms: 60)
  p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100)
  if melody {
    p.nets["melody"] = ring("melody", channel: 1, [0, 3, 6, 8, 11, 14].map { ($0, 69) }, ms: 100)
  }
  p.structure = [Section(name: "verse", steps: 64), Section(name: "outro", steps: 64)]
  p.nets["struct-stop"] = buildControlBundle(
    steps: 128, ctrlAt: [127: controlBinding("stop-transport", target: "")], sink: true)
  return p
}

func tailOptions(_ tail: MixOutTail?, fixes: DJMusicality.Fixes = []) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.tail = tail
  return o
}

/// `seconds` of the runner from `play()`, and the block (frames) in which it stopped, if it did.
private func play(
  _ p: Project, _ o: WaveOptions, startTick: Int = 0, seconds: Double
) -> (out: [Float], stop: Range<Int>?) {
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: startTick))
  r.play()
  var out = [Float](repeating: 0, count: Int(seconds * sr))
  var stop: Range<Int>?
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(block, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n)
      if stop == nil && r.stopped { stop = off..<(off + n) }
      off += n
    }
  }
  return (out, stop)
}

private func rmsDB(_ x: [Float], _ a: Int, _ b: Int) -> Double { rmsDB(x[a..<b]) }

struct MixOutTailTests {
  /// The tail's rest is the melodic classes, from its first tick to its stop; on a schedule it
  /// merges with what is there.
  @Test func tailRestsTheMelodicClasses() {
    let t = MixOutTail(fromTick: 64, bars: 4)
    #expect(t.endTick == 128 && MixOutTail(fromTick: 32).endTick == 32 + 256)
    #expect(t.entry == RestSchedule.Entry(from: 64, to: 128, mask: .melodic))
    #expect(RestSchedule.Class.melodic.isDisjoint(with: .rhythm))
    let gap = RestSchedule(merging: [.init(from: 60, to: 68, mask: .rhythm)])
    let s = gap.with(tail: t)
    #expect(s.mask(at: 59).isEmpty && s.mask(at: 60) == .rhythm)
    #expect(s.mask(at: 64) == [.rhythm, .melodic] && s.mask(at: 70) == .melodic)
    #expect(s.mask(at: 128).isEmpty)
  }

  /// No tail: nothing changes. The project has no tail, its rests are the song's, and it stops
  /// where beats' stop-transport stops it (on step 127's tick).
  @Test func noTailEndsWithTheSong() throws {
    let p = tailProject()
    let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: tailOptions(nil))
    #expect(prepared.tail == nil && prepared.rests == prepared.songRests)
    #expect(WaveOptions().tail == nil)
    let (_, stop) = play(p, tailOptions(nil), seconds: 18)
    let s = try #require(stop)
    #expect(s.contains(127 * step), "stopped in \(s), the song's end is frame \(127 * step)")
  }

  /// With a tail from the outro for 16 bars: the render is the song's until the outro, then
  /// the drums-forward lanes alone (as the project without its lead), on past the song's end,
  /// and the deck stops on the tail's last bar line.
  @Test func tailPlaysPastTheSongAndStopsOnItsBarLine() throws {
    let p = tailProject()
    let tail = MixOutTail(fromTick: 64, bars: 16)
    let (withTail, stop) = play(p, tailOptions(tail), seconds: 42)
    let (song, _) = play(p, tailOptions(nil), seconds: 42)
    let (noLead, _) = play(tailProject(melody: false), tailOptions(nil), seconds: 42)
    let s = try #require(stop)
    #expect(
      s.contains(tail.endTick * step), "stopped in \(s), the bar line is \(tail.endTick * step)")
    // (compared as a Bool: a failing #expect on two renders would print the floats)
    let before = Array(withTail[0..<(64 * step)]) == Array(song[0..<(64 * step)])
    #expect(before, "untouched before the tail")
    // in the tail (past the lead's last note) only kick, snare and bass play
    let a = 64 * step + step
    let b = 96 * step
    #expect(abs(rmsDB(withTail, a, b) - rmsDB(noLead, a, b)) < 0.5)
    #expect(rmsDB(song, a, b) > rmsDB(withTail, a, b) + 1)
    // past the song's own end the rhythm plays on, as loud as earlier in the tail
    let c = 200 * step
    #expect(abs(rmsDB(withTail, c, c + 32 * step) - rmsDB(withTail, a, b)) < 1)
    // and it is silent once the last voices have died away
    let quiet = tail.endTick * step + Int(sr)
    #expect(rmsDB(withTail, quiet, quiet + Int(sr) / 2) < -80)
  }

  /// A start inside the tail (a section launch) stops on the same bar line, in song ticks.
  @Test func aLateStartStopsOnTheSameBarLine() throws {
    let p = tailProject()
    let tail = MixOutTail(fromTick: 64, bars: 4)
    let (out, stop) = play(p, tailOptions(tail), startTick: 96, seconds: 6)
    let s = try #require(stop)
    let end = (tail.endTick - 96) * step
    #expect(s.contains(end), "stopped in \(s), the bar line is \(end)")
    #expect(rmsDB(out, step, 16 * step) > -60, "the rhythm plays up to it")
  }

  /// The room rings out after the stop: the transport stops, the reverb's return goes on and
  /// dies away (it is not cut at the bar line).
  @Test func theRoomRingsOut() throws {
    let p = tailProject()
    let tail = MixOutTail(fromTick: 64, bars: 4)
    let (out, stop) = play(p, tailOptions(tail, fixes: [.space]), seconds: 24)
    let s = try #require(stop)
    let after = s.upperBound + Int(0.3 * sr)
    let ringing = rmsDB(out, after, after + Int(0.2 * sr))
    #expect(ringing > -90, "the room still rings 0.3 s after the stop (\(ringing) dB)")
    #expect(ringing < rmsDB(out, s.lowerBound - 16 * step, s.lowerBound) - 6)
    let late = s.upperBound + 6 * Int(sr)
    #expect(rmsDB(out, late, late + Int(0.5 * sr)) < ringing - 20, "and dies away")
  }
}

@MainActor
struct MixOutTailDeckTests {
  /// Another start of the song keeps the playing project's tail and its song rests (without
  /// the tail's, which the next prepare adds again).
  @Test func sameSongOptionsKeepTheTail() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "edm", seed: 42, structure: "standard"))
    let song = try #require(deck.netProject)
    #expect(deck.sameSongOptions(deck.waveOptions).tail == nil)
    let tail = MixOutTail(fromTick: 128, bars: 16)
    var o = deck.sameSongOptions(deck.waveOptions)
    o.tail = tail
    deck.wave.load(WaveRunner.prepare(song, sampleRate: deck.wave.sampleRate, opts: o))
    let tailed = try #require(deck.wave.latest)
    #expect(tailed.tail == tail && tailed.rests == tailed.songRests.with(tail: tail))
    let again = deck.sameSongOptions(deck.waveOptions)
    #expect(again.tail == tail && again.trackRests == tailed.songRests)
    var other = deck.waveOptions
    other.tail = MixOutTail(fromTick: 0, bars: 1)
    #expect(deck.sameSongOptions(other).tail == other.tail, "a tail asked for wins")
    #expect(await deck.jumpToSection(1))
    #expect(deck.wave.latest?.tail == tail)
  }
}
