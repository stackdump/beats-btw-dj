import Testing

@testable import DJViews

@MainActor
struct HoverKeysTests {
  @Test func arrowsStepThroughTheChoicesAndStopAtTheEnds() {
    let items = ["techno", "house", "jazz"]
    #expect(HoverKeys.step(items, from: "house", by: 1) == "jazz")
    #expect(HoverKeys.step(items, from: "house", by: -1) == "techno")
    #expect(HoverKeys.step(items, from: "jazz", by: 1) == "jazz", "stops at the end")
    #expect(HoverKeys.step(items, from: "techno", by: -1) == "techno")
    #expect(HoverKeys.step(items, from: nil, by: 1) == "techno", "nothing current: first")
    #expect(HoverKeys.step(items, from: "gone", by: -1) == "jazz", "not in the list: last")
    #expect(HoverKeys.step([String](), from: nil, by: 1) == nil)
  }

  @Test func onlyPlainArrowsCount() {
    #expect(HoverKeys.delta(keyDown(123)) == -1 && HoverKeys.delta(keyDown(126)) == -1)
    #expect(HoverKeys.delta(keyDown(124)) == 1 && HoverKeys.delta(keyDown(125)) == 1)
    #expect(HoverKeys.delta(keyDown(0)) == nil, "a letter")
    #expect(HoverKeys.delta(keyDown(124, commandKey)) == nil, "⌘→ is the system's")
  }

  @Test func theInnermostHoveredListGetsTheArrowsAndLeavingHandsThemBack() {
    let keys = HoverKeys()
    var outer = 0
    var inner = 0
    #expect(!keys.handle(keyDown(124)), "nothing hovered: the key goes on")
    let a = newListID()
    let b = newListID()
    keys.enter(a) { outer += $0 }
    keys.enter(b) { inner += $0 }
    #expect(keys.handle(keyDown(124)) && inner == 1 && outer == 0)
    keys.leave(b)
    #expect(keys.handle(keyDown(123)) && outer == -1)
    keys.leave(a)
    #expect(!keys.handle(keyDown(124)))
  }
}
