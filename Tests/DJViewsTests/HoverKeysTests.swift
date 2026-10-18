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
  /// A grid of 3 columns, 7 choices: rows a b c / d e f / g.
  @Test func upAndDownStepARowOnAGrid() {
    let items = ["a", "b", "c", "d", "e", "f", "g"]
    let step = { (from: String?, by: Int, vertical: Bool) in
      HoverKeys.step(items, from: from, by: by, vertical: vertical, columns: 3)
    }
    #expect(step("b", 1, true) == "e", "↓ one row")
    #expect(step("e", -1, true) == "b", "↑ one row")
    #expect(step("b", -1, true) == "b", "↑ on the first row stays put")
    #expect(step("e", 1, true) == "g", "↓ into a short row: its last pad")
    #expect(step("g", 1, true) == "g", "↓ on the last row stays put")
    #expect(step("f", 1, true) == "g")
    #expect(step("c", 1, false) == "d", "→ still steps one, wrapping into the next row")
    #expect(step("d", -1, false) == "c")
    #expect(step(nil, 1, true) == "a", "nothing current: first")
    #expect(step(nil, -1, true) == "g", "nothing current: last")
    #expect(HoverKeys.isVertical(keyDown(125)) && HoverKeys.isVertical(keyDown(126)))
    #expect(!HoverKeys.isVertical(keyDown(123)) && !HoverKeys.isVertical(keyDown(124)))
  }

  @Test func oneDimensionalListsAreUnchanged() {
    let items = ["techno", "house", "jazz"]
    for vertical in [false, true] {
      for from in [nil, "techno", "house", "jazz"] as [String?] {
        for by in [-1, 1] {
          #expect(
            HoverKeys.step(items, from: from, by: by, vertical: vertical, columns: 1)
              == HoverKeys.step(items, from: from, by: by))
        }
      }
    }
    // a 1-D list's handler still gets ↑ / ↓ as -1 / +1
    let keys = HoverKeys()
    var total = 0
    keys.enter(newListID()) { total += $0 }
    #expect(keys.handle(keyDown(125)) && total == 1)
    #expect(keys.handle(keyDown(126)) && total == 0)
    // and a grid's is told which axis
    var moves: [String] = []
    keys.enter(newListID(), move: { moves.append("\($0)\($1 ? "v" : "h")") })
    _ = keys.handle(keyDown(125))
    _ = keys.handle(keyDown(123))
    #expect(moves == ["1v", "-1h"])
  }
}
