import Testing

@testable import DJCore

// The toolbar's toggle buttons: which button writes which flag. (The SwiftUI buttons do not render
// offscreen, so the wiring is a table, `StageToolAction`, that the toolbar view lays out.)

@MainActor
struct StageToolActionTests {
  /// Every flag a button can write, as a value to compare.
  struct Flags: Equatable {
    var overlays: Set<StageOverlay>
    var expand: Bool
    var backs: Bool
    var labels: Bool
    var card: Bool
    var wander: Bool

    @MainActor init(_ s: StageSettings) {
      overlays = s.overlays
      expand = s.expandVariants
      backs = s.showBacks
      labels = s.showLabels
      card = s.cardOnChange
      wander = s.showWander
    }
  }

  /// What pressing each button must change, written out independently of the table.
  static let effects: [(StageToolAction, (inout Flags) -> Void)] = [
    (.flow, { $0.overlays.formSymmetricDifference([.flow]) }),
    (.pulse, { $0.overlays.formSymmetricDifference([.pulse]) }),
    (.flame, { $0.overlays.formSymmetricDifference([.flame]) }),
    (.tilt, { $0.overlays.formSymmetricDifference([.tilt]) }),
    (.bolts, { $0.overlays.formSymmetricDifference([.bolts]) }),
    (.expand, { $0.expand.toggle() }),
    (.backs, { $0.backs.toggle() }),
    (.labels, { $0.labels.toggle() }),
    (.card, { $0.card.toggle() }),
    (.wander, { $0.wander.toggle() }),
  ]

  @Test func eachButtonFlipsItsOwnFlagAndNothingElse() {
    #expect(Self.effects.count == StageToolAction.allCases.count)
    for (action, effect) in Self.effects {
      let s = StageSettings()
      let before = Flags(s)
      var want = before
      effect(&want)
      action.toggle(s)
      #expect(Flags(s) == want, "\(action)")
      #expect(Flags(s) != before, "\(action) changes something")
      action.toggle(s)
      #expect(Flags(s) == before, "\(action) twice is nothing")
    }
  }

  @Test func aButtonReadsTheFlagItWrites() {
    for action in StageToolAction.allCases {
      let s = StageSettings()
      let was = action.isOn(s)
      action.toggle(s)
      #expect(action.isOn(s) == !was, "\(action)")
    }
    // the defaults of stage.js: flow, pulse, flame and bolts on; the rest off (and dj's wander on)
    let s = StageSettings()
    let on = StageToolAction.allCases.filter { $0.isOn(s) }
    #expect(Set(on) == [.flow, .pulse, .flame, .bolts, .wander])
  }

  @Test func theToolbarOrderIsStageJS() {
    // the four data-viz buttons, expand, backs, labels | card | bolts | help (and dj's wander)
    #expect(
      StageToolAction.beforeCard == [.flow, .pulse, .flame, .tilt, .expand, .backs, .labels])
    let laidOut = StageToolAction.beforeCard + [.card, .bolts, .wander]
    #expect(Set(laidOut) == Set(StageToolAction.allCases) && laidOut.count == 10)
    #expect(StageToolAction.beforeCard.map(\.glyph) == ["◌", "◎", "▼", "⊝", "⇄", "■", "A"])
    #expect(StageToolAction.card.glyph == "✎" && StageToolAction.bolts.glyph == "⚡\u{FE0E}")
    #expect(StageToolAction.wander.glyph == "∿")
    #expect(Set(StageToolAction.allCases.map(\.glyph)).count == 10, "no two buttons look alike")
    #expect(StageToolAction.allCases.allSatisfy { !$0.help.isEmpty })
  }

  @Test func aSoloVisualizerHidesEveryButtonButTheCard() {
    // .viz-solo hides [data-viz], .pn-stage-expand, -backs, -labels, -bolts; and the wander button
    #expect(StageToolAction.hiddenWhileSolo.contains(.wander))
    #expect(StageToolAction.hiddenWhileSolo == Set(StageToolAction.allCases).subtracting([.card]))
  }

  @Test func theOverlayButtonsAreTheOverlays() {
    #expect(StageToolAction.flow.overlay == .flow && StageToolAction.bolts.overlay == .bolts)
    #expect(StageToolAction.expand.overlay == nil && StageToolAction.card.overlay == nil)
    #expect(StageToolAction.wander.overlay == nil, "wander is a setting, not an overlay")
    #expect(Set(StageToolAction.allCases.compactMap(\.overlay)) == Set(StageOverlay.allCases))
  }
}
