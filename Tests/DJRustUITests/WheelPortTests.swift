import DJRustUI
import Testing

// djandroid's PickerAnchorTest and WheelLogTest (at the rev in rust/PINS), the same numbers.

@Test func aSwitchHoldsThePickerWhileItSettlesAndOnlyThen() {
  let a = PickerAnchor()
  var to: [Double] = []
  let s: (Double) -> Void = { to.append($0) }
  a.placed(contentY: 1200, scroll: 600, id: "cmaj7-hoop", nowMs: 0, scrollTo: s)  // the picker 600 down the viewport
  a.placed(contentY: 1200, scroll: 700, id: "cmaj7-hoop", nowMs: 10, scrollTo: s)  // the user scrolls: left alone (now 500 down)
  a.hold("marble-run")
  a.placed(contentY: 1200, scroll: 700, id: "cmaj7-hoop", nowMs: 20, scrollTo: s)  // still the old instrument: wait
  a.placed(contentY: 912, scroll: 700, id: "marble-run", nowMs: 30, scrollTo: s)  // the cards above shrank by 288: back to 500 down
  a.placed(contentY: 912, scroll: 700, id: "marble-run", nowMs: 35, scrollTo: s)  // asked again before it landed: the same target
  a.placed(contentY: 912, scroll: 412, id: "marble-run", nowMs: 40, scrollTo: s)  // landed
  a.placed(contentY: 1168, scroll: 412, id: "marble-run", nowMs: 300, scrollTo: s)  // a card above grew a poll later
  a.placed(contentY: 1168, scroll: 668, id: "marble-run", nowMs: 2000, scrollTo: s)  // settled: the user's again
  a.placed(contentY: 1168, scroll: 500, id: "marble-run", nowMs: 2100, scrollTo: s)
  #expect(to == [412, 412, 668])
}

@Test func aPickerNearTheTopIsNeverScrolledAboveIt() {
  let a = PickerAnchor()
  var to: [Double] = []
  a.placed(contentY: 300, scroll: 0, id: "slide", nowMs: 0) { to.append($0) }
  a.hold("pendulum")
  a.placed(contentY: 100, scroll: 0, id: "pendulum", nowMs: 10) { to.append($0) }  // would be −200: stays at 0
  #expect(to.isEmpty)
}

@Test func linesAreKeyValueAndQuoteWhatNeedsIt() {
  let motor: Bool? = nil
  #expect(
    WheelLog.line(
      "switch.start", [("n", 3), ("from", "cmaj7-hoop"), ("to", "marble-run"), ("paused", false), ("motor", motor)])
      == "switch.start n=3 from=cmaj7-hoop to=marble-run paused=false motor=-")
  #expect(
    WheelLog.line("wheel.sequence", [("text", "C E G"), ("bad", "a\"b")]) == #"wheel.sequence text="C E G" bad="a'b""#)
  #expect(WheelLog.line("e", [("empty", ""), ("eq", "a=b"), ("gear", 6.0)]) == #"e empty="" eq="a=b" gear=6.0"#)
}
