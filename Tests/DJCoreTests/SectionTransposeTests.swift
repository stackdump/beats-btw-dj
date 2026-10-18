import Testing

@testable import DJCore

// `.sectionHarmony`'s runner half (ROADMAP 6.3, dj first): `WaveRunner.prepare` builds the
// section plan (`SectionHarmony`) and every tonal lane plays its notes through it, so the band
// moves with the bridge / solo / breakdown. What it fires is what `NoteLog` captures with the
// same plan (`djctl render` reports that); home sections and decks without the flag play the
// bound notes, bit for bit.

private let sr = 22_050.0

/// Render `blocks` blocks of 128 frames, draining `ring` into `fires` as it goes.
private func render(
  _ r: WaveRunner, blocks: Int, ring: LatestRing<FireEvent>? = nil,
  fires: inout [FireEvent], cursor: inout Int
) -> [Float] {
  var out: [Float] = []
  var l = [Float](repeating: 0, count: 128)
  for i in 0..<blocks {
    l.withUnsafeMutableBufferPointer { b in r.process(b.baseAddress!, nil, frames: 128) }
    out.append(contentsOf: l)
    if let ring, i % 32 == 31 { _ = ring.drain(from: &cursor, into: &fires) }
  }
  if let ring { _ = ring.drain(from: &cursor, into: &fires) }
  return out
}

private func render(_ r: WaveRunner, blocks: Int) -> [Float] {
  var fires: [FireEvent] = []
  var cursor = 0
  return render(r, blocks: blocks, fires: &fires, cursor: &cursor)
}

/// A runner playing `p` with `fixes` from `startTick`, at 600 bpm (a tick is 551.25 frames).
private func runner(_ p: Project, _ fixes: DJMusicality.Fixes, startTick: Int = 0) -> (
  WaveRunner, WaveProject
) {
  var o = WaveOptions()
  o.musicality = fixes
  let r = WaveRunner(sampleRate: sr, opts: o)
  let prepared = WaveRunner.prepare(p, sampleRate: sr, opts: o, startTick: startTick)
  r.load(prepared: prepared)
  r.setTempo(600)
  r.play()
  return (r, prepared)
}

private let framesPerTick = sr * 60 / (600 * 4)

struct SectionTransposeTests {
  /// Without the flag there is no plan and no lane is mapped; with it, the tonal lanes of the
  /// plan's groups are, and drums and the live keys never are.
  @Test func lanesGetTheirGroup() throws {
    let song = try #require(BridgeSong.first)
    let played = song.played(.all)
    let plain = WaveRunner.prepare(played, sampleRate: sr, opts: WaveOptions())
    #expect(plain.harmony == nil)
    #expect(plain.lanes.allSatisfy { $0.harmonyGroup == -1 })
    var o = WaveOptions()
    o.musicality = [.sectionHarmony]
    let mapped = WaveRunner.prepare(played, sampleRate: sr, opts: o)
    let h = try #require(mapped.harmony)
    #expect(h == SectionHarmony(project: played))
    #expect(mapped.lanes[mapped.liveLane].harmonyGroup == -1)
    for lane in mapped.lanes where !lane.isTonal { #expect(lane.harmonyGroup == -1) }
    let groups = Set(mapped.lanes.map(\.harmonyGroup).filter { $0 >= 0 })
    #expect(!groups.isEmpty)
    #expect(groups.allSatisfy { $0 < h.groups.count })
  }

  /// Across the first moved section's start, the runner fires exactly the notes `NoteLog`
  /// captures through the same plan (the `FireEvent` note is the mapped one), and some of them
  /// differ from the bound notes.
  @Test func firedNotesAreTheMappedLog() throws {
    let song = try #require(BridgeSong.first)
    let played = song.played(.all)
    let h = try #require(SectionHarmony(project: played))
    let k = try #require(h.degrees.firstIndex { $0 != 0 })
    let from = max(0, h.start[k] - 32)
    let ticks = 96
    let (r, proj) = runner(played, [.sectionHarmony], startTick: from)
    let ring = LatestRing<FireEvent>(capacity: 1 << 14)
    r.fireRing = ring
    var fires: [FireEvent] = []
    var cursor = 0
    _ = render(
      r, blocks: Int(Double(ticks) * framesPerTick / 128), ring: ring, fires: &fires,
      cursor: &cursor)
    let last = fires.map { Int($0.tick) }.max() ?? 0
    #expect(last > h.start[k] + 16)

    struct Fire: Hashable {
      var tick: Int
      var net: String
      var note: Int
    }
    let voiced = Set(proj.byNet.keys)
    let got = fires.filter { $0.flags.isDisjoint(with: .drum) && !isDrumChannel(Int($0.channel)) }
      .map { Fire(tick: Int($0.tick), net: proj.graph.nets[Int($0.net)].id, note: Int($0.note)) }
    func expected(_ harmony: SectionHarmony?) -> [Fire] {
      NoteLog.capture(played, ticks: last, harmony: harmony)
        .filter { $0.tick > from && !$0.isDrum && voiced.contains($0.net) }
        .map { Fire(tick: $0.tick, net: $0.net, note: $0.note) }
    }
    let want = expected(h)
    #expect(!got.isEmpty)
    #expect(
      got.sorted { ($0.tick, $0.net, $0.note) < ($1.tick, $1.net, $1.note) }
        == want.sorted { ($0.tick, $0.net, $0.note) < ($1.tick, $1.net, $1.note) })
    #expect(Set(want) != Set(expected(nil)), "the plan moves some note")
  }

  /// Home sections play the bound notes: up to the first moved section the flag renders the
  /// same samples as no flag, and a loop (no plan) renders the same throughout.
  @Test func homeSectionsAndLoopsRenderAsBound() throws {
    let song = try #require(BridgeSong.first)
    let played = song.played(.all)
    let h = try #require(SectionHarmony(project: played))
    let k = try #require(h.degrees.firstIndex { $0 != 0 })
    let from = max(0, h.start[k] - 48)
    let blocks = Int(Double(h.start[k] - from - 1) * framesPerTick / 128)
    let on = render(runner(played, [.sectionHarmony], startTick: from).0, blocks: blocks)
    let off = render(runner(played, [], startTick: from).0, blocks: blocks)
    #expect(on == off)
    #expect(on.contains { $0 != 0 })

    let loop = TrackSpec(genre: song.spec.genre, seed: song.spec.seed, structure: nil)
    let lp = DJMusicality.apply(loop.project(), spec: loop)
    #expect(SectionHarmony(project: lp) == nil)
    #expect(
      render(runner(lp, [.sectionHarmony]).0, blocks: 400) == render(runner(lp, []).0, blocks: 400))
  }

  /// Live keys play what is pressed, whatever the section.
  @Test func liveKeysAreNotMapped() throws {
    let song = try #require(BridgeSong.first)
    let played = song.played(.all)
    let h = try #require(SectionHarmony(project: played))
    let k = try #require(h.degrees.firstIndex { $0 != 0 })
    let (r, proj) = runner(played, [.sectionHarmony], startTick: h.start[k])
    #expect(proj.lanes[proj.liveLane].harmonyGroup == -1)
    // nothing but the key: every net muted
    for n in proj.graph.nets { r.setMute(n.id, true) }
    _ = render(r, blocks: 8)
    r.noteOn(69, velocity: 100)
    _ = render(r, blocks: 2)
    #expect(proj.lanes[proj.liveLane].heldNote.contains(69))
    r.noteOff(69)
  }
}
