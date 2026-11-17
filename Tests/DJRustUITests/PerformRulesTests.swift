import DJRust
import DJRustUI
import Testing

// djandroid's PerformRulesTest (at the rev in rust/PINS), the same cases.

private func info(_ kind: String, one: Bool = false, choices: [UInt32] = [8, 16, 32], def: UInt32 = 8) -> MoveInfo {
  MoveInfo(
    kind: kind, label: kind, barsMeaning: "phrase (bars)", barChoices: choices, defaultBars: def, deckWord: "deck",
    oneAtATime: one, hasAction: kind == "phrase_sync")
}

private func status(_ kind: String, _ deck: String, phase: String = "armed", left: Double? = 3.2) -> MoveStatus {
  MoveStatus(id: 1, kind: kind, deck: deck, bars: 8, action: "", phase: phase, beatsLeft: left, text: "armed: bar 9")
}

@Test func aRowDefaultsAsTheDesktopAndRoundTripsThroughPrefs() {
  let swap = info("bass_swap", one: true)
  #expect(PerformRules.defaultRow(swap) == MoveRow("B", 8))
  #expect(PerformRules.defaultRow(info("echo_out", choices: [1, 2, 4, 8], def: 4)) == MoveRow("A", 4))
  let r = MoveRow("A", 32, "cut")
  #expect(PerformRules.parseRow(PerformRules.rowText(r), swap) == r)
  #expect(PerformRules.parseRow("A:5:seed", swap) == nil)  // 5 bars is not offered
  #expect(PerformRules.parseRow("C:8:seed", swap) == nil)
  #expect(PerformRules.parseRow("A:8:jump", swap) == nil)
  #expect(PerformRules.parseRow(nil, swap) == nil)
}

@Test func aOneAtATimeMoveIsInFlightWhateverTheRowsDeck() {
  let active = [status("bass_swap", "B"), status("filter_exit", "A")]
  #expect(PerformRules.flight(active, "bass_swap", true, "A")?.deck == "B")
  #expect(PerformRules.flight(active, "filter_exit", false, "A")?.deck == "A")
  #expect(PerformRules.flight(active, "filter_exit", false, "B") == nil)
  let last = [MoveWord(kind: "bass_swap", deck: "*", text: "lows swapped"), MoveWord(kind: "echo_out", deck: "B", text: "B out")]
  #expect(PerformRules.lastWord(last, "bass_swap", true, "B") == "lows swapped")
  #expect(PerformRules.lastWord(last, "echo_out", false, "B") == "B out")
  #expect(PerformRules.lastWord(last, "echo_out", false, "A") == nil)
}

@Test func theCaptionPrefersWhatIsInFlightThenARefusalThenTheLastWord() {
  #expect(PerformRules.caption(status("x", "A"), "refused", "did") == "armed: bar 9 · 4 beats")
  #expect(PerformRules.caption(status("x", "A", left: nil), nil, nil) == "armed: bar 9")
  #expect(PerformRules.caption(nil, "refused", "did") == "refused")
  #expect(PerformRules.caption(nil, nil, "did") == "did")
  #expect(PerformRules.caption(nil, nil, nil) == "")
  #expect(PerformRules.light(status("x", "A", phase: "running")) == "running")
  #expect(PerformRules.light(nil) == nil)
}

@Test func theHintNamesBothKeysAndHowTheyMix() {
  let h = HarmonicHint(a: "Am", b: "C", compat: "relative", mixes: true)
  #expect(PerformRules.hintKeys(h) == "A Am · B C")
  #expect(PerformRules.hintWords(h) == "relative: mixes")
  #expect(PerformRules.hintWords(HarmonicHint(a: "Am", b: "C", compat: "clash", mixes: false)) == "clash")
  let none = HarmonicHint(a: nil, b: nil, compat: nil, mixes: nil)
  #expect(PerformRules.hintKeys(none) == "A ? · B ?")
  #expect(PerformRules.hintWords(none) == "keys unknown")
}
