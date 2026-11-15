import DJCore
import DJRustMIDI
import DJRustUI
import Testing

// The Inpulse 200 MK3's bindings on the djrust decks: bytes made from the profile itself (each
// control's own number and channel) decode and map to the model's actions, and every captured
// message from the real unit decodes without a binding that maps wrongly.

private let inpulse = SurfaceProfile.inpulse200MK3

/// The MIDI a control sends: a note-on / CC on its group's channel, value `v`.
private func bytes(_ group: String, _ index: Int, _ v: UInt8) -> [UInt8] {
  let g = inpulse.group(group)!
  let n = inpulse.number(group: group, index: index)!
  let status: UInt8 = g.type == .note ? 0x90 : 0xB0
  return [status | (g.channel ?? 0), n, v]
}

private func actions(_ data: [UInt8], lead: String = "A") -> [ControllerAction] {
  var dec = SurfaceDecoder(profile: inpulse)
  guard let e = dec.decode(data) else { return [] }
  return RustControllers.bindings(inpulse, e, shift: false).compactMap { RustControllers.action($0, e, lead: lead) }
}

@Test func buttonsActOnThePressOnly() {
  #expect(actions(bytes("deckA.buttons", 4, 127)) == [.play(deck: "A")])
  #expect(actions(bytes("deckA.buttons", 4, 0)) == [])
  #expect(actions(bytes("deckB.buttons", 2, 127)) == [.sync(deck: "B")])
  #expect(actions(bytes("deckB.buttons", 8, 127)) == [.next(deck: "B")])
  #expect(actions(bytes("deckA.shiftButtons", 1, 127)) == [.previous(deck: "A")])
}

@Test func padsToggleRolesAndHoldEffects() {
  #expect(actions(bytes("deckA.fxPads", 0, 127)) == [.roleToggle(deck: "A", role: "kick")])
  #expect(actions(bytes("deckB.rollPads", 0, 127)) == [.effect(deck: "B", id: "cut", down: true)])
  #expect(actions(bytes("deckB.rollPads", 0, 0)) == [.effect(deck: "B", id: "cut", down: false)])
}

@Test func fadersSendTheirPosition() {
  #expect(actions(bytes("mixer.faders", 0, 127)) == [.crossfader(position: 1)])
  guard case .volume(let d, let p)? = actions(bytes("deckA.faders", 0, 64)).first else {
    Issue.record("deck A's volume fader isn't bound")
    return
  }
  #expect(d == "A" && abs(p - 64.0 / 127) < 0.01)
}

@Test func controlsDjmobileCantPlayStayUnbound() {
  // EQ, gain, cue: bound in the profile, no call in djmobile's Player
  for e in inpulse.layout where [.eqLow, .eqMid, .eqHigh, .gain, .cue, .hotcue].contains(e.action) {
    guard let i = e.index, let g = inpulse.group(e.group), g.type == .note || g.type == .cc else { continue }
    #expect(actions(bytes(e.group, i, 127)).isEmpty, "\(e.group)[\(i)] \(e.action)")
  }
}
