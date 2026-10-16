import Testing

@testable import DJCore

struct ControllerLayoutTests {
  /// Every control a profile maps sits somewhere on its drawing, apart from the ones that are
  /// not a physical control of their own: the APC's DRUM-mode notes (the same pads, another
  /// mode), the MPK's other 127 key numbers (drawn as one keyboard), the Inpulse's pad bend.
  @Test func everyControlIsDrawn() {
    for layout in ControllerLayout.all {
      let profile = SurfaceProfile.all.first { $0.name == layout.profileName }!
      let drawn = Set(layout.spots.flatMap { $0.bindings.map { "\($0.group)/\($0.index)" } })
      let missing = profile.deviceMap().map { "\($0.group)/\($0.index)" }
        .filter { !drawn.contains($0) }
        .filter {
          !$0.hasPrefix("drumPads/") && !$0.hasPrefix("keys/") && !$0.contains("padBend")

        }
      #expect(missing.isEmpty, "\(layout.title): not drawn \(missing)")
    }
  }

  @Test func spotsStayOnTheirDeviceAndApart() {
    for layout in ControllerLayout.all {
      for s in layout.spots {
        #expect(s.x >= -0.01 && s.y >= -0.01, "\(layout.title) \(s.caption ?? "")")
        #expect(
          s.x + s.w <= layout.width + 0.01 && s.y + s.h <= layout.height + 0.01,
          "\(layout.title) \(s.caption ?? "") \(s.bindings.first.map { "\($0.group)/\($0.index)" } ?? "")"
        )
      }
      // no two controls on top of each other (centres at least 0.3 units apart)
      for (i, a) in layout.spots.enumerated() {
        for b in layout.spots[(i + 1)...] {
          let d = abs((a.x + a.w / 2) - (b.x + b.w / 2)) + abs((a.y + a.h / 2) - (b.y + b.h / 2))
          #expect(d > 0.3, "\(layout.title): \(a.caption ?? "") over \(b.caption ?? "")")
        }
      }
    }
  }

  @Test func unverifiedBindingsAreKnown() {
    let inpulse = SurfaceProfile.inpulse200MK3
    #expect(!inpulse.isUnverified(group: "deckA.loopPads", index: 0), "measured")
    #expect(inpulse.isUnverified(group: "deckB.loopPads", index: 0), "deck B mirrors A")
    #expect(SurfaceProfile.mpkMiniMK2.isUnverified(group: "padNotes", index: 9))
  }
}
