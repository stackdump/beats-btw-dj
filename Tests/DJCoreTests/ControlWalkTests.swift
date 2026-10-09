import Testing

@testable import DJCore

@Suite struct ControlWalkTests {
  func rows() -> [DeviceMapRow] {
    ["a", "b", "c"].enumerated().map {
      DeviceMapRow(
        group: "g", index: $0.offset, control: $0.element, number: $0.offset, action: "x",
        shiftedAction: nil, parked: false)
    }
  }

  @Test func targetAdvancesAndOthersAreHeard() {
    var w = ControlWalk(device: "d", rows: rows())
    let r1 = w.feed(group: "g", index: 2)
    #expect(!r1)
    #expect(w.heard == "g[2]")
    let r2 = w.feed(group: "g", index: 0)
    #expect(r2)
    #expect(w.position == 1)
    // the finished control keeps streaming: ignored
    let r3 = w.feed(group: "g", index: 0)
    #expect(!r3)
    #expect(w.heard == nil)
  }

  @Test func skipRecordsSilentOrWrong() {
    var w = ControlWalk(device: "d", rows: rows())
    w.skip()
    #expect(w.outcome(group: "g", index: 0) == .skipped)
    _ = w.feed(group: "g", index: 2)
    w.skip()
    #expect(w.outcome(group: "g", index: 1) == .heardInstead("g[2]"))
    let r4 = w.feed(group: "g", index: 2)
    #expect(r4)
    #expect(w.isDone)
    let c = w.counts
    #expect(c.ok == 1 && c.skipped == 1 && c.wrong == 1)
    #expect(w.report.contains("WRONG    g[1]"))
  }

  @Test func backUndoes() {
    var w = ControlWalk(device: "d", rows: rows())
    w.feed(group: "g", index: 0)
    w.back()
    #expect(w.position == 0 && w.outcome(group: "g", index: 0) == nil)
  }

  @Test func realProfileHasRows() {
    for p in SurfaceProfile.all {
      #expect(!ControlWalk(device: p.name, rows: p.deviceMap()).rows.isEmpty)
    }
  }
}
