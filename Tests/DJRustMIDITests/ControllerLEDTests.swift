import DJCore
import DJRustMIDI
import DJRustUI
import Testing

// The controllers' LEDs on the djrust decks (RustLEDs): what each LED shows for a model state,
// and the bytes a frame sends — status bytes, channels and numbers straight from the profiles.

private let inpulse = SurfaceProfile.inpulse200MK3
private let apc = SurfaceProfile.apcMiniMK2
private let catalogue = [
  ControllerEffect(id: "drop", label: "Drop"), ControllerEffect(id: "tape-stop", label: "Tape Stop"),
  ControllerEffect(id: "br", label: "Beat Repeat"),
]

private func state(_ a: ControllerDeckLights = .init(), _ b: ControllerDeckLights = .init()) -> ControllerLightState {
  ControllerLightState(decks: ["A": a, "B": b], catalogue: catalogue)
}

private func level(
  _ p: SurfaceProfile, _ s: ControllerLightState, _ group: String, _ index: Int, aim: String = "A", shift: Bool = false
) -> PadLight {
  RustLEDs(profile: p).lights(s, aim: aim, shift: shift, now: 100)[group]![index]
}

/// The Inpulse's deck A buttons: play 4, sync 2, next 8, cue 3, PFL 7.
@Test func inpulsePlayShowsTheDeck() {
  #expect(level(inpulse, state(), "deckA.buttons", 4).level == .off)  // nothing loaded
  #expect(level(inpulse, state(.init(loaded: true)), "deckA.buttons", 4).level == .full)
  #expect(level(inpulse, state(.init(loaded: true, playing: true)), "deckA.buttons", 4).level == .blink)
  #expect(level(inpulse, state(.init(loaded: true)), "deckA.buttons", 8).level == .full)
  #expect(level(inpulse, state(.init(loaded: true, composing: true)), "deckA.buttons", 8).level == .blink)
}

@Test func syncLightsAtTheOtherDecksTempo() {
  let a = ControllerDeckLights(loaded: true, tempo: 124)
  #expect(level(inpulse, state(a, .init(loaded: true, tempo: 124.02)), "deckA.buttons", 2).level == .full)
  #expect(level(inpulse, state(a, .init(loaded: true, tempo: 128)), "deckB.buttons", 2).level == .off)
  #expect(level(inpulse, state(a), "deckA.buttons", 2).level == .off)  // B empty
}

@Test func controlsDjmobileCantPlayStayDark() {
  let s = state(.init(loaded: true, playing: true))
  for i in [0, 3, 5, 6, 7] { #expect(level(inpulse, s, "deckA.buttons", i).level == .off, "deckA.buttons[\(i)]") }
  for i in 0..<4 {
    #expect(level(inpulse, s, "deckA.hotcuePads", i).level == .off)
    #expect(level(inpulse, s, "deckA.loopPads", i).level == .off)
  }
}

@Test func aFrameSendsOnlyWhatChanged() {
  var leds = RustLEDs(profile: inpulse)
  let first = leds.frame(state(), aim: "A", shift: false, now: 100)
  // every LED of every single-LED group, once
  let count = inpulse.leds!.singleGroups.reduce(0) { $0 + inpulse.group($1)!.controlNumbers.count }
  #expect(first.count == count)
  #expect(leds.frame(state(), aim: "A", shift: false, now: 100).isEmpty)
  // deck A loaded: play (note 7 on channel 1) and next (note 15) light, nothing else moves
  let next = leds.frame(state(.init(loaded: true)), aim: "A", shift: false, now: 100)
  let play = inpulse.number(group: "deckA.buttons", index: 4)!
  let nxt = inpulse.number(group: "deckA.buttons", index: 8)!
  #expect(Set(next.map { $0 }) == [[0x91, play, 127], [0x91, nxt, 127]])
  // a blackout turns them off and forgets: the next frame sends everything again
  #expect(leds.blackout().count == count)
  #expect(leds.frame(state(), aim: "A", shift: false, now: 100).count == count)
}

/// The APC's grid: pad 0 is "drop", 37 "tape-stop", 4 "beat-repeat" (matched by label).
@Test func apcEffectPadsShowTheirEffect() {
  let rest = level(apc, state(), "pads", 0)
  #expect(rest == PadLight(colorIndex: 5, level: .dim))  // red, dim: there, not on
  #expect(level(apc, state(.init(effects: ["drop": .on])), "pads", 0) == PadLight(colorIndex: 5, level: .full))
  #expect(level(apc, state(.init(effects: ["drop": .waiting])), "pads", 0) == PadLight(colorIndex: 5, level: .blink))
  #expect(level(apc, state(), "pads", 37).colorIndex == 13)  // tape stop: yellow
  #expect(level(apc, state(.init(effects: ["br": .on])), "pads", 4) == PadLight(colorIndex: 5, level: .full))
  // no such effect in djrust (sweep-lp, pad 8): dark
  #expect(level(apc, state(), "pads", 8).colorIndex == 0)
  // "*" follows the aim: B's drop on, A aimed → dim
  #expect(level(apc, state(.init(), .init(effects: ["drop": .on])), "pads", 0, aim: "A").level == .dim)
  #expect(level(apc, state(.init(), .init(effects: ["drop": .on])), "pads", 0, aim: "B").level == .full)
}

@Test func apcFrameBytesUseTheProfilesStatuses() {
  var leds = RustLEDs(profile: apc)
  _ = leds.frame(state(), aim: "A", shift: false, now: 100)
  let n = apc.number(group: "pads", index: 0)!
  #expect(leds.frame(state(.init(effects: ["drop": .on])), aim: "A", shift: false, now: 100) == [[0x96, n, 5]])
  #expect(leds.frame(state(.init(effects: ["drop": .waiting])), aim: "A", shift: false, now: 100) == [[0x9E, n, 5]])
}

@Test func apcRolesAimAndScene() {
  let a = ControllerDeckLights(loaded: true, autoAdvance: true, roles: ["kick": .on, "snare": .paused, "bass": .out])
  #expect(level(apc, state(a), "track", 0).level == .full)  // kick
  #expect(level(apc, state(a), "track", 1).level == .off)  // snare paused
  #expect(level(apc, state(a), "track", 4).level == .off)  // bass locked out
  #expect(level(apc, state(a), "scene", 2).level == .full)  // auto-advance
  #expect(level(apc, state(a), "scene", 3, aim: "A").level == .full)  // aim A
  #expect(level(apc, state(a), "scene", 4, aim: "A").level == .off)
  #expect(level(apc, state(a), "scene", 4, aim: "B").level == .full)
  // SHIFT: the loop page (clips: none in djrust) is dark, and the aim buttons aim at the loops
  #expect(level(apc, state(a), "pads", 0, shift: true).colorIndex == 0)
  #expect(level(apc, state(a), "scene", 3, shift: true).level == .off)
}

@Test func aPressFlashesItsPad() {
  var leds = RustLEDs(profile: apc)
  leds.flash(group: "pads", index: 0, now: 100)
  #expect(leds.lights(state(), aim: "A", shift: false, now: 100.1)["pads"]![0].level == .full)
  #expect(leds.lights(state(), aim: "A", shift: false, now: 100.3)["pads"]![0].level == .dim)
}

@Test func apcSceneButtonsMapToDjrustCalls() {
  func act(_ group: String, _ index: Int) -> ControllerAction? {
    var dec = SurfaceDecoder(profile: apc)
    let n = apc.number(group: group, index: index)!
    let ch = apc.group(group)!.channel ?? 0
    guard let e = dec.decode([0x90 | ch, n, 127]) else { return nil }
    return RustControllers.bindings(apc, e, shift: false).compactMap { RustControllers.action($0, e, lead: "B") }.first
  }
  #expect(act("scene", 1) == .next(deck: "B"))  // regenerate: the next version
  #expect(act("scene", 2) == .autoAdvanceToggle(deck: "B"))
  #expect(act("scene", 7) == .panic(deck: "B"))
  #expect(act("scene", 3) == nil)  // aim: RustControllers keeps it, no model call
  #expect(RustControllers.aim(0) == "A" && RustControllers.aim(1) == "B" && RustControllers.aim(2) == nil)
}
