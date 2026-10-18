import Testing

@testable import DJCore

private let rate = 48_000.0

/// `DJEngine.reset(to:clip:)`: a running engine stood back where a checkpoint was.
@MainActor
struct JournalRewindTests {
  static let spec = TrackSpec(genre: "techno", seed: 7, structure: "standard")
  static let clips = [fxTestClip(1), fxTestClip(2), fxTestClip(3)]
  static func lookup(_ id: String) -> LoopClip? { clips.first { $0.id == id } }

  /// An engine running in replay mode, and its conductor.
  func engine(deterministic: Bool = true) throws -> (DJEngine, OfflineConductor) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = deterministic
    try dj.start()
    return (dj, OfflineConductor(engine: dj, router: ControllerRouter(engine: dj)))
  }

  func run(_ c: OfflineConductor, blocks: Int, inputs: () -> Void = {}) throws {
    var first = true
    for _ in 0..<blocks {
      _ = try c.step {
        if first { inputs() }
        first = false
      }
    }
  }

  /// The target: A on the demo loop, playing; B on a net; clip 1 looping under the mixer, clip 2
  /// on the row, clip 3 removed; a scene; a lock; the mixer and row settings moved.
  func target(_ dj: DJEngine, _ c: OfflineConductor) throws -> JournalState {
    try run(c, blocks: 4) {
      dj.perform(
        .load(deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil))
      )
      dj.perform(.load(deck: "B", source: .net(Self.spec)))
      dj.restoreClips(Array(Self.clips))
      dj.perform(.clipRemove(id: Self.clips[2].id))
      dj.perform(.clipGain(id: Self.clips[0].id, value: 0.7))
      dj.perform(.clipMute(id: Self.clips[1].id, on: true))
      dj.perform(.play(deck: "A", on: true))
      dj.perform(.crossfader(0.3))
      dj.perform(.loopQuantize(beats: 8))
      dj.perform(.lock(key: "A.volume", on: true))
      dj.perform(.param(deck: "B", name: "eqLow", value: 0.2))
    }
    dj.startLoop(Self.clips[0].id, atOnce: true)
    dj.saveScene("Scene 1")
    try run(c, blocks: 20)
    return JournalState(engine: dj)
  }

  /// Everything moved on from the target, and a clip made after it.
  func dirty(_ dj: DJEngine, _ c: OfflineConductor, newClip: LoopClip) throws {
    try run(c, blocks: 4) {
      dj.restoreClips([newClip])
      dj.perform(.clipLoop(id: newClip.id, on: true))
      dj.perform(.clipRemove(id: Self.clips[0].id))
      dj.perform(.clipRestore(id: Self.clips[2].id, at: 0))
      dj.perform(.clipSolo(id: Self.clips[1].id, on: true))
      dj.perform(.clipKeyLock(id: Self.clips[1].id, on: true))
      dj.perform(.load(deck: "A", source: .net(Self.spec)))
      dj.perform(
        .load(deck: "B", source: .sample(id: DeckSourceDescriptor.demoID, title: "d", grid: nil)))
      dj.perform(.play(deck: "B", on: true))
      dj.perform(.follow(deck: "A", leader: "B"))
      dj.perform(.roleDisable(deck: "A", role: "kick", on: true))
      dj.perform(.param(deck: "A", name: "volume", value: 0.2))
      dj.perform(.crossfader(0.9))
      dj.perform(.master(0.4))
      dj.perform(.lock(key: "A.volume", on: false))
      dj.perform(.lock(key: "B.filter", on: true))
      dj.perform(.loopQuantize(beats: 16))
      dj.perform(.loopFxLink(on: true))
      dj.perform(.loopFade(mode: LoopFade.allCases.last!.rawValue))
      dj.perform(.tapBars(bars: 4))
      dj.perform(.sceneSave(name: "Scene 2"))
      dj.perform(.sceneDelete(name: "Scene 1"))
    }
    try run(c, blocks: 20)
  }

  @Test func aDirtyEngineResetEqualsTheTarget() async throws {
    let (dj, c) = try engine()
    defer { dj.stop() }
    let want = try target(dj, c)
    let late = fxTestClip(9)
    try dirty(dj, c, newClip: late)
    #expect(JournalState(engine: dj) != want, "the dirty engine moved on")

    let warnings = await dj.reset(to: want, clip: Self.lookup)
    #expect(warnings.isEmpty, "\(warnings)")
    #expect(JournalState(engine: dj) == want)
    #expect(dj.clip(late.id) == nil, "no clip from after the target")
    #expect(!dj.removedClips.contains { $0.clip.id == late.id }, "nor remembered as removed")
    #expect(!dj.loopingClips.contains(late.id))
    #expect(dj["A"]?.leader == nil)
    #expect(dj["A"]?.disabledRoles.isEmpty == true)
    try run(c, blocks: 20)
    #expect(JournalState(engine: dj) == want, "and it stays there as it renders")
  }

  @Test func aResetMatchesARestoreIntoAFreshEngine() async throws {
    let (dj, c) = try engine()
    defer { dj.stop() }
    let want = try target(dj, c)
    try dirty(dj, c, newClip: fxTestClip(9))
    await dj.reset(to: want, clip: Self.lookup)

    let (fresh, fc) = try engine()
    defer { fresh.stop() }
    want.restore(into: fresh, clip: Self.lookup)
    try run(fc, blocks: 1)
    #expect(JournalState(engine: dj) == JournalState(engine: fresh))
    #expect(dj.clips.map(\.id) == fresh.clips.map(\.id))
    #expect(dj.removedClips.map(\.clip.id) == fresh.removedClips.map(\.clip.id))
    #expect(dj.scenes == fresh.scenes)
  }

  @Test func aResetToAFreshStateEmptiesTheEngine() async throws {
    let (dj, c) = try engine()
    defer { dj.stop() }
    let fresh = JournalState(
      engine: try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate))
    _ = try target(dj, c)
    await dj.reset(to: fresh, clip: Self.lookup)
    #expect(JournalState(engine: dj) == fresh)
    #expect(dj.clips.isEmpty && dj.removedClips.isEmpty && dj.scenes.isEmpty)
    #expect(dj.decks.values.allSatisfy { !$0.playing && $0.loaded == nil && $0.netProject == nil })
    #expect(dj.loopSettings == DJEngine.defaultLoopSettings)
    try run(c, blocks: 40)
    #expect(dj.loopingClips.isEmpty, "the loops faded out")
  }

  @Test func aClipMissingFromTheLibraryIsAWarning() async throws {
    let (dj, c) = try engine()
    defer { dj.stop() }
    let want = try target(dj, c)
    let warnings = await dj.reset(
      to: want, clip: { id in id == Self.clips[1].id ? nil : Self.lookup(id) })
    #expect(warnings == ["clip \(Self.clips[1].id) has no audio"])
    #expect(dj.clip(Self.clips[1].id) == nil)
  }

  /// Live: a compile already on its way when the reset comes lands nowhere.
  @Test func aLiveResetSupersedesACompileInFlight() async throws {
    let (dj, _) = try engine(deterministic: false)
    defer { dj.stop() }
    let a = try #require(dj["A"])
    let empty = JournalState(engine: dj)
    let compiling = Task { @MainActor in await a.generate(Self.spec) }
    await dj.reset(to: empty, clip: Self.lookup)
    #expect(await compiling.value == false, "superseded")
    #expect(a.netProject == nil)
    #expect(JournalState(engine: dj) == empty)
  }

  /// Live: a net deck's playhead is a jump, awaited before the reset returns.
  @Test func aLiveResetAwaitsTheNetDecksJump() async throws {
    let (dj, c) = try engine(deterministic: false)
    defer { dj.stop() }
    let want = JournalState(
      sampleRate: rate,
      decks: ["A": DeckCheckpoint(), "B": DeckCheckpoint(source: .net(Self.spec), position: 96)])
    dj.perform(.load(deck: "B", source: .net(TrackSpec(genre: "house", seed: 3))))
    try run(c, blocks: 8)
    let warnings = await dj.reset(to: want, clip: Self.lookup)
    #expect(warnings.isEmpty, "\(warnings)")
    try run(c, blocks: 1)
    let b = try #require(dj["B"])
    #expect(b.currentSpec == Self.spec)
    #expect(b.wave.tick == 96, "at the checkpoint's tick")
    #expect(!b.playing)
  }
}
