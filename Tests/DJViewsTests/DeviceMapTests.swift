import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct DeviceMapRenderTests {
  let rows = [
    DeviceMapRow(
      group: "pads", index: 0, control: "pad 1", number: 0, action: "hot cue 1 · deck A",
      shiftedAction: nil, parked: false),
    DeviceMapRow(
      group: "pads", index: 1, control: "pad 2", number: 1, action: "hot cue 2 · deck A",
      shiftedAction: nil, parked: false),
    DeviceMapRow(
      group: "track", index: 0, control: "track 1", number: 100, action: "play · deck A",
      shiftedAction: "quantize · deck A", parked: false),
  ]

  @Test func groupsKeepProfileOrder() {
    let list = DeviceMapList(title: "APC", rows: rows)
    #expect(list.grouped.map(\.group) == ["pads", "track"])
    #expect(list.grouped[0].rows.count == 2)
  }

  @Test func theTouchedRowIsHighlighted() throws {
    let tint = Color(red: 0, green: 0.8, blue: 0.2)
    let quiet = try #require(
      renderPixels(DeviceMapList(title: "APC", rows: rows, tint: tint), width: 420, height: 110))
    let lit = try #require(
      renderPixels(
        DeviceMapList(title: "APC", rows: rows, highlight: ("pads", 1), tint: tint), width: 420,
        height: 110))
    func greenPixels(_ p: Pixels) -> Int {
      p.count(inX: 0..<420, y: 0..<110) { r, g, b in g > 150 && r < 80 && b < 100 }
    }
    #expect(greenPixels(quiet) == 0)
    #expect(greenPixels(lit) > 500, "one row's background is the tint: \(greenPixels(lit))")
    // only one band lit: rows are ~14 px tall
    let band = lit.count(inX: 205..<206, y: 0..<110) { r, g, b in g > 150 && r < 80 && b < 100 }
    #expect(band >= 8 && band < 34, "one row, not two: band \(band)")
  }

  @Test func theWholeAPCMapRenders() throws {
    let rows = SurfaceProfile.apcMiniMK2.deviceMap()
    let list = DeviceMapList(title: "APC mini mk2", rows: rows)
    #expect(list.grouped.map(\.group) == ["pads", "track", "scene", "faders", "shift", "drumPads"])
    savePNG(list, width: 480, height: 1400, name: "device-map-apc")
    #expect(try renderPixels(list, width: 480, height: 200) != nil)
  }
}
