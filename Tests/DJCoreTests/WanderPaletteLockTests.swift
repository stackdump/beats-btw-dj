import Testing

@testable import DJCore

/// Wander's palette lock: the palette and the drum kit go with every track the walk swaps in.
struct WanderPaletteLockTests {
  func walkSwaps(locks: Set<String>) -> [TrackSpec] {
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    let roles = ["kick", "snare", "hihat", "bass", "melody"]
    var c = WanderContext(
      deck: "A", spec: spec, isLoop: false, roles: roles, rolesOn: Set(roles), disabledRoles: [],
      stemsMuted: [], lockedActions: [], locks: locks, voices: [], anchorBPM: nil, key: nil,
      palette: "minecraft@32", kit: "MuseScore_General.sf2#128:0")
    var swaps: [TrackSpec] = []
    for step in 0..<300 where swaps.count < 6 {
      guard let p = Wander.plan(c, step: step) else { break }
      if case .swap(let s) = p.action {
        swaps.append(s)
        c.spec = s
      }
    }
    return swaps
  }

  @Test func thePaletteLockCarriesThePaletteAndKit() {
    let locked = walkSwaps(locks: ["palette"])
    #expect(locked.count >= 3, "swaps to look at")
    for s in locked {
      let p = s.project()
      #expect(p.palette == "minecraft@32", "\(s.genre) \(s.seed)")
      #expect(p.drumKit == "MuseScore_General.sf2#128:0", "\(s.genre) \(s.seed)")
    }
    #expect(WanderLock.dimensions.contains("palette") && WanderLock.isValid("palette"))
  }

  @Test func withoutTheLockASwapStartsFromItsOwnSounds() {
    for s in walkSwaps(locks: []) {
      #expect(s.project().palette == nil)
      #expect(s.project().drumKit == nil)
    }
  }
}
