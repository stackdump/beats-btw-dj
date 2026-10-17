import Testing

@testable import DJCore

@MainActor
struct DisableTests {
  func netDeck(_ dj: DJEngine, seed: Double = 42) async throws -> Deck {
    let a = try #require(dj["A"])
    await a.generate(TrackSpec(genre: "techno", seed: seed, structure: nil))
    a.setPlaying(true)
    return a
  }

  @Test func aDisabledRoleStaysOffThroughANewTrack() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try await netDeck(dj)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 4096)
    #expect(a.isRoleOn("bass"))
    dj.perform(.roleDisable(deck: "A", role: "bass", on: true))
    _ = try renderOffline(dj, frames: 4096)
    #expect(!a.isRoleOn("bass") && a.disabledRoles == ["bass"])
    #expect(a.roleFilter?.mute.contains("bass") == true, "every compile leaves it out")
    // clicking it does nothing while it is disabled
    a.toggleRole("bass")
    dj.perform(.role(deck: "A", role: "bass", on: true))
    _ = try renderOffline(dj, frames: 4096)
    #expect(!a.isRoleOn("bass"))
    // a re-generation: the new song has no bass playing
    await a.generate(TrackSpec(genre: "techno", seed: 7, structure: nil))
    for _ in 0..<40 {
      _ = try renderOffline(dj, frames: 4096)
      a.service()  // the hub's housekeeping tick
    }
    // compiled without its notes (roleFilter), and its button shows it off
    #expect(a.currentSpec?.seed == 7 && !a.isRoleOn("bass"), "off in the new track too")
    // a section that unmutes it is put back by the housekeeping tick
    a.setRole("bass", on: true)
    _ = try renderOffline(dj, frames: 4096)  // the unmute lands on the audio side
    a.service()  // the next tick sees it and mutes it again
    _ = try renderOffline(dj, frames: 4096)
    #expect(!a.isRoleOn("bass"))
    // enabled again: it plays
    dj.perform(.roleDisable(deck: "A", role: "bass", on: false))
    _ = try renderOffline(dj, frames: 4096)
    #expect(a.isRoleOn("bass") && a.disabledRoles.isEmpty && a.roleFilter == nil)
  }

  @Test func disabledRolesAreInASessionsStartAndItsActions() {
    let action = DeckAction.roleDisable(deck: "B", role: "melody", on: true)
    #expect(DeckAction(json: action.json) == action)
    var p = DeckParams()
    #expect(p.json["disabledRoles"] == nil, "untouched: the text is as before")
    p.disabledRoles = ["bass", "melody"]
    #expect(DeckParams(json: p.json).disabledRoles == ["bass", "melody"])
  }

  @Test func aLockedControllerButtonDoesNothing() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try #require(dj["A"])
    a.loadDemo()
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    let play = try #require(s.decode([0x91, 0x07, 0x7F]).flatMap { s.binding(for: $0) })
    #expect(play.lockKey == "A.play")
    dj.lockedActions = ["A.play"]
    s.handle(bytes: [0x91, 0x07, 0x7F])
    #expect(!a.playing, "locked")
    dj.lockedActions = []
    s.handle(bytes: [0x91, 0x07, 0x7F])
    #expect(a.playing)
    // the key names the action, its deck and which one: one hot cue, not all of them
    let cue2 = try #require(s.decode([0x96, 0x02, 0x7F]).flatMap { s.binding(for: $0) })
    #expect(cue2.lockKey == "A.hotcue.1", "pad 2 (note 0x02) is hot cue 2: slot 1")
    #expect(DJActionKind.lockKey(deck: "A", .macro, param: "drop") == "A.macro.drop")
  }
}
