import Testing

@testable import DJCore

// `.hook` (Hook.swift): one seeded chord-tone hook, stated on the first bar of every melody
// slot window, varied by section.

private let songGenres = ["techno", "house", "edm", "trance", "lofi", "synthwave"]

private func spec(_ genre: String, _ seed: Double = 42) -> TrackSpec {
  TrackSpec(genre: genre, seed: seed, structure: "standard")
}

private func played(_ s: TrackSpec, fixes: DJMusicality.Fixes = .all) -> Project {
  DJMusicality.apply(s.project(), spec: s, fixes: fixes)
}

private func report(_ p: Project) -> MusicalityReport {
  let (notes, controls) = NoteLog.captureAll(p)
  return MusicalityReport(project: p, log: notes, controls: controls)
}

private func moves(_ notes: [Int]) -> [Int] {
  zip(notes, notes.dropFirst()).map { ($1 - $0).signum() }
}

/// A one-bar hook with a known shape: up, up, down, level.
private let cell: HookCell = {
  var mask = [Bool](repeating: false, count: 16)
  var target = [Int](repeating: -1, count: 16)
  for (s, t) in [(0, 0), (3, 2), (6, 4), (10, 2), (12, 2)] {
    mask[s] = true
    target[s] = t
  }
  return HookCell(mask: mask, target: target)
}()

private let cMajor = Set([0, 2, 4, 5, 7, 9, 11])
private let cScale = (0...127).filter { cMajor.contains($0 % 12) }

struct HookTests {
  /// Each mode on a hand-built hook: Play keeps the sixteenths and the moves, Transposed the
  /// moves a third up, Inverted turns every move, Fragment keeps the first half, Augmented
  /// plays the first half at half speed; every note is a tone of the chord given.
  @Test func modesShapeTheBar() {
    func bar(_ mode: Int, chord: [Int] = [0, 4, 7]) -> [(step: Int, note: Int)] {
      DJMusicality.hookBar(cell, mode: mode, base: 72, chord: chord, key: cMajor, scale: cScale)
    }
    let play = bar(MotifMode.play)
    #expect(play.map(\.step) == [0, 3, 6, 10, 12])
    #expect(moves(play.map(\.note)) == [1, 1, -1, 0])
    #expect(play.first?.note == 72)
    let transposed = bar(MotifMode.transposed)
    #expect(transposed.map(\.step) == play.map(\.step))
    #expect(moves(transposed.map(\.note)) == [1, 1, -1, 0])
    #expect(transposed[0].note > play[0].note)
    let inverted = bar(MotifMode.inverted)
    #expect(inverted.map(\.step) == play.map(\.step))
    #expect(moves(inverted.map(\.note)) == [-1, -1, 1, 0])
    #expect(bar(MotifMode.fragment).map(\.step) == [0, 3, 6])
    #expect(bar(MotifMode.augmented).map(\.step) == [0, 6, 12])
    for m in [MotifMode.play, MotifMode.transposed, MotifMode.inverted] {
      // on another chord (A minor) the shape stays and every note is its tone
      let am = bar(m, chord: [9, 0, 4])
      #expect(am.allSatisfy { [9, 0, 4].contains($0.note % 12) }, "mode \(m)")
      #expect(moves(am.map(\.note)) == moves(bar(m).map(\.note)), "mode \(m)")
    }
  }

  /// In what a deck plays, every melody window's first bar is the hook: its sixteenths, on
  /// the bar's chord, with its moves (turned in a bridge). Checked right after the stage.
  @Test(arguments: songGenres)
  func everyMelodyWindowStatesTheHook(genre: String) throws {
    let s = spec(genre)
    let g = try #require(BeatsTables.shared.genres[genre])
    var p = played(s, fixes: .all.subtracting(.hook))
    DJMusicality.placeHook(&p, genre: g, spec: s)
    let hook = buildHook(genre: genre, seed: s.seed, bars: 1, density: g.melodyDensity)
    let rhythm = (0..<16).filter { hook.mask[$0] }
    let shape = moves(rhythm.map { hook.target[$0] })
    let (chords, padBars) = DJMusicality.padChords(p)
    try #require(padBars > 0)
    var checked = 0
    for (id, ws) in DJMusicality.slotWindows(p, role: "melody") {
      let nb = try #require(p.nets[id])
      guard DJMusicality.isBarRing(nb), let w = ws.first, let r = w.ringStart else { continue }
      let bar = DJMusicality.ringNotes(nb).filter { $0.step >= r && $0.step < r + 16 }
      #expect(bar.map { $0.step - r } == rhythm, "\(genre) \(id) in \(w.sectionName)")
      let chord = chords[(w.start / 16) % padBars] ?? []
      #expect(
        chord.isEmpty || bar.allSatisfy { chord.contains(DJMusicality.pc($0.note)) },
        "\(genre) \(id): \(bar.map(\.note)) on \(chord)")
      let turned = hookModes[w.sectionName] == MotifMode.inverted
      #expect(
        moves(bar.map(\.note)) == (turned ? shape.map { -$0 } : shape), "\(genre) \(id)")
      checked += 1
    }
    #expect(checked > 0, "\(genre): no melody window")
  }

  /// The hook recurs in every later melodic section and bar 1 of each phrase is on the chord,
  /// while bar 2 still restates bar 1 (`.motif`). A/B against the same track without the
  /// stage; the numbers print for the notes.
  @Test(arguments: songGenres)
  func hookRecursAcrossSections(genre: String) {
    let s = spec(genre)
    let on = report(played(s))
    let off = report(played(s, fixes: .all.subtracting(.hook)))
    print(
      "hook \(genre): hook \(off.hookRecurrence ?? -1) → \(on.hookRecurrence ?? -1), "
        + "b1ct \(off.barOneChordTones ?? -1) → \(on.barOneChordTones ?? -1), "
        + "idea \(off.melodyIdeaRepeats ?? -1) → \(on.melodyIdeaRepeats ?? -1)")
    if let h = on.hookRecurrence { #expect(h >= 0.9, "\(genre): hookRecurrence \(h)") }
    if let b = on.barOneChordTones { #expect(b >= 0.95, "\(genre): barOneChordTones \(b)") }
    if let i = on.melodyIdeaRepeats { #expect(i == 1, "\(genre): melodyIdeaRepeats \(i)") }
  }

  /// With compose's own `hook` technique the slots already are the hook: the stage leaves
  /// them alone.
  @Test func composeHookTurnsTheStageOff() {
    var s = spec("edm")
    s.extra["hook"] = .bool(true)
    func melody(_ p: Project) -> [[Int]] {
      NoteLog.capture(p).filter { $0.group == "melody" }.map { [$0.tick, $0.note] }
    }
    let with = melody(played(s))
    #expect(!with.isEmpty)
    #expect(with == melody(played(s, fixes: .all.subtracting(.hook))))
  }

  /// Seeds keep their own melodies: the hook is the seed's, so two seeds' songs share few
  /// notes (pitch at a tick), as `VarietyTests` holds for loops.
  @Test(arguments: ["techno", "trance", "lofi"])
  func seedsKeepTheirOwnMelodies(genre: String) {
    let seeds: [Double] = [7, 42, 1234, 98_765, 31_337, 500_001]
    let tunes = seeds.map { seed in
      Set(
        NoteLog.capture(played(spec(genre, seed))).filter { $0.group == "melody" }
          .map { [$0.tick, $0.note] })
    }
    var sum = 0.0
    var pairs = 0
    for i in tunes.indices {
      for j in tunes.indices where j > i {
        sum +=
          Double(tunes[i].intersection(tunes[j]).count)
          / Double(max(1, tunes[i].union(tunes[j]).count))
        pairs += 1
      }
    }
    #expect(sum / Double(pairs) <= 0.25, "\(genre): mean pitch Jaccard \(sum / Double(pairs))")
  }
}
