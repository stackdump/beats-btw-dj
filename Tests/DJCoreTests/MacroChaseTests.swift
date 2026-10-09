import Testing

@testable import DJCore

// SPEC mode 26: the chase arithmetic (controllers.js `macroPulse`: BLINK = 120, element 0 first,
// wrapping), the targets of the catalogue's macros, and the CSS numbers of the glow.
struct MacroChaseTests {
  func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

  @Test func theRunningLightMovesEveryHundredAndTwentyMilliseconds() {
    var c = MacroChase(macro: .drop, targets: ["bass", "melody", "harmony"])
    #expect(MacroChase.step == 0.12)
    #expect(c.hot == "bass" && c.hotIndex == 0, "the first frame lights element 0 at once")
    c.advance(by: 0.119)
    #expect(c.hot == "bass", "just before the boundary")
    c.advance(by: 0.001)
    #expect(c.hot == "melody", "120 ms: the second")
    c.advance(by: 0.12)
    #expect(c.hot == "harmony" && c.steps == 2)
    c.advance(by: 0.12)
    #expect(c.hot == "bass" && c.steps == 3, "and it wraps round")
    c.advance(by: 0.36)
    #expect(c.hot == "bass" && c.steps == 6, "two more laps")
  }

  @Test func aClockOfSmallStepsSitsOnTheBoundaryNotUnderIt() {
    var c = MacroChase(macro: .cut, targets: ["a", "b"])
    for _ in 0..<3 { c.advance(by: 0.04) }  // 0.12000000000000001
    #expect(c.hot == "b")
    var d = MacroChase(macro: .cut, targets: ["a", "b"])
    for _ in 0..<12 { d.advance(by: 0.01) }  // 0.12 summed in hundredths: 0.12 or a hair under
    #expect(d.hot == "b", "a hair under 120 ms must still count: \(d.elapsed)")
    // a 30 Hz poll: 33.3 ms per frame
    var e = MacroChase(macro: .cut, targets: ["a", "b", "c"])
    var seen: [String] = []
    for _ in 0..<12 {
      e.advance(by: 1.0 / 30)
      seen.append(e.hot!)
    }
    // frame n is at n/30 s: step = floor(n * 0.2778) = 0 0 0 1 1 1 1 2 2 2 3 3 -> a a a b b b b c c c a a
    #expect(seen == ["a", "a", "a", "b", "b", "b", "b", "c", "c", "c", "a", "a"], "\(seen)")
    #expect(e.steps == 3, "0.4 s is three 120 ms steps")
  }

  @Test func noTargetsMeansNothingIsHot() {
    var c = MacroChase(macro: .drop, targets: [])
    #expect(c.hot == nil && c.hotIndex == nil)
    c.advance(by: 1)
    #expect(c.hot == nil)
    c.retarget(["bass"])
    #expect(c.hot == "bass")
  }

  @Test func retargetingKeepsTheLightWhereItIs() {
    var c = MacroChase(macro: .drop, targets: ["bass", "melody", "harmony", "arp"])
    c.advance(by: 0.25)  // two steps: harmony
    #expect(c.hot == "harmony")
    c.retarget(["bass", "melody"])  // the engine now holds two: step 2 % 2 = 0
    #expect(c.hot == "bass" && c.elapsed == 0.25)
  }

  @Test func negativeAndNonFiniteTimeIsIgnored() {
    var c = MacroChase(macro: .drop, targets: ["a", "b"])
    c.advance(by: -1)
    c.advance(by: .nan)
    c.advance(by: .infinity)
    #expect(c.elapsed == 0 && c.hot == "a")
  }

  @Test func theCatalogueSaysWhichMacrosChaseAndWhatTheyTouch() {
    // catalog.js: drop / solo-drums -> nonDrums, breakdown -> drumsOnly, cut -> everything
    #expect(NetMacro.drop.chaseTargets == .nonDrums)
    #expect(NetMacro.soloDrums.chaseTargets == .nonDrums)
    #expect(NetMacro.breakdown.chaseTargets == .drumsOnly)
    #expect(NetMacro.cut.chaseTargets == .everything)
    // compound, beat-repeat and tempo kinds never call macroPulse in the JS
    for m in [NetMacro.doubleDrop, .beatRepeat, .halfTime, .tapeStop, .tempoAnchor] {
      #expect(m.chaseTargets == nil, "\(m)")
    }
  }

  @Test func theBoardStartsAChaseWhenAMacroAppearsAndEndsItWhenItDoes() {
    var board = MacroChaseBoard()
    #expect(board.state == MacroPulseState())
    let drop = MacroActivity(running: [.drop], targets: [.drop: ["bass", "melody", "harmony"]])
    board.update(drop, dt: 0.5)  // the first update starts the chase: no time has passed yet
    #expect(board.state.hot == ["bass"] && board.state.pulsing == ["bass", "melody", "harmony"])
    #expect(board.state.running == [.drop] && board.chases.count == 1)
    board.update(drop, dt: 0.12)
    #expect(board.state.hot == ["melody"])
    board.update(drop, dt: 0.12)
    #expect(board.state.hot == ["harmony"])
    board.update(drop, dt: 0.12)
    #expect(board.state.hot == ["bass"], "wraps")
    board.update(.idle, dt: 0.033)  // the engine says the macro is over
    #expect(board.state == MacroPulseState() && board.chases.isEmpty, "end on macro end")
    // the next fire starts from the first target again
    board.update(drop, dt: 0.033)
    #expect(board.state.hot == ["bass"])
  }

  @Test func aMacroWithoutAChaseOnlyShowsRunning() {
    var board = MacroChaseBoard()
    board.update(MacroActivity(running: [.beatRepeat, .halfTime], targets: [:]), dt: 0.1)
    #expect(board.state.running == [.beatRepeat, .halfTime])
    #expect(board.state.pulsing.isEmpty && board.state.hot.isEmpty && board.chases.isEmpty)
    #expect(board.state.isRunning(.beatRepeat) && !board.state.isRunning(.drop))
  }

  @Test func twoMacrosChaseAtOnceAndEachEndsOnItsOwn() {
    var board = MacroChaseBoard()
    let both = MacroActivity(
      running: [.drop, .breakdown],
      targets: [.drop: ["bass", "melody"], .breakdown: ["kick", "snare", "hihat"]])
    board.update(both, dt: 0)
    #expect(board.state.hot == ["bass", "kick"], "one light per macro")
    #expect(board.state.pulsing == ["bass", "melody", "kick", "snare", "hihat"])
    board.update(both, dt: 0.12)
    #expect(board.state.hot == ["melody", "snare"])
    board.update(
      MacroActivity(running: [.breakdown], targets: [.breakdown: ["kick", "snare"]]), dt: 0.12)
    #expect(board.state.running == [.breakdown] && board.chases.count == 1)
    #expect(board.state.pulsing == ["kick", "snare"], "retargeted to what the engine still holds")
    #expect(board.state.hot == ["kick"], "step 2 of 2 targets")
    #expect(board.state.level(of: "kick") == .hot && board.state.level(of: "snare") == .dim)
    #expect(board.state.level(of: "bass") == .none)
  }

  @Test func aRoleHotInOneChaseIsHotWhateverTheOtherSays() {
    var board = MacroChaseBoard()
    let both = MacroActivity(
      running: [.drop, .soloDrums],
      targets: [.drop: ["bass", "melody"], .soloDrums: ["melody", "bass"]])
    board.update(both, dt: 0)
    #expect(board.state.hot == ["bass", "melody"])
    #expect(board.state.level(of: "bass") == .hot && board.state.level(of: "melody") == .hot)
  }

  @Test func theGlowNumbersAreBeatsCss() {
    #expect(MacroPulseStyle.dim == .init(spread: 1, blur: 4, alpha: 0.35))
    #expect(MacroPulseStyle.hot == .init(spread: 3, blur: 10, alpha: 0.95))
    #expect(MacroPulseStyle.glow(.none) == nil)
    #expect(MacroPulseStyle.glow(.dim) == MacroPulseStyle.dim)
    #expect(MacroPulseStyle.glow(.hot) == MacroPulseStyle.hot)
    #expect(MacroPulseStyle.color.rgb8 == (233, 69, 96))
    #expect(MacroPulseStyle.runningFill.rgb8 == (233, 69, 96))
    #expect(MacroPulseStyle.runningBorder.rgb8 == (248, 179, 192))
  }

  @Test func theRunningButtonBreathesOnAOneSecondEaseInOut() {
    typealias S = MacroPulseStyle
    #expect(S.runningPeriod == 1)
    let rest = S.runningGlow(at: 0)
    #expect(rest == S.runningRest && S.runningGlow(at: 1) == S.runningRest, "0% and 100%")
    let peak = S.runningGlow(at: 0.5)
    #expect(near(peak.spread, 3) && near(peak.blur, 10) && near(peak.alpha, 0.95), "50%")
    // a quarter of the way: half of each half, ease-in-out(0.5) = 0.5
    let q = S.runningGlow(at: 0.25)
    #expect(near(q.spread, 1.5) && near(q.blur, 5) && near(q.alpha, 0.825), "\(q)")
    // an eighth: progress 0.25 of the rise, eased: cubic-bezier(.42, 0, .58, 1)(0.25) = 0.12916193...
    let e = S.runningGlow(at: 0.125)
    #expect(near(e.blur, 10 * 0.1291619310473198, 1e-6), "\(e.blur)")
    // symmetrical on the way down
    #expect(near(S.runningGlow(at: 0.875).blur, e.blur, 1e-9))
    // and periodic
    #expect(
      near(S.runningGlow(at: 3.125).blur, e.blur, 1e-9)
        && near(S.runningGlow(at: -0.875).blur, e.blur, 1e-9))
  }

  @Test func easeInOutMatchesTheCssCurve() {
    // reference values from an independent bisection in node
    let want: [(Double, Double)] = [
      (0, 0), (0.1, 0.019722453548311196), (0.25, 0.1291619310473198), (0.5, 0.5),
      (0.75, 0.8708380689526802), (0.9, 0.9802775464516887), (1, 1),
    ]
    for (x, y) in want { #expect(near(MacroPulseStyle.easeInOut(x), y, 1e-9), "x = \(x)") }
    #expect(MacroPulseStyle.easeInOut(-1) == 0 && MacroPulseStyle.easeInOut(2) == 1)
  }
}
