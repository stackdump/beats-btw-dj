import Testing

@testable import DJCore

private let rate = 22_050.0

private func lp(_ n: String, _ cat: String = "Vocals", beats: Int = 16) -> LayerLoop {
  LayerLoop(path: "/lib/\(n).caf", name: n, category: cat, beats: beats)
}

private let pool = [
  lp("Vox A"), lp("Vox B"), lp("Vox C", beats: 8), lp("Riser A", "Sound Effect"),
  lp("Riser B", "Sound Effect"),
  lp("Pad A", "Texture/Atmosphere", beats: 32),
]

/// A raw-nets context like a playing roll's, with a layer list and a pool.
private func context(
  layers: [LayerEntry] = [], pool: [LayerLoop] = pool, locks: Set<String> = [], bar: Int = 8,
  pace: Int = 8
) -> WanderContext {
  let roles = ["kick", "bass", "melody"]
  var c = WanderContext(
    deck: "A", spec: TrackSpec(genre: "", seed: 0), isLoop: false, roles: roles,
    rolesOn: Set(roles),
    disabledRoles: [], stemsMuted: [], lockedActions: [], locks: locks, voices: [], anchorBPM: nil,
    key: nil)
  c.rawBase = WanderRandom.base(cid: "z-test-payload")
  c.layers = layers
  c.layerPool = pool
  c.bar = bar
  c.pace = pace
  return c
}

struct WanderLayerPlannerTests {
  /// The plan for one kind (drawing steps until it turns up).
  func plan(_ kind: WanderMoveKind, _ c: WanderContext) -> WanderPlan? {
    for step in 0..<2000 {
      if let p = Wander.plan(c, step: step), p.kind == kind { return p }
    }
    return nil
  }

  func list(_ p: WanderPlan?) -> [LayerEntry]? {
    if case .layers(let l)? = p?.action { return l }
    return nil
  }

  @Test func anAddedLayerComesInFromTheNextBarForOnePassAndSitsUnderTheMix() throws {
    let l = try #require(list(plan(.layerAdd, context(bar: 8))))
    #expect(l.count == 1)
    let e = l[0]
    #expect(
      e.start == 9 && e.length == min(16, 8 + e.loop.bars), "a little over one phrase (pace 8)")
    #expect(pool.contains(e.loop) && e.gainDB == LoopLayers.defaultGain(category: e.loop.category))
    #expect(
      plan(.layerAdd, context(bar: 8))?.detail.hasPrefix("+ \(e.loop.name) · bars 9–") == true)
  }

  @Test func noMoreThanThreeAtOnceAndNoLoopTwice() {
    let on = [pool[0], pool[1], pool[3]].enumerated().map {
      LayerEntry(loop: $1, start: 5 + $0, length: 8)
    }
    #expect(plan(.layerAdd, context(layers: on, bar: 8)) == nil, "three are live: no fourth")
    // a window already over doesn't count
    let over = [LayerEntry(loop: pool[0], start: 1, length: 4)]
    #expect(plan(.layerAdd, context(layers: over, bar: 8)) != nil)
    // never one that is already live
    let live = LayerEntry(loop: pool[0], start: 5, length: 8)
    for step in 0..<300 {
      if case .layers(let l)? = Wander.plan(context(layers: [live], bar: 8), step: step)?.action,
        l.count == 2
      {
        #expect(l.filter { $0.loop == pool[0] }.count == 1)
      }
    }
  }

  @Test func aLayerThatIsOnGoesOutAtTheNextBarAndOneNotYetOnNeverComes() throws {
    let on = LayerEntry(loop: pool[0], start: 5, length: 8)  // bars 5–12, on now (bar 8)
    let l = try #require(list(plan(.layerRemove, context(layers: [on], bar: 8))))
    #expect(l.count == 1 && l[0].start == 5 && l[0].end == 9, "out after bar 8")
    let later = LayerEntry(loop: pool[1], start: 14, length: 4)
    let gone = try #require(list(plan(.layerRemove, context(layers: [later], bar: 8))))
    #expect(gone.isEmpty)
    #expect(plan(.layerRemove, context(layers: [], bar: 8)) == nil, "nothing to take out")
    #expect(
      plan(.layerRemove, context(layers: [LayerEntry(loop: pool[0], start: 1, length: 4)], bar: 8))
        == nil, "already over")
  }

  @Test func aSwapEndsTheOldLoopAndBringsAnotherOfItsKindIn() throws {
    let on = LayerEntry(loop: pool[0], start: 5, length: 8, gainDB: -7, keyLock: false)  // a vocal, on now
    let l = try #require(list(plan(.layerSwap, context(layers: [on], bar: 8))))
    #expect(l.count == 2)
    let old = try #require(l.first { $0.loop == on.loop })
    let new = try #require(l.first { $0.loop != on.loop })
    #expect(old.end == 9, "the old one is out at the next bar")
    #expect(new.start == 9 && new.loop.category == "Vocals" && new.gainDB == -7 && !new.keyLock)
    #expect(new.end == 13, "for what was left of the old one's window")
    // one not yet on is replaced in place
    let later = LayerEntry(loop: pool[3], start: 14, length: 4)
    let r = try #require(list(plan(.layerSwap, context(layers: [later], bar: 8))))
    #expect(
      r.count == 1 && r[0].start == 14 && r[0].loop != later.loop
        && r[0].loop.category == "Sound Effect")
    #expect(plan(.layerSwap, context(layers: [], bar: 8)) == nil)
  }

  @Test func withALayerOnTheWalkSoonTakesItOutOrSwapsIt() {
    let on = [LayerEntry(loop: pool[0], start: 5, length: 8)]
    func share(_ kind: WanderMoveKind, _ c: WanderContext) -> Double {
      var n = 0
      for step in 0..<3000 where Wander.plan(c, step: step)?.kind == kind { n += 1 }
      return Double(n) / 3000
    }
    let live = context(layers: on, bar: 8)
    let none = context(layers: [], bar: 8)
    #expect(
      share(.layerRemove, live) > 0.10 && share(.layerSwap, live) > 0.05, "out and swap come up")
    #expect(
      share(.layerAdd, none) > share(.layerAdd, live), "one is likelier to come in when none is on")
  }

  @Test func withoutAPoolOrWithTheLayersLockThereAreNoLayerMoves() {
    let on = [LayerEntry(loop: pool[0], start: 5, length: 8)]
    for kind in [WanderMoveKind.layerAdd, .layerSwap] {
      #expect(plan(kind, context(layers: on, pool: [])) == nil)
    }
    #expect(
      plan(.layerRemove, context(layers: on, pool: [])) != nil, "taking one out needs no pool")
    let locked = context(layers: on, locks: ["layers"])
    for kind in [WanderMoveKind.layerAdd, .layerSwap, .layerRemove] {
      #expect(plan(kind, locked) == nil)
    }
    #expect(WanderLock.isValid("layers") && WanderLock.dimensions.contains("layers"))
  }

  @Test func aWalkKeepsTheListSaneAndIsTheSameEveryTime() {
    func run() -> [String] {
      var c = context(bar: 4, pace: 4)
      var log: [String] = []
      for step in 0..<300 {
        c.bar = 4 + step * 4
        guard let p = Wander.plan(c, step: step) else { continue }
        if case .layers(let l) = p.action {
          c.layers = l
          log.append(p.detail)
          // the invariants after every layer move
          let live = l.filter { $0.end > c.bar + 1 }
          #expect(live.count <= Wander.maxLayers)
          #expect(Set(live.map(\.loop.path)).count == live.count, "no loop twice at once")
          #expect(l.allSatisfy { $0.length >= 1 })
        }
      }
      return log
    }
    let a = run()
    #expect(a.count > 20 && a == run())
    #expect(
      a.contains { $0.hasPrefix("+ ") } && a.contains { $0.hasPrefix("− ") }
        && a.contains { $0.contains(" → ") }, "\(a.count): \(a.prefix(12))")
  }
}

@MainActor
struct WanderLayerDeckTests {
  /// A raw deck with a pool and one layer, its Wander walk run `bars` bars at pace 4.
  func walked(bars: Int, pool: [LayerLoop] = pool) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    let d = dj["A"]!
    let env = try PianoRoll.envelope(
      JSONValue.parse(
        """
        {"name":"L","tempo":128,"steps":128,"key":"A minor",
         "layers":[{"loop":"/lib/Vox A.caf","name":"Vox A","bar":3,"bars":4,"beats":16,"category":"Vocals"}],
         "parts":{"kick":{"every":16,"until":128,"notes":[[0],[4],[8],[12]]},
                  "bass":{"every":16,"until":128,"notes":[[2,45,2],[6,45,2],[10,45,2],[14,45,2]]}}}
        """))
    d.loadNet(
      try #require(
        PreparedTrack(source: .rawNets(payload: env), sampleRate: rate, opts: d.waveOptions)))
    dj["B"]!.loadDemo()
    try dj.start()
    d.layerPool = pool
    d.setWander(true)
    d.setWanderPace(4)
    for bar in 0..<bars { d.advanceWander(toBar: bar, lockedActions: []) }
    return (dj, d)
  }

  @Test func aRawTracksLayersAndKeyComeFromItsPayload() throws {
    let (dj, d) = try walked(bars: 0)
    defer { dj.stop() }
    #expect(d.layerEntries.count == 1 && d.layerKeyName == "A minor" && d.layerKey == "A minor")
    let e = d.layerEntries[0]
    #expect(e.loop.name == "Vox A" && e.loop.category == "Vocals" && e.start == 3 && e.length == 4)
    #expect(d.layerEpoch == 1)
  }

  @Test func wanderAddsSwapsAndRemovesLoopsOnTheDeckAndLogsIt() throws {
    // everything but layers locked: a cheap walk made only of layer moves
    let (dj, d) = try walked(bars: 0)
    defer { dj.stop() }
    for lock in ["arrangement", "fx", "palette"] { d.setWanderLock(lock, true) }
    for bar in 0..<160 { d.advanceWander(toBar: bar, lockedActions: []) }  // 40 phrases
    let kinds = d.wander.log.map(\.kind)
    #expect(Set(kinds) == [.layerAdd, .layerSwap, .layerRemove], "\(Set(kinds))")
    for m in d.wander.log { #expect(m.spec == nil && !m.detail.isEmpty) }
    #expect(d.layerEpoch == 1, "moves don't make it a new track")
    // the list holds only what the pool and the track gave it, at most three on at the end
    let paths = Set(pool.map(\.path) + ["/lib/Vox A.caf"])
    #expect(d.layerEntries.allSatisfy { paths.contains($0.loop.path) })
    #expect(d.layerEntries.filter { $0.end > 160 }.count <= Wander.maxLayers)
  }

  @Test func theSameTrackWalksTheSameLoopsAndALockStopsThem() throws {
    func layersOnly(_ d: Deck) {
      for lock in ["arrangement", "fx", "palette"] { d.setWanderLock(lock, true) }
      for bar in 0..<80 { d.advanceWander(toBar: bar, lockedActions: []) }
    }
    let (dj1, a) = try walked(bars: 0)
    let (dj2, b) = try walked(bars: 0)
    let (dj3, c) = try walked(bars: 0)
    defer {
      dj1.stop()
      dj2.stop()
      dj3.stop()
    }
    layersOnly(a)
    layersOnly(b)
    #expect(a.layerEntries == b.layerEntries && !a.layerEntries.isEmpty)
    for lock in ["layers", "arrangement", "fx", "palette"] { c.setWanderLock(lock, true) }
    for bar in 0..<80 { c.advanceWander(toBar: bar, lockedActions: []) }
    #expect(c.wander.log.isEmpty, "nothing is left to move")
    #expect(c.layerEntries.count == 1)
  }
}
