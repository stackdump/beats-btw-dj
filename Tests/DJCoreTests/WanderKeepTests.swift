import Testing

@testable import DJCore

// `keep:<role>` carries the role's part seed into every same-genre swap (`Wander.carry`), so a
// kept bass plays its line on through new seeds; a genre hop drops it, and so does freeing the
// keep at the next swap.

private let rate = 22_050.0

private func context(
  _ spec: TrackSpec = TrackSpec(genre: "techno", seed: 42, structure: "standard"),
  locks: Set<String>
) -> WanderContext {
  let roles = ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"]
  let voices = [
    WanderVoice(
      roles: ["kick", "snare", "hihat"], channel: 10, instrument: "drums",
      options: ["drums", "drums-909"]),
    WanderVoice(
      roles: ["bass"], channel: 2, instrument: "sub-bass", options: ["sub-bass", "acid"]),
    WanderVoice(roles: ["melody"], channel: 1, instrument: "lead", options: ["lead", "pluck"]),
    WanderVoice(roles: ["arp"], channel: 4, instrument: "arp", options: ["arp", "bell"]),
  ]
  return WanderContext(
    deck: "A", spec: spec, isLoop: false, roles: roles, rolesOn: Set(roles), disabledRoles: [],
    stemsMuted: [], lockedActions: [], locks: locks, voices: voices, anchorBPM: nil, key: nil)
}

/// The specs a walk swaps to, in order (each swap becomes the next step's spec).
private func swaps(_ start: WanderContext, steps: Int) -> [(WanderPlan, TrackSpec)] {
  var c = start
  var out: [(WanderPlan, TrackSpec)] = []
  for step in 0..<steps {
    guard let p = Wander.plan(c, step: step) else { break }
    if case .swap(let s) = p.action {
      out.append((p, s))
      c.spec = s
    }
  }
  return out
}

/// The bass's hit ticks over the first 64 ticks of what `spec` plays (`.approach`, which steps
/// into the next root from the chords, left out).
private func bassRhythm(_ spec: TrackSpec) -> [Int] {
  let p = DJMusicality.apply(
    spec.project(), spec: spec, fixes: DJMusicality.Fixes.all.subtracting(.approach))
  return NoteLog.capture(p, ticks: 64).filter { !$0.isDrum && $0.group == "bass" }.map(\.tick)
}

struct WanderKeepTests {
  /// Under keep:bass (genre and structure locked: every swap is a same-genre loop), every new
  /// seed carries the seed the bass first played under, and the bass keeps its rhythm.
  @Test func aKeptBassKeepsItsLineThroughSeedMoves() {
    let c = context(
      TrackSpec(genre: "techno", seed: 42), locks: ["genre", "structure", WanderLock.keep("bass")])
    let all = swaps(c, steps: 200)
    let seeded = all.filter { $0.1.seed != 42 }
    #expect(seeded.count >= 3)
    for (p, s) in all {
      #expect(s.partSeeds == ["bass": 42], "\(p.detail)")
    }
    let rhythms = Set(([c.spec] + seeded.prefix(4).map(\.1)).map(bassRhythm))
    #expect(rhythms.count == 1, "\(rhythms.count) bass rhythms")
    #expect(!(rhythms.first ?? []).isEmpty)
    // without the keep the same seeds play their own bass lines, and carry no part seeds
    let free = swaps(context(TrackSpec(genre: "techno", seed: 42), locks: ["genre"]), steps: 200)
    #expect(free.allSatisfy { $0.1.partSeeds.isEmpty })
  }

  /// A kept part that already has its own seed keeps that one; a kept role with no seedable
  /// part (harmony) carries nothing.
  @Test func aKeptPartKeepsItsOwnSeed() {
    var spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    spec.partSeeds = ["melody": 777]
    let c = context(spec, locks: ["genre", WanderLock.keep("melody"), WanderLock.keep("harmony")])
    let all = swaps(c, steps: 120)
    #expect(!all.isEmpty)
    for (p, s) in all { #expect(s.partSeeds == ["melody": 777], "\(p.detail)") }
  }

  /// A genre hop drops the kept part's seed: another genre's figures are not this one's.
  @Test func aGenreHopDropsThePartSeed() throws {
    var spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    spec.partSeeds = ["bass": 9_001]
    let c = context(spec, locks: [WanderLock.keep("bass")])
    let step = try #require((0..<400).first { Wander.plan(c, step: $0)?.kind == .genre })
    let p = try #require(Wander.plan(c, step: step))
    guard case .swap(let s) = p.action else {
      Issue.record("a genre move swaps")
      return
    }
    #expect(s.genre != "techno")
    #expect(s.partSeeds.isEmpty)
    // and a seed move from the same spec keeps it
    let seedStep = try #require((0..<400).first { Wander.plan(c, step: $0)?.kind == .seed })
    if case .swap(let n)? = Wander.plan(c, step: seedStep)?.action {
      #expect(n.partSeeds == ["bass": 9_001])
    }
  }

  /// Freeing a keep drops its seed at the next swap (a structure move too, which keeps the rest
  /// of the spec).
  @Test func freeingAKeepDropsItsSeedAtTheNextSwap() {
    var spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    spec.partSeeds = ["bass": 42, "kick": 5]
    let c = context(spec, locks: ["genre", WanderLock.keep("kick")])
    let all = swaps(c, steps: 120)
    #expect(all.contains { $0.0.kind == .structure })
    #expect(all.contains { $0.0.kind == .seed })
    for (p, s) in all { #expect(s.partSeeds == ["kick": 5], "\(p.detail)") }
  }

  /// The walk with keeps is still a pure function of the context and step: the same path twice.
  @Test func theWalkWithKeepsIsDeterministic() {
    let c = context(locks: [WanderLock.keep("bass"), WanderLock.keep("hihat")])
    let a = swaps(c, steps: 200).map(\.1)
    let b = swaps(c, steps: 200).map(\.1)
    #expect(!a.isEmpty && a == b)
  }

  /// On a deck: a seed move under keep:bass loads the new seed with the bass's part seed, and the
  /// next move walks from that spec, seed kept.
  @Test func aDeckCarriesTheKeptPartSeedIntoItsSwaps() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    let d = dj["A"]!
    d.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "minimal"), sampleRate: rate,
        opts: d.waveOptions))
    dj["B"]!.loadDemo()
    dj.perform(.wanderLock(deck: "A", dimension: "genre", on: true))
    dj.perform(.wanderLock(deck: "A", dimension: WanderLock.keep("bass"), on: true))
    d.setWander(true)
    for bar in [3, 7] {
      let c = try #require(d.wanderContext(lockedActions: []))
      let step = try #require(
        (d.wander.step..<(d.wander.step + 400)).first { Wander.plan(c, step: $0)?.kind == .seed })
      d.wander.step = step
      let move = try #require(d.takeWanderMove(bar: bar, lockedActions: []))
      #expect(move.kind == .seed)
      #expect(move.spec?.partSeeds == ["bass": 42])
      #expect(d.currentSpec?.partSeeds == ["bass": 42])
      #expect(d.currentSpec?.seed != 42)
    }
  }
}
