import Testing

@testable import DJCore

// The CSS numbers of the constellation's look, pinned as literals (petri-note.css, canvas.js,
// stage.js; the rule or line each comes from is named). A drawing test elsewhere checks that the
// painter uses them; these make a change of a number a failing test of its own.

struct StageStyleTests {
  @Test func nodeSizesAreThePixelsOfTheCSS() {
    // .pn-place-circle { width: 50px; border: 3px solid #4a90d9 }
    #expect(StageStyle.placeRadius == 25 && StageStyle.placeBorder == 3)
    // .pn-transition-rect { width: 40px; border: 3px solid #e94560; border-radius: 6px }
    #expect(StageStyle.transitionHalf == 20 && StageStyle.transitionBorder == 3)
    #expect(StageStyle.transitionCorner == 6)
    // a place is 50 across: the arrowhead stops at its edge (canvas.js `drawArrowhead` offset)
    #expect(StageArcArrow.offset == StageStyle.placeRadius)
    #expect(StageArcArrow.headLength == 12)
  }

  @Test func theGlowIsTheCSSBlurHalved() {
    // box-shadow: 0 0 8px #e94560; a CSS blur radius is twice the Gaussian's deviation
    #expect(StageStyle.glowBlur == 8 && StageStyle.glowSigma == 4)
  }

  @Test func aFiringNodeKeepsItsBodyWhenItCarriesANote() {
    // `.pn-transition.has-midi` (line 2190) beats `.pn-transition.firing` (line 2173) at equal
    // specificity: only a node WITHOUT a note is solid red while it fires
    #expect(!StageStyle.firingBodyIsSolid(hasMidi: true))
    #expect(StageStyle.firingBodyIsSolid(hasMidi: false))
  }

  @Test func tokenDiscsAreOurChoiceNotBeats() {
    // beats draws no tokens; a disc of 10 (one token) or 15 (several) with a bold 16px count,
    // the size the CSS reserves for text in the place circle
    #expect(StageStyle.tokenRadius == 10 && StageStyle.tokenRadiusMany == 15)
    #expect(StageStyle.tokenCountFontSize == 16)
    // both fit inside the place's 22 point inner radius
    #expect(StageStyle.tokenRadiusMany < StageStyle.placeRadius - StageStyle.placeBorder)
  }

  @Test func panelNumbersAreThePanelRules() {
    // .pn-stage-panel { border-radius: 10px; border: 1px solid ... }
    #expect(StageStyle.panelCorner == 10 && StageStyle.panelBorder == 1)
    // .pn-stage-label { top: 8px; left: 10px; font-size: 11px; letter-spacing: 0.08em }
    #expect(StageStyle.labelLeft == 10 && StageStyle.labelTop == 8)
    #expect(StageStyle.labelFontSize == 11 && StageStyle.labelTracking == 0.08)
    // drawPanel: ctx.lineWidth = 2 / view.scale; renderMetaNet: stroke-width 2
    #expect(StageStyle.arcScreenWidth == 2 && StageStyle.metaStrokeWidth == 2)
  }
}

struct StagePaletteTests {
  /// 8-bit channels of a colour.
  func rgb(_ c: ScopeColor) -> [Int] { [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) } }

  @Test func theColoursAreTheCSSOnes() {
    #expect(rgb(StagePalette.background) == [10, 10, 26])  // #0a0a1a
    #expect(rgb(StagePalette.arc) == [74, 144, 217])  // #4a90d9
    #expect(rgb(StagePalette.nodeFill) == [26, 26, 46])  // #1a1a2e
    #expect(rgb(StagePalette.transition) == [233, 69, 96])  // #e94560
    #expect(rgb(StagePalette.transitionMidi) == [45, 31, 61])  // #2d1f3d
    #expect(rgb(StagePalette.backInner) == [19, 26, 51])  // #131a33
    #expect(rgb(StagePalette.backOuter) == [7, 7, 18])  // #070712
    #expect(StagePalette.background.a == 1 && StagePalette.arc.a == 1)
  }

  @Test func theAlphasAreTheCSSOnes() {
    // drawPanel: ctx.globalAlpha = 0.6
    #expect(StagePalette.arcAlpha == 0.6)
    // .pn-stage-panel border: 1px solid rgba(74,144,217,0.18)
    #expect(rgb(StagePalette.backBorder) == [74, 144, 217] && StagePalette.backBorder.a == 0.18)
    // .pn-stage-label: rgba(255,255,255,0.55)
    #expect(rgb(StagePalette.label) == [255, 255, 255] && StagePalette.label.a == 0.55)
  }

  @Test func theMuteFadeIsTheCSS() {
    // .pn-stage-panel.muted { opacity: 0.25 }
    #expect(StageFade.mutedOpacity == 0.25)
  }
}

struct StageEmptyStateTests {
  @Test func theMessageNamesTheDeckAsItIsCalled() {
    // (no lower-casing: "Deck B" is what the toolbar calls it)
    #expect(
      StageEmptyState.message(hasNet: false, source: .deck("B"))
        == "Stage needs a net deck — load a track on Deck B")
    #expect(
      StageEmptyState.message(hasNet: false, source: .master)
        == "Stage needs a net deck — load a track on a deck")
    #expect(
      StageEmptyState.message(hasNet: true, source: .deck("A")) == "Waiting for the first bar…")
  }
}
