import Testing

@testable import DJCore

@MainActor
private func eventually(_ cond: @MainActor () -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if cond() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return cond()
}

/// Net-deck performance through the real controller layouts.
@MainActor
struct SurfaceNetTests {
  func make(_ p: SurfaceProfile, structure: String? = "standard") async throws
    -> (DJEngine, SurfaceController, Deck)
  {
    let dj = try DJEngine(offline: true)
    dj["B"]!.loadDemo()
    let a = dj["A"]!
    await a.generate(TrackSpec(genre: "techno", seed: 42, structure: structure))
    return (dj, SurfaceController(profile: p, engine: dj), a)
  }

  @Test func apcTrackButtonsMuteTheAimedDecksParts() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2)
    await dj["B"]!.generate(TrackSpec(genre: "house", seed: 3, structure: "standard"))
    let b = dj["B"]!
    a.setPlaying(true)
    b.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("kick") && b.isRoleOn("kick"))
    // track button 1 = kick, on the aimed deck (A to start with)
    s.handle(bytes: [0x90, 100, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && b.isRoleOn("kick"))
    // aim at B (scene 5), press again
    s.handle(bytes: [0x90, 0x74, 0x7F])
    s.handle(bytes: [0x90, 100, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(!b.isRoleOn("kick") && dj.focus == "B")
  }

  @Test func inpulseStemsButtonsMuteTheMusicOrTheLead() async throws {
    let (dj, s, a) = try await make(.inpulse200MK3, structure: nil)  // a loop: every role plays
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    let music = a.roles.filter { ["bass", "melody", "harmony", "arp"].contains($0) }
    #expect(music.contains("melody") && music.allSatisfy { a.isRoleOn($0) } && a.isRoleOn("kick"))
    _ = s.ledFrame()
    // STEMS music (note icon, 0x09): everything but the drums goes, and its LED lights
    s.handle(bytes: [0x91, 0x09, 0x7F])
    s.handle(bytes: [0x91, 0x09, 0x00])
    _ = try renderOffline(dj, frames: 2048)
    #expect(music.allSatisfy { !a.isRoleOn($0) } && a.isRoleOn("kick"))
    #expect(a.isStemMuted("music") && !a.isStemMuted("mic"))
    #expect(s.ledFrame().contains([0x91, 0x09, 0x7F]))
    // STEMS mic (0x0A) on top, then music back: the lead stays out until mic is pressed again
    s.handle(bytes: [0x91, 0x0A, 0x7F])
    s.handle(bytes: [0x91, 0x09, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("bass") && !a.isRoleOn("melody") && !a.isStemMuted("music"))
    s.handle(bytes: [0x91, 0x0A, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(music.allSatisfy { a.isRoleOn($0) } && !a.isStemMuted("mic"))
    // only changes go out: mic's LED went on and off between frames, music's went off
    #expect(s.ledFrame() == [[0x91, 0x09, 0x00]])
    // deck B's buttons are deck B's
    s.handle(bytes: [0x92, 0x0A, 0x7F])
    #expect(dj.focus == "B" && !a.isStemMuted("mic"))
  }

  @Test func aStemBringsBackOnlyWhatItSilenced() async throws {
    // a song's intro has its music silent by arrangement: muting and unmuting the stem must
    // not bring it in early
    let (dj, s, a) = try await make(.inpulse200MK3)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    let silent = a.roles.filter {
      ["bass", "melody", "harmony", "arp"].contains($0) && !a.isRoleOn($0)
    }
    #expect(!silent.isEmpty, "the intro holds some of the music back")
    s.handle(bytes: [0x91, 0x09, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isStemMuted("music"))
    s.handle(bytes: [0x91, 0x09, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isStemMuted("music") && silent.allSatisfy { !a.isRoleOn($0) })
  }

  /// The grid is beats' macro layout (lib/backend/apc-mini-mk2.js), in beats' group colours,
  /// bright while a macro runs; beats' macros dj doesn't have stay dark.
  @Test func apcPadsAreBeatsMacroGridInGroupColours() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    let frame = s.ledFrame()
    #expect(frame.contains([0x92, 0, 5]), "drop: Mute red")
    #expect(frame.contains([0x92, 8, 37]), "sweep-lp: FX cyan")
    #expect(frame.contains([0x92, 11, 0]), "delay-throw: not in dj, dark")
    #expect(frame.contains([0x92, 32, 53]), "octave-up: Pitch magenta")
    #expect(frame.contains([0x92, 36, 13]), "half-time: Tempo yellow")
    #expect(frame.contains([0x92, 40, 21]), "feel-chill: Feel green")
    #expect(frame.contains([0x92, 56, 3]), "hit 1: white")
    s.handle(bytes: [0x90, 0, 0x7F])  // drop
    _ = try renderOffline(dj, frames: 4096)
    #expect(a.wave.activeMacros.contains(.drop))
    #expect(s.ledFrame(now: 1_000_000).contains([0x96, 0, 5]), "bright while it runs")
  }

  @Test func apcFadersSetTheAimedDecksFX() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2, structure: nil)
    s.handle(bytes: [0xB0, 0x34, 0])  // fader 5: LP fully closed
    s.handle(bytes: [0xB0, 0x37, 127])  // fader 8: crush all the way
    s.handle(bytes: [0xB0, 0x36, 127])  // fader 7: master pitch +12
    s.handle(bytes: [0xB0, 0x32, 127])  // fader 3: reverb wet
    s.handle(bytes: [0xB0, 0x33, 0])  // fader 4: reverb size
    #expect(a.wave.masterFxSet[.lpFreq] == 0 && a.wave.masterFxSet[.crushBits] == 100)
    #expect(a.wave.masterFxSet[.masterPitch] == 12)
    #expect(a.reverb.wet == 1 && a.reverb.size == 0)
    // aimed at B: the same faders move B's
    s.handle(bytes: [0x90, 0x74, 0x7F])
    s.handle(bytes: [0xB0, 0x32, 64])
    #expect(abs(dj["B"]!.reverb.wet - 64.0 / 127) < 1e-9 && a.reverb.wet == 1)
  }

  @Test func apcMacroPadsFireMacrosAndPanicRestores() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("bass") && a.isRoleOn("kick"))
    s.handle(bytes: [0x90, 0, 0x7F])  // bottom row, col 0: drop (aimed deck A)
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("bass") && a.isRoleOn("kick"), "drop mutes the non-drums")
    s.handle(bytes: [0x90, 0x77, 0x7F])  // scene 8: panic
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("bass"))
    s.handle(bytes: [0x90, 1, 0x7F])  // breakdown mutes the drums
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && a.isRoleOn("bass"))
  }

  @Test func macroPadsDoNothingOnASampleDeck() async throws {
    let (dj, s, _) = try await make(.apcMiniMK2)
    let b = dj["B"]!
    #expect(b.mode == .sample)
    // aimed at B (a sample): its drop pad, a part mute: must not crash or change anything
    s.handle(bytes: [0x90, 0x74, 0x7F])
    s.handle(bytes: [0x90, 0, 0x7F])
    s.handle(bytes: [0x90, 100, 0x7F])
    #expect(b.mode == .sample && b.roles.isEmpty)
  }

  @Test func mpkKeysPlayTheLiveVoiceInScale() async throws {
    let (dj, s, a) = try await make(.mpkMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    for r in ["kick", "snare", "hihat", "bass", "melody", "harmony"] { a.setRole(r, on: false) }
    _ = try renderOffline(dj, frames: 8192)
    let quiet = try renderOffline(dj, frames: 4096).reduce(0) { max($0, abs($1)) }
    // 61 is outside the scale of this project's key; the controller snaps it.
    s.handle(bytes: [0x90, 61, 110])
    let loud = try renderOffline(dj, frames: 8192).reduce(0) { max($0, abs($1)) }
    #expect(loud > quiet + 0.02, "the held key is audible (\(loud) vs \(quiet))")
    #expect(a.heldKeys[61] == a.scaleLocked(61))
    s.handle(bytes: [0x80, 61, 0])
    #expect(a.heldKeys[61] == nil)
  }

  @Test func mpkPadsTurnTheAimedDecksPartsOffAndOnAndTheJoystickNudgesTempo() async throws {
    let (dj, s, a) = try await make(.mpkMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    dj.focus = "A"
    #expect(a.isRoleOn("kick") && a.isRoleOn("bass"))
    s.handle(bytes: [0x99, 36, 100])  // pad 1: kick off
    s.handle(bytes: [0x99, 40, 100])  // pad 5: bass off
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && !a.isRoleOn("bass") && a.isRoleOn("snare"))
    s.handle(bytes: [0x99, 36, 100])  // pad 1 again: kick back
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("kick"))
    // joystick full right → +8 % on the focus deck
    dj.focus = "A"
    let base = a.netBaseBPM
    s.handle(bytes: [0xE0, 0x7F, 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(abs(a.wave.tempo - base * (1 + Deck.pitchRange)) < 1e-6)
    s.handle(bytes: [0xE0, 0x00, 0x40])  // centre
    _ = try renderOffline(dj, frames: 2048)
    #expect(abs(a.wave.tempo - base) < 0.05)
  }

  @Test func inpulsePadsDriveMacrosRolesAndStingers() async throws {
    let (dj, s, a) = try await make(.inpulse200MK3, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    // deck A rollPads (channel 6 = 0x96), notes by profile
    let prof = SurfaceProfile.inpulse200MK3
    func note(_ group: String, _ i: Int) -> UInt8 { prof.number(group: group, index: i)! }
    s.handle(bytes: [0x96, note("deckA.rollPads", 3), 0x7F])  // breakdown
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && a.isRoleOn("bass"))
    s.handle(bytes: [0x96, note("deckA.fxPads", 3), 0x7F])  // role: bass
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("bass"))
  }

  @Test func hotCuesOnANetDeckAreTicks() async throws {
    let (dj, _, a) = try await make(.apcMiniMK2)
    a.wave.setTempo(600)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 30_000)
    let t1 = a.wave.tick
    #expect(t1 > 20)
    a.hotCue(0)
    #expect(a.hotCues[0] == Double(t1))
    _ = try renderOffline(dj, frames: 60_000)
    a.hotCue(0)  // jump back
    let back = await eventually {
      _ = try? renderOffline(dj, frames: 4096)
      return abs(a.wave.tick - t1) < 80  // swapped in at a bar, then ran on a little
    }
    #expect(back)
  }
}

@MainActor
struct SurfaceBeatTests {
  @Test func inpulseSyncRewindAndLoadButtons() async throws {
    let dj = try DJEngine(offline: true)
    let a = dj["A"]!
    let b = dj["B"]!
    await a.generate(
      TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(127))])))
    b.loadDemo()
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    // deck B (channel 2): SYNC is deckB.buttons[2] → note 5
    let prof = SurfaceProfile.inpulse200MK3
    let syncB = prof.number(group: "deckB.buttons", index: 2)!
    s.handle(bytes: [0x92, syncB, 0x7F])
    #expect(abs(b.effectiveBPM! - 127) < 1e-9)
    let led = s.ledFrame()
    let lit: [UInt8] = [0x92, syncB, prof.leds!.singleOn]
    #expect(led.contains(lit), "SYNC lights while the tempi match: \(led)")
    // shift + SYNC = bar sync (shift buttons live on channel 5 for deck B)
    let shiftSyncB = prof.number(group: "deckB.shiftButtons", index: 0)!
    b.pitch = 0
    s.handle(bytes: [0x95, shiftSyncB, 0x7F])
    #expect(abs(b.effectiveBPM! - 127) < 1e-9)
    // rewind (shift + CUE)
    b.turntable.send(.seek(sample: 30_000))
    _ = try { dj.stop() }()
    let shiftCueB = prof.number(group: "deckB.shiftButtons", index: 1)!
    s.handle(bytes: [0x95, shiftCueB, 0x7F])
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 256)
    #expect(b.turntable.position < 1000)
  }

  @Test func apcScenesAimPlayAndAutoNext() throws {
    let dj = try DJEngine(offline: true)
    let s = SurfaceController(profile: .apcMiniMK2, engine: dj)
    let (a, b) = (dj["A"]!, dj["B"]!)
    a.loadDemo()
    b.loadDemo()
    s.handle(bytes: [0x90, 0x70, 0x7F])  // play: the aimed deck, A
    #expect(a.playing && !b.playing)
    s.handle(bytes: [0x90, 0x74, 0x7F])  // aim at B
    s.handle(bytes: [0x90, 0x70, 0x7F])
    #expect(b.playing)
    s.handle(bytes: [0x90, 0x72, 0x7F])  // auto-next on B
    #expect(b.autoAdvance && !a.autoAdvance)
    #expect(s.ledFrame().contains([0x90, 0x72, 1]))
  }

}
