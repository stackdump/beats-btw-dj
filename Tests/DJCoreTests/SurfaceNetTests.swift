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

  @Test func apcRoleButtonsToggleRolesAndShiftAimsAtDeckB() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2)
    await dj["B"]!.generate(TrackSpec(genre: "house", seed: 3, structure: "standard"))
    let b = dj["B"]!
    a.setPlaying(true)
    b.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("kick") && b.isRoleOn("kick"))
    // track button 1 = kick: plain press → deck A
    s.handle(bytes: [0x90, UInt8(100 + 1), 0x7F])
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && b.isRoleOn("kick"))
    // hold SHIFT, press again → deck B
    s.handle(bytes: [0x90, 122, 0x7F])
    s.handle(bytes: [0x90, UInt8(100 + 1), 0x7F])
    s.handle(bytes: [0x80, 122, 0x00])
    _ = try renderOffline(dj, frames: 2048)
    #expect(!b.isRoleOn("kick"))
    #expect(dj.focus == "B")
  }

  @Test func apcSectionPadsLaunchSectionsAndLightTheCurrentOne() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2)
    let secs = a.sections
    #expect(secs.count >= 5)
    a.wave.setTempo(600)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    // pad 16 + 3 = deck A, section 3
    s.handle(bytes: [0x90, UInt8(16 + 3), 0x7F])
    let landed = await eventually {
      _ = try? renderOffline(dj, frames: 4096)
      return a.currentSectionIndex == 3
    }
    #expect(landed, "section 3 launched (tick \(a.wave.tick))")
    // LEDs: current section pad is solid bright (status 0x96), others dim (0x92)
    let frame = s.ledFrame()
    #expect(frame.contains([0x96, 19, 9]))  // deck A orange, bright
    #expect(frame.contains([0x92, 18, 9]))
    #expect(!frame.contains { $0[1] == 16 + 15 && $0[2] != 0 }, "pad past the song's end is dark")
    // next-section button (scene 3) steps forward
    s.handle(bytes: [0x90, UInt8(112 + 3), 0x7F])
    let stepped = await eventually {
      _ = try? renderOffline(dj, frames: 4096)
      return a.currentSectionIndex == 4
    }
    #expect(stepped)
  }

  @Test func apcMacroPadsFireMacrosAndPanicRestores() async throws {
    let (dj, s, a) = try await make(.apcMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("bass") && a.isRoleOn("kick"))
    s.handle(bytes: [0x90, UInt8(48 + 0), 0x7F])  // row 6, col 0: deck A drop
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("bass") && a.isRoleOn("kick"), "drop mutes the non-drums")
    s.handle(bytes: [0x90, UInt8(56 + 3), 0x7F])  // row 7, col 3: deck A panic
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("bass"))
    s.handle(bytes: [0x90, UInt8(48 + 1), 0x7F])  // breakdown mutes the drums
    _ = try renderOffline(dj, frames: 2048)
    #expect(!a.isRoleOn("kick") && a.isRoleOn("bass"))
  }

  @Test func macroPadsDoNothingOnASampleDeck() async throws {
    let (dj, s, _) = try await make(.apcMiniMK2)
    let b = dj["B"]!
    #expect(b.mode == .sample)
    // deck B's drop pad (col 4): must not crash or change anything
    s.handle(bytes: [0x90, UInt8(48 + 4), 0x7F])
    s.handle(bytes: [0x90, UInt8(100 + 1), 0x7F])
    s.handle(bytes: [0x90, UInt8(112 + 4), 0x7F])
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

  @Test func mpkPadsRingStingersAndTheJoystickNudgesTempo() async throws {
    let (dj, s, a) = try await make(.mpkMiniMK2, structure: nil)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 2048)
    s.handle(bytes: [0x99, 37, 100])  // pad 2 → deck A stinger 1 (hit2)
    _ = try renderOffline(dj, frames: 2048)
    #expect(a.isRoleOn("hit2"), "the stinger's ring is unmuted for its bar")
    let g = try #require(a.wave.latest?.graph)
    #expect(g.nets[g.byId["hit2"]!].id == "hit2")
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
