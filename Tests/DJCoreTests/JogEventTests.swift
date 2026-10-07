import Testing

@testable import DJCore

// Mirrors the parser cases in web/jog/jog.test.mjs.
struct JogEventTests {
  let p = JogProfile.inpulse200MK3

  @Test func bundledProfileLoads() {
    #expect(p.ticksPerRev == 248)
    #expect(p.decks == ["A": 1, "B": 2])
    #expect(p.matches(portName: "DJControl Inpulse 200 Mk3"))
    #expect(!p.matches(portName: "btw Bus 1"))
  }

  @Test(arguments: [(0x01, 1), (0x7F, -1), (0x02, 2), (0x7E, -2), (0x3F, 63), (0x40, -64)])
  func twosComplement(value: UInt8, ticks: Int) {
    #expect(decodeRelative(value) == ticks)
    #expect(encodeRelative(ticks) == value)
  }

  @Test func offset64() {
    #expect(decodeRelative(0x41, .offset64) == 1)
    #expect(decodeRelative(0x3F, .offset64) == -1)
    #expect(encodeRelative(-1, .offset64) == 0x3F)
  }

  @Test func parsesDecksShiftAndKinds() {
    #expect(p.parse([0xB1, 0x0A, 0x01]) == .scratch(deck: "A", shift: false, ticks: 1))
    #expect(p.parse([0xB2, 0x09, 0x7F]) == .bend(deck: "B", shift: false, ticks: -1))
    #expect(p.parse([0xB4, 0x0A, 0x7F]) == .scratch(deck: "A", shift: true, ticks: -1))
    #expect(p.parse([0x91, 0x08, 0x7F]) == .touch(deck: "A", shift: false, down: true))
    #expect(p.parse([0x91, 0x08, 0x00]) == .touch(deck: "A", shift: false, down: false))
    #expect(p.parse([0x81, 0x08, 0x40]) == .touch(deck: "A", shift: false, down: false))
  }

  @Test func ignoresNonJog() {
    #expect(p.parse([0xB0, 0x0A, 0x01]) == nil)  // mixer channel
    #expect(p.parse([0xB1, 0x0A, 0x00]) == nil)  // zero ticks
    #expect(p.parse([0xB1, 0x30, 0x01]) == nil)  // other CC
    #expect(p.parse([0xB1, 0x0A]) == nil)  // short
  }

  @Test func secondsPerTick() {
    #expect(abs(p.secondsPerTick - 1.8 / 248) < 1e-12)
  }
}
