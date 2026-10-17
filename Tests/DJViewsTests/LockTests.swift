import DJCore
import Testing

@testable import DJViews

@MainActor
struct LockTests {
  @Test func locksAndDisabledRolesAreRememberedAcrossLaunches() throws {
    let defaults = scratchDefaults()
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let m = AppModel(engine: dj)
    m.defaults = defaults
    m.start()
    m.setLocked("A.panic", true)
    m.setLocked("B.hotcue.0", true)
    #expect(dj.lockedActions == ["A.panic", "B.hotcue.0"] && m.isLocked("A.panic"))
    m.setRoleDisabled("A", "bass", true)
    #expect(dj["A"]!.disabledRoles == ["bass"])
    m.setLocked("B.hotcue.0", false)

    // the next launch
    let dj2 = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let m2 = AppModel(engine: dj2)
    m2.defaults = defaults
    m2.start()
    #expect(m2.lockedButtons == ["A.panic"] && dj2.lockedActions == ["A.panic"])
    #expect(dj2["A"]!.disabledRoles == ["bass"] && dj2["A"]!.roleFilter?.mute == ["bass"])
  }
}
