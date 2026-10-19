import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double, _ structure: String?) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if let structure { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

private func hash(_ s: String) -> Int32 { strHash(s) }

private func isMuted(_ g: WaveGraph, _ id: String) -> Bool { g.muted[g.byId[id]!] != 0 }

struct WaveRoleTests {
  @Test func groupMuteKeepsTheActiveSlot() {
    let g = WaveGraph(project: project("techno", 42, "standard"))
    for _ in 0..<200 { g.advance() }  // well into the song: slots have been launched
    let bass = g.nets.filter { $0.bundle.riffGroup == "bass" }
    #expect(bass.count > 1)
    let audibleBefore = bass.filter { g.muted[$0.index] == 0 }.map(\.id)
    #expect(g.isRoleAudible(hash: hash("bass")) == !audibleBefore.isEmpty)

    g.setRoleMuted(hash: hash("bass"), true)
    #expect(bass.allSatisfy { g.muted[$0.index] == 1 })
    #expect(!g.isRoleAudible(hash: hash("bass")))
    for _ in 0..<64 { g.advance() }  // structure keeps activating slots meanwhile
    #expect(bass.allSatisfy { g.muted[$0.index] == 1 }, "a muted group stays silent")

    g.setRoleMuted(hash: hash("bass"), false)
    let audible = bass.filter { g.muted[$0.index] == 0 }
    #expect(audible.count == 1, "exactly one slot comes back")
    #expect(g.isRoleAudible(hash: hash("bass")))
  }

  @Test func plainNetsMuteByName() {
    let g = WaveGraph(project: project("techno", 42, nil))
    #expect(!isMuted(g, "kick"))
    g.setRoleMuted(hash: hash("kick"), true)
    #expect(isMuted(g, "kick") && !g.isRoleAudible(hash: hash("kick")))
    g.setRoleMuted(hash: hash("kick"), false)
    #expect(!isMuted(g, "kick"))
    g.setRoleMuted(hash: hash("no-such-role"), true)  // ignored
  }

  @Test func activateSlotPicksTheVariant() {
    let g = WaveGraph(project: project("techno", 42, "standard"))
    let slots = g.nets.filter { $0.bundle.riffGroup == "melody" }.map(\.id)
    #expect(slots.count >= 2)
    g.activateSlot(hash: hash(slots[1]))
    #expect(slots.filter { !isMuted(g, $0) } == [slots[1]])
    g.activateSlot(hash: hash(slots[0]))
    #expect(slots.filter { !isMuted(g, $0) } == [slots[0]])
  }
}

struct WaveMacroTests {
  @Test func dropMutesNonDrumsAndRestoresOnTheNthTick() {
    let g = WaveGraph(project: project("techno", 42, nil))
    let music = g.nets.filter { g.isControlNet[$0.index] == false }
    let nonDrums = music.filter { !g.isDrumNet[$0.index] && g.muted[$0.index] == 0 }
    #expect(nonDrums.count >= 3)
    let n = g.fireMute(.nonDrums, ticks: 16)
    #expect(n == nonDrums.count)
    #expect(nonDrums.allSatisfy { g.muted[$0.index] == 1 })
    #expect(music.filter { g.isDrumNet[$0.index] }.allSatisfy { g.muted[$0.index] == 0 })
    for _ in 0..<15 { g.advance() }
    #expect(nonDrums.allSatisfy { g.muted[$0.index] == 1 }, "still muted after 15 ticks")
    g.advance()
    #expect(nonDrums.allSatisfy { g.muted[$0.index] == 0 }, "restored on the 16th")
    #expect(g.pendingMacroTimers == 0)
  }

  @Test func aUserMuteSurvivesAMacro() {
    let g = WaveGraph(project: project("techno", 42, nil))
    g.setRoleMuted(hash: hash("bass"), true)
    g.fireMute(.everything, ticks: 4)
    for _ in 0..<4 { g.advance() }
    #expect(isMuted(g, "bass"), "the macro must not unmute what it did not mute")
    #expect(!isMuted(g, "kick"))
  }

  @Test func breakdownMutesTheDrums() {
    let g = WaveGraph(project: project("techno", 42, nil))
    g.fireMute(.drumsOnly, ticks: 32)
    #expect(isMuted(g, "kick") && isMuted(g, "snare") && isMuted(g, "hihat"))
    #expect(!isMuted(g, "bass") && !isMuted(g, "melody"))
  }

  @Test func beatRepeatStuttersEverythingButTheKick() {
    let g = WaveGraph(project: project("techno", 42, nil))
    g.fireBeatRepeat(ticks: 16, step: 2, burst: 1)
    var snareMuted: [Bool] = [isMuted(g, "snare")]
    var kickEverMuted = isMuted(g, "kick")
    for _ in 0..<16 {
      g.advance()
      snareMuted.append(isMuted(g, "snare"))
      kickEverMuted = kickEverMuted || isMuted(g, "kick")
    }
    #expect(!kickEverMuted)
    #expect(snareMuted.prefix(8) == [true, false, true, false, true, false, true, false])
    #expect(!snareMuted.last!, "the run ends unmuted")
    #expect(g.pendingMacroTimers == 0)
  }

  @Test func panicRestoresEverythingNow() {
    let g = WaveGraph(project: project("techno", 42, nil))
    g.fireMute(.everything, ticks: 64)
    g.fireBeatRepeat(ticks: 64)
    g.cancelMacros()
    // back to the state before the macros: everything audible except the stingers
    #expect(
      g.nets.allSatisfy {
        g.isControlNet[$0.index] || (g.muted[$0.index] == 0) == !isStingerID($0.id)
      })
    #expect(g.pendingMacroTimers == 0)
    g.advance()
    #expect(!isMuted(g, "snare"), "the repeater is stopped too")
  }

  @Test func stingerRingsForItsBarsThenMutes() {
    let g = WaveGraph(project: project("techno", 42, nil))
    #expect(isMuted(g, "hit1"))
    g.fireStinger(hash: hash("hit1"), ticks: 16)
    #expect(!isMuted(g, "hit1"))
    for _ in 0..<15 { g.advance() }
    #expect(!isMuted(g, "hit1"))
    g.advance()
    #expect(isMuted(g, "hit1"))
    // a re-fire while ringing extends rather than stacking restores
    g.fireStinger(hash: hash("hit2"), ticks: 8)
    for _ in 0..<4 { g.advance() }
    g.fireStinger(hash: hash("hit2"), ticks: 8)
    for _ in 0..<7 { g.advance() }
    #expect(!isMuted(g, "hit2"))
    g.advance()
    #expect(isMuted(g, "hit2"))
  }

  @Test func fastForwardEqualsStepping() {
    let p = project("jazz", 7, "standard")
    let a = WaveGraph(project: p)
    for _ in 0..<300 { a.advance() }
    let b = WaveGraph(project: p)
    b.fastForward(to: 300)
    #expect(b.tick == 300)
    #expect(b.muted == a.muted)
    #expect(zip(a.nets, b.nets).allSatisfy { $0.state == $1.state })
    // and prepare(startTick:) hands over exactly that
    let c = WaveRunner.prepare(p, sampleRate: 8000, startTick: 300)
    #expect(c.graph.tick == 300 && c.graph.muted == a.muted)
  }
}

struct WaveRunnerLiveTests {
  private func runner(_ p: Project, tempo: Double = 120) -> WaveRunner {
    let r = WaveRunner(sampleRate: 8000)
    r.load(p)
    r.setTempo(tempo)
    r.play()
    return r
  }

  private func run(_ r: WaveRunner, blocks: Int) -> [Float] {
    var out: [Float] = []
    var l = [Float](repeating: 0, count: 128)
    for _ in 0..<blocks {
      l.withUnsafeMutableBufferPointer { r.process($0.baseAddress!, nil, frames: 128) }
      out += l
    }
    return out
  }

  @Test func halfTimeHoldsThenRestores() {
    let r = runner(project("techno", 42, nil), tempo: 120)
    _ = run(r, blocks: 4)
    r.fireMacro(.halfTime, ticks: 16)
    _ = run(r, blocks: 1)
    #expect(r.tempo == 60)
    // 16 ticks at 120 bpm of wall time = 2 s = 16000 samples
    _ = run(r, blocks: 100)
    #expect(r.tempo == 60)
    _ = run(r, blocks: 40)
    #expect(r.tempo == 120)
  }

  @Test func tapeStopSweepsDownAndSnapsBack() {
    let r = runner(project("techno", 42, nil), tempo: 120)
    r.fireMacro(.tapeStop, ticks: 16)
    var seen: [Double] = []
    for _ in 0..<130 {
      _ = run(r, blocks: 1)
      seen.append(r.tempo)
    }
    #expect(seen.min()! < 40, "ramps toward 22 bpm")
    #expect(zip(seen, seen.dropFirst()).prefix(80).allSatisfy { $0 >= $1 }, "monotonic down")
    #expect(r.tempo == 120, "snaps back at the end")
  }

  @Test func tempoAnchorHoldsTheProjectBPM() {
    let p = project("techno", 42, nil)
    let r = runner(p, tempo: 150)
    r.fireMacro(.tempoAnchor, ticks: 8)
    _ = run(r, blocks: 1)
    #expect(r.tempo == p.tempo)
    _ = run(r, blocks: 100)
    #expect(r.tempo == 150)
  }

  @Test func panicEndsTempoMacrosToo() {
    let r = runner(project("techno", 42, nil), tempo: 120)
    r.fireMacro(.halfTime, ticks: 64)
    _ = run(r, blocks: 2)
    r.panic()
    #expect(r.tempo == 120)
  }

  @Test func doubleDropCutsThenDrops() {
    let r = runner(project("techno", 42, nil), tempo: 240)
    _ = run(r, blocks: 2)
    let g = r.graph!
    let music = g.nets.indices.filter { !g.isControlNet[$0] && !isStingerID(g.nets[$0].id) }
    let nonDrums = music.filter { !g.isDrumNet[$0] }
    let drums = music.filter { g.isDrumNet[$0] }
    let t0 = g.tick
    r.fireMacro(.doubleDrop, ticks: 16)
    #expect(music.allSatisfy { g.muted[$0] == 1 }, "the cut mutes everything")
    // 240 bpm → 500 samples per tick. The cut lasts 2 ticks, the drop starts 4 ticks in.
    func runTo(_ tick: Int) {
      var guardRail = 0
      while g.tick < tick && guardRail < 400 {
        _ = run(r, blocks: 1)
        guardRail += 1
      }
    }
    runTo(t0 + 3)
    #expect(music.allSatisfy { g.muted[$0] == 0 }, "the cut is over after 2 ticks")
    runTo(t0 + 5)
    #expect(nonDrums.allSatisfy { g.muted[$0] == 1 }, "then the drop takes the non-drums")
    #expect(drums.allSatisfy { g.muted[$0] == 0 })
  }

  @Test func liveKeysSoundWhileHeldAndRingOutAfter() {
    let r = runner(project("techno", 42, nil))
    r.setMute(hash: strHash("melody"), true)
    for n in ["bass", "harmony", "kick", "snare", "hihat"] { r.setMute(hash: strHash(n), true) }
    for t in ["hit1", "hit2", "hit3", "hit4", "arp", "clap"] { r.setMute(hash: strHash(t), true) }
    _ = run(r, blocks: 40)
    let quiet = run(r, blocks: 20).reduce(0) { max($0, abs($1)) }
    r.noteOn(60, velocity: 110)
    let held = run(r, blocks: 40)
    let heldPeak = held.suffix(2000).reduce(0) { max($0, abs($1)) }
    #expect(heldPeak > 0.02, "a held key sustains (peak \(heldPeak), quiet \(quiet))")
    r.noteOff(60)
    _ = run(r, blocks: 60)
    let after = run(r, blocks: 20).reduce(0) { max($0, abs($1)) }
    #expect(after < heldPeak * 0.2, "released keys die away")
  }
}

@MainActor
struct DeckPerformTests {
  @Test func scaleLockSnapsKeysToTheProjectScale() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "jazz", seed: 7))  // Dorian, rootNote 55
    let p = try #require(deck.netProject)
    let root = try #require(p.rootNote) % 12
    let dorian = Set([0, 2, 3, 5, 7, 9, 10].map { ($0 + root) % 12 })
    for note in 36...96 {
      let q = deck.scaleLocked(note)
      #expect(dorian.contains(q % 12), "\(note) → \(q)")
      #expect(abs(q - note) <= 2)
    }
    #expect(deck.scaleLocked(55) == 55, "a scale tone stays put")
  }

  @Test func launchSectionRepositionsTheNet() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let secs = deck.sections
    #expect(secs.count >= 5 && secs[0].startTick == 0)
    #expect(secs.map(\.steps).reduce(0, +) > 600)
    let target = 3
    let ok = await deck.jumpToSection(target)
    #expect(ok)
    deck.wave.setTempo(600)
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 4096)
    #expect(deck.wave.tick >= secs[target].startTick)
    #expect(deck.currentSectionIndex == target)
  }

  @Test func aSectionLaunchIsTheSameSongAndANewTrackIsNot() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let song = try #require(deck.wave.latest)
    let secs = deck.sections
    #expect(secs.count >= 5)
    // jumping around inside the song: a new project each time (the marking and the tick
    // numbering start over), but the same song
    #expect(await deck.jumpToSection(3))
    let launched = try #require(deck.wave.latest)
    #expect(launched.generation > song.generation)
    #expect(launched.trackSerial == song.trackSerial, "a section launch is not a new track")
    #expect(launched.startTick == secs[3].startTick && song.startTick == 0)
    #expect(launched.marking.layout.trackSerial == song.marking.layout.trackSerial)
    #expect(launched.marking.layout.startTick == secs[3].startTick)
    #expect(await deck.jumpToTick(100))
    let jumped = try #require(deck.wave.latest)
    #expect(jumped.trackSerial == song.trackSerial && jumped.startTick == 100)
    dj.deterministic = true  // replay mode: relocation completes inline
    deck.relocate(toTick: 40)
    let relocated = try #require(deck.wave.latest)
    #expect(relocated.generation > jumped.generation && relocated.trackSerial == song.trackSerial)
    #expect(relocated.startTick == 40)
    // a new track, generated or handed over: a new serial
    await deck.generate(TrackSpec(genre: "techno", seed: 43, structure: "standard"))
    let next = try #require(deck.wave.latest)
    #expect(next.trackSerial != song.trackSerial && next.startTick == 0)
    #expect(await deck.jumpToSection(2))
    #expect(deck.wave.latest?.trackSerial == next.trackSerial, "and sections of it keep its serial")
    deck.loadNet(try #require(deck.netProject))
    #expect(deck.wave.latest?.trackSerial != next.trackSerial, "loading a project afresh restarts")
  }

  @Test func rolesFollowTheNet() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 42))
    #expect(deck.roles == ["kick", "snare", "hihat", "bass", "melody", "harmony"])
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    #expect(deck.isRoleOn("kick"))
    deck.toggleRole("kick")
    _ = try renderOffline(dj, frames: 2048)
    #expect(!deck.isRoleOn("kick") && deck.isRoleOn("snare"))
    deck.toggleRole("kick")
    _ = try renderOffline(dj, frames: 2048)
    #expect(deck.isRoleOn("kick"))
  }
}

struct WaveScratchTests {
  private func runner(_ p: Project, tempo: Double = 120, play: Bool = true) -> WaveRunner {
    let r = WaveRunner(sampleRate: 8000)
    r.load(p)
    r.setTempo(tempo)
    if play { r.play() }
    return r
  }

  @discardableResult
  private func run(_ r: WaveRunner, blocks: Int) -> [Float] {
    var out: [Float] = []
    var l = [Float](repeating: 0, count: 128)
    for _ in 0..<blocks {
      l.withUnsafeMutableBufferPointer { r.process($0.baseAddress!, nil, frames: 128) }
      out += l
    }
    return out
  }

  private func marking(_ g: WaveGraph) -> [[Double]] { g.nets.map { $0.state } }

  @Test func scratchingForwardAndBackLeavesTheMarkingYouLeft() {
    let r = runner(project("techno", 42, "standard"), tempo: 240)
    run(r, blocks: 90)
    let g = r.graph!
    r.freeze()
    run(r, blocks: 1)
    let t0 = g.tick
    let m0 = marking(g)
    let mutes0 = g.muted
    #expect(r.isScrubbing && t0 > 5)

    r.scrub(ticks: 24)
    run(r, blocks: 60)
    #expect(g.tick == t0 + 24, "reached the target: \(g.tick)")
    #expect(marking(g) != m0)

    r.scrub(ticks: -24)
    run(r, blocks: 60)
    #expect(g.tick == t0)
    #expect(marking(g) == m0, "the marking is the one we left")
    #expect(g.muted == mutes0)
  }

  @Test func scratchingPlaysTheNotesItCrosses() {
    let r = runner(project("techno", 42, nil), tempo: 120, play: false)
    r.freeze()
    let silent = run(r, blocks: 40).reduce(0) { max($0, abs($1)) }
    #expect(silent == 0, "a frozen, stopped net is silent")
    r.scrub(ticks: 12)
    let forward = run(r, blocks: 60)
    #expect(forward.reduce(0) { max($0, abs($1)) } > 0.05)
    r.scrub(ticks: -12)
    let backward = run(r, blocks: 60)
    #expect(backward.reduce(0) { max($0, abs($1)) } > 0.05, "going back plays the notes too")
  }

  @Test func theStartOfTheSongIsAWall() {
    let r = runner(project("techno", 42, nil), tempo: 120, play: false)
    r.freeze()
    r.scrub(ticks: 6)
    run(r, blocks: 40)
    let g = r.graph!
    #expect(g.tick == 6)
    r.scrub(ticks: -50)
    run(r, blocks: 80)
    #expect(g.tick == 0, "can't go before tick 0 (at \(g.tick))")
    r.scrub(ticks: 9)  // the hand was far past the wall; it still comes back
    run(r, blocks: 80)
    #expect(g.tick >= 0)
    r.scrub(ticks: 40)
    run(r, blocks: 200)
    #expect(g.tick > 5)
  }

  @Test func releaseResumesTheClockFromWhereThePlatterIs() {
    let r = runner(project("techno", 42, nil), tempo: 240)
    run(r, blocks: 30)
    r.freeze()
    r.scrub(ticks: 5)
    run(r, blocks: 60)
    let g = r.graph!
    let held = g.tick
    r.release()
    #expect(!r.isScrubbing)
    run(r, blocks: 30)  // ~0.5 s at 240 bpm = 8 ticks
    #expect(g.tick >= held + 5 && g.tick <= held + 10, "running again: \(held) → \(g.tick)")
  }

  @Test func theSameGestureSoundsTheSameEveryTime() {
    func gesture() -> [Float] {
      let r = runner(project("jazz", 7, "standard"), tempo: 200)
      run(r, blocks: 40)
      r.freeze()
      var out: [Float] = []
      for d in [10.0, -4, 7, -13, 6] {
        r.scrub(ticks: d)
        out += run(r, blocks: 25)
      }
      r.release()
      return out + run(r, blocks: 20)
    }
    let a = gesture()
    #expect(sameSamples(a, gesture()) == .identical)
    #expect(a.contains { $0 != 0 })
  }
}

@MainActor
struct DeckScratchTests {
  @Test func jogClockDrivesTheNetClockOnANetDeck() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))])))
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 24_000)
    let t0 = deck.wave.tick
    deck.freeze()
    // one platter second at 120 bpm = 2 beats = 8 ticks
    deck.scrubBy(seconds: 1)
    _ = try renderOffline(dj, frames: 12_000)
    #expect(deck.wave.isScrubbing)
    #expect(abs(deck.wave.tick - (t0 + 8)) <= 1, "tick \(deck.wave.tick) vs \(t0 + 8)")
    deck.scrubBy(seconds: -1)
    _ = try renderOffline(dj, frames: 12_000)
    #expect(abs(deck.wave.tick - t0) <= 1)
    deck.release()
    _ = try renderOffline(dj, frames: 24_000)
    #expect(!deck.wave.isScrubbing && deck.wave.tick > t0 + 3)
  }

  @Test func theJogAdapterScratchesANetDeck() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    await deck.generate(TrackSpec(genre: "techno", seed: 1))
    deck.setPlaying(true)
    let jog = JogAdapter(profile: .inpulse200MK3, clock: deck, deck: "A")
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 12_000)
    // touch → freeze; ticks of the wheel → scrub
    jog.handle(.touch(deck: "A", shift: false, down: true))
    _ = try renderOffline(dj, frames: 2048)
    #expect(deck.wave.isScrubbing)
    let t0 = deck.wave.tick
    jog.handle(.scratch(deck: "A", shift: false, ticks: 400))
    _ = try renderOffline(dj, frames: 24_000)
    #expect(deck.wave.tick > t0, "the wheel moved the net clock: \(t0) → \(deck.wave.tick)")
    jog.handle(.touch(deck: "A", shift: false, down: false))
    _ = try renderOffline(dj, frames: 2048)
    #expect(!deck.wave.isScrubbing)
  }
}
