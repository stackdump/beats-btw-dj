import Testing

@testable import DJCore

struct ScopeKindTests {
  @Test func theViewsAreTheFourOfScopeJs() {
    #expect(ScopeKind.allCases == [.live, .spectro, .bands, .raster])
    #expect(ScopeKind.allCases.map(\.title) == ["Scope", "Spectro", "Bands", "Raster"])
    #expect(ScopeKind.allCases.map(\.supportsMeasured) == [false, true, true, false])
    #expect(ScopeKind.live.id == "live")
    #expect(ScopeKind.live.help.hasPrefix("Waveform x and fired events"))
  }

  // scope.js viewHeight, worked by hand: room = clamp(round(h * 0.55), 0, 640)
  @Test func liveHeightGrowsWithLanesAndRoom() {
    func h(_ lanes: Int, _ win: Double?) -> Double {
      ScopeKind.viewHeight(kind: .live, measured: false, laneCount: lanes, windowHeight: win)
    }
    #expect(h(10, 800) == 440, "room 440 beats 110 + 12 * 10 = 230")
    #expect(h(32, 800) == 494, "110 + 12 * 32 = 494 beats the room")
    #expect(h(10, 1500) == 640, "room is capped at 640")
    #expect(h(40, 1500) == 640, "and so is the view")
    #expect(h(0, 400) == 220, "room 220")
    #expect(h(0, 100) == 170, "never under 170")
    #expect(h(5, nil) == 440 && h(5, 0) == 440 && h(5, -3) == 440, "unknown window: 800")
  }

  @Test func spectroHeight() {
    func h(_ m: Bool, _ win: Double) -> Double {
      ScopeKind.viewHeight(kind: .spectro, measured: m, laneCount: 10, windowHeight: win)
    }
    #expect(h(false, 800) == 308, "round(440 * 0.7)")
    #expect(h(true, 800) == 440, "max(300, room)")
    #expect(h(false, 400) == 170, "round(220 * 0.7) = 154, floor 170")
    #expect(h(true, 400) == 300)
    #expect(h(true, 1500) == 640)
  }

  @Test func bandsHeightIsFixed() {
    for win in [100.0, 800, 1500] {
      #expect(
        ScopeKind.viewHeight(kind: .bands, measured: false, laneCount: 3, windowHeight: win) == 124)
      #expect(
        ScopeKind.viewHeight(kind: .bands, measured: true, laneCount: 3, windowHeight: win) == 300)
    }
  }

  @Test func rasterHeightFollowsTheLaneCount() {
    func h(_ lanes: Int, _ win: Double) -> Double {
      ScopeKind.viewHeight(kind: .raster, measured: false, laneCount: lanes, windowHeight: win)
    }
    #expect(h(0, 800) == 90, "32 under the floor of 90")
    #expect(h(10, 800) == 312, "10 * 28 + 32")
    #expect(h(32, 800) == 560, "capped at max(560, room)")
    #expect(h(32, 1500) == 640, "min(max(560, 640), 928)")
  }

  @Test func theInstanceMethodIsTheSameRule() {
    #expect(
      ScopeKind.live.height(measured: false, laneCount: 10, windowHeight: 800)
        == ScopeKind.viewHeight(kind: .live, measured: false, laneCount: 10, windowHeight: 800))
  }
}
