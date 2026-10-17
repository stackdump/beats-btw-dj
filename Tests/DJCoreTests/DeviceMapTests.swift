import Testing

@testable import DJCore

struct DeviceMapTests {
  @Test func everyControlOfEveryDeviceHasARow() {
    for p in SurfaceProfile.all {
      let rows = p.deviceMap()
      let expected = p.groups.reduce(0) {
        $0 + ($1.type == .pitchbend ? 1 : $1.controlNumbers.count)
      }
      #expect(rows.count == expected, Comment(rawValue: p.name))
      #expect(!rows.contains { $0.action == "unmapped" }, "\(p.name): a control fell through")
    }
  }

  @Test func rowsReadLikeTheLayout() {
    let apc = SurfaceProfile.apcMiniMK2.deviceMap()
    func row(_ g: String, _ i: Int) -> DeviceMapRow {
      apc.first { $0.group == g && $0.index == i }!
    }
    #expect(row("pads", 0).action == "hot cue 1 · deck A")
    #expect(row("pads", 16 + 2).action == "section 3 · deck A")
    #expect(row("pads", 32 + 15).action == "section 16 · deck B")
    #expect(row("pads", 48).action == "macro drop · deck A")
    #expect(row("pads", 56 + 3).action == "panic · deck A")
    #expect(row("track", 1).action == "mute kick · deck A")
    #expect(row("track", 1).shiftedAction == "mute kick · deck B", "SHIFT aims it at deck B")
    #expect(
      row("track", 0).action == "play · deck A" && row("track", 0).shiftedAction == "unbound"
        || row("track", 0).shiftedAction?.hasPrefix("quantize") == true)
    // SHIFT turns the grid into the loop page, read like text from the top-left
    #expect(row("pads", 56).shiftedAction == "loop 1 in/out")
    #expect(row("pads", 63).shiftedAction == "loop 8 in/out")
    #expect(row("pads", 48).shiftedAction == "loop 9 in/out")
    #expect(row("pads", 0).shiftedAction == "loop 57 in/out")
    #expect(row("pads", 7).shiftedAction == "loop 64 in/out")
    #expect(row("faders", 4).action == "headphone mix")
    #expect(row("shift", 0).action == "SHIFT")
    let mpk = SurfaceProfile.mpkMiniMK2.deviceMap()
    #expect(mpk.first { $0.group == "keys" && $0.index == 60 }?.action == "live keys (focus deck)")
    #expect(mpk.first { $0.group == "padNotes" && $0.index == 0 }?.action == "stinger 1 · deck A")
    #expect(mpk.first { $0.group == "joystickX" }?.action == "tempo nudge (focus deck)")
    let ip = SurfaceProfile.inpulse200MK3.deviceMap()
    #expect(ip.first { $0.group == "deckB.buttons" && $0.index == 2 }?.action == "sync · deck B")
    #expect(
      ip.first { $0.group == "deckB.buttons" && $0.index == 7 }?.action == "headphone cue · deck B")
    #expect(
      ip.first { $0.group == "deckA.shiftButtons" && $0.index == 0 }?.action
        == "sync to bar · deck A")
  }

  @Test func parkedControlsSayWhy() {
    let rows = SurfaceProfile.inpulse200MK3.deviceMap().filter(\.parked)
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.action.hasPrefix("unbound — ") })
  }

  @Test func numbersArePresent() {
    let apc = SurfaceProfile.apcMiniMK2.deviceMap()
    #expect(apc.first { $0.group == "pads" && $0.index == 10 }?.number == 10)
    #expect(apc.first { $0.group == "track" && $0.index == 3 }?.number == 103)
  }
}
