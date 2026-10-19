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
    #expect(row("pads", 0).action == "macro drop · aimed deck")
    #expect(row("pads", 8).action == "macro sweep-lp · aimed deck")
    #expect(row("pads", 11).action.hasPrefix("unbound — beats' delay-throw"))
    #expect(row("pads", 56).action == "stinger 1 · aimed deck")
    #expect(row("track", 0).action == "mute kick · aimed deck")
    #expect(row("scene", 3).action == "aim at deck A" && row("scene", 4).action == "aim at deck B")
    #expect(row("scene", 7).action == "panic · aimed deck")
    #expect(row("faders", 0).action == "FX unit filter · aimed deck")
    #expect(row("faders", 4).action == "FX unit crush · aimed deck")
    #expect(row("faders", 7).action == "FX unit room · aimed deck")
    #expect(row("faders", 7).shiftedAction == "FX unit echo · aimed deck")
    #expect(row("faders", 8).action == "master")
    #expect(row("pads", 6).action == "FX unit reset (next beat) · aimed deck")
    #expect(row("pads", 7).action == "FX unit kill (next beat) · aimed deck")
    // SHIFT turns the grid into the loop page, read like text from the top-left
    #expect(row("pads", 56).shiftedAction == "loop 1 in/out")
    #expect(row("pads", 63).shiftedAction == "loop 8 in/out")
    #expect(row("pads", 48).shiftedAction == "loop 9 in/out")
    #expect(row("pads", 0).shiftedAction == "loop 57 in/out")
    #expect(row("pads", 7).shiftedAction == "loop 64 in/out")
    #expect(row("shift", 0).action == "SHIFT")
    let mpk = SurfaceProfile.mpkMiniMK2.deviceMap()
    #expect(mpk.first { $0.group == "keys" && $0.index == 60 }?.action == "live keys (focus deck)")
    #expect(
      mpk.first { $0.group == "padNotes" && $0.index == 0 }?.action == "mute kick · aimed deck")
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
