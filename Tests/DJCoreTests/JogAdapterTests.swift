import Testing

@testable import DJCore

final class RecordingClock: JogClock {
  var calls: [String] = []
  func freeze() { calls.append("freeze") }
  func scrubBy(seconds: Double) { calls.append(String(format: "scrub %.6f", seconds)) }
  func release() { calls.append("release") }
  func nudge(_ ratio: Double) { calls.append(String(format: "nudge %.4f", ratio)) }
}

struct JogAdapterTests {
  let profile = JogProfile.inpulse200MK3
  var spt: Double { profile.secondsPerTick }

  @Test func touchScratchRelease() {
    let clock = RecordingClock()
    let a = JogAdapter(profile: profile, clock: clock)
    a.handle(.touch(deck: "A", shift: false, down: true))
    a.handle(.touch(deck: "A", shift: false, down: true))  // repeat ignored
    a.handle(.scratch(deck: "A", shift: false, ticks: 2))
    a.handle(.scratch(deck: "A", shift: true, ticks: -1))
    a.handle(.touch(deck: "A", shift: false, down: false))
    #expect(
      clock.calls == [
        "freeze",
        String(format: "scrub %.6f", 2 * spt),
        String(format: "scrub %.6f", -4 * spt),
        "release",
      ])
  }

  @Test func otherDeckIgnored() {
    let clock = RecordingClock()
    let a = JogAdapter(profile: profile, clock: clock, deck: "B")
    a.handle(.touch(deck: "A", shift: false, down: true))
    a.handle(.scratch(deck: "A", shift: false, ticks: 1))
    #expect(clock.calls.isEmpty)
  }

  @Test func untouchedScratchBendsAndDecays() {
    let clock = RecordingClock()
    let a = JogAdapter(profile: profile, clock: clock)
    a.handle(.scratch(deck: "A", shift: false, ticks: 5))
    #expect(a.nudge > 0)
    #expect(clock.calls.isEmpty)  // nudges go out on decay ticks
    a.decay(now: 0)
    #expect(clock.calls.count == 1)
    a.decay(now: 0.15)  // one time constant
    let after = a.nudge
    a.decay(now: 10)
    #expect(a.nudge == 0)
    #expect(clock.calls.last == "nudge 0.0000")
    #expect(after > 0 && after < 0.5)
  }

  @Test func bendSettlesAtDepthAtPlatterSpeed() {
    let clock = RecordingClock()
    let a = JogAdapter(profile: profile, clock: clock)
    // Feed ticks at platter speed (ticksPerRev * rpm/60 per second) for 2 s.
    let rate = Double(profile.ticksPerRev) * profile.platterRpm / 60
    var t = 0.0
    a.decay(now: t)
    while t < 2 {
      t += 1 / rate
      a.handle(.bend(deck: "A", shift: false, ticks: 1))
      a.decay(now: t)
    }
    #expect(abs(a.nudge - 0.10) < 0.01)
  }

  @Test func touchClearsNudge() {
    let clock = RecordingClock()
    let a = JogAdapter(profile: profile, clock: clock)
    a.handle(.bend(deck: "A", shift: false, ticks: 10))
    a.handle(.touch(deck: "A", shift: false, down: true))
    #expect(a.nudge == 0)
  }
}
