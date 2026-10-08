import Testing

@testable import DJCore

private func rms(_ x: ArraySlice<Float>) -> Float {
  guard !x.isEmpty else { return 0 }
  return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

struct CueOutputTests {
  /// Two decks, a 4-channel offline engine routed master → 1/2, cue → 3/4.
  func make() async throws -> DJEngine {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050, outputChannels: 4)
    try await dj.enableCueRouting()
    for d in dj.decks.values { d.loadDemo() }
    return dj
  }

  @Test func masterOnOneTwoAndCueOnThreeFour() async throws {
    let dj = try await make()
    let a = try #require(dj["A"])
    a.volume = 0  // channel fader down: nothing reaches the master from A
    a.pfl = true  // but A is cued
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let c = try renderChannels(dj, frames: 22_050)
    #expect(c.count == 4)
    let tail = 4000..<22_050
    #expect(rms(c[0][tail]) < 1e-4 && rms(c[1][tail]) < 1e-4, "master is silent: fader is down")
    #expect(rms(c[2][tail]) > 0.01 && rms(c[3][tail]) > 0.01, "the cue pair carries A pre-fader")
  }

  @Test func theMasterMixIsOnTheFirstPairOnly() async throws {
    let dj = try await make()
    let a = try #require(dj["A"])
    a.setPlaying(true)  // no PFL anywhere
    try dj.start()
    defer { dj.stop() }
    let c = try renderChannels(dj, frames: 22_050)
    let tail = 4000..<22_050
    #expect(rms(c[0][tail]) > 0.01 && rms(c[1][tail]) > 0.01)
    #expect(
      rms(c[2][tail]) < 1e-5 && rms(c[3][tail]) < 1e-5, "nothing cued, headphone mix = cue only")
  }

  @Test func theHeadphoneMixBlendsInTheMaster() async throws {
    let dj = try await make()
    let a = try #require(dj["A"])
    a.setPlaying(true)
    dj.headphoneMix = 1  // all master
    try dj.start()
    defer { dj.stop() }
    let c = try renderChannels(dj, frames: 22_050)
    let tail = 4000..<22_050
    #expect(rms(c[2][tail]) > 0.01, "the master reaches the headphones")
    // same signal, scaled by the headphone level
    let ratio = rms(c[2][tail]) / rms(c[0][tail])
    #expect(abs(ratio - Float(dj.headphoneLevel)) < 0.02, "ratio \(ratio)")
  }

  @Test func cueIsPreFaderAndFollowsTheDecksEQ() async throws {
    let dj = try await make()
    let a = try #require(dj["A"])
    a.pfl = true
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let loud = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    a.volume = 0.1
    dj.crossfader = 1  // deck A also faded out by the crossfader
    let still = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    #expect(abs(still - loud) / loud < 0.35, "the channel fader and crossfader don't touch the cue")
    a.eqLow = 0  // kill the lows: the cue hears it
    a.eqMid = 0
    a.eqHigh = 0
    let killed = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    #expect(killed < still * 0.5, "post-EQ")
  }

  @Test func levelAndPFLToggleLive() async throws {
    let dj = try await make()
    let a = try #require(dj["A"])
    a.setPlaying(true)
    a.pfl = true
    try dj.start()
    defer { dj.stop() }
    let on = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    dj.headphoneLevel = 0.35
    let half = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    #expect(abs(half / on - 0.5) < 0.1)
    a.pfl = false
    let off = rms(try renderChannels(dj, frames: 22_050)[2][4000...])
    #expect(off < on * 0.02)
  }

  @Test func theStereoPathIsUntouchedWithoutRouting() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    a.loadDemo()
    a.pfl = true
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let c = try renderChannels(dj, frames: 22_050)
    #expect(c.count == 2 && rms(c[0][4000...]) > 0.01)
  }

  @Test func theAudioDeviceListIsReadable() {
    let outs = AudioDevices.outputs()
    for d in outs { #expect(d.outputChannels > 0 && !d.name.isEmpty) }
    // never claims an Inpulse that is not there
    if let i = AudioDevices.inpulse() { #expect(i.name.lowercased().contains("inpulse")) }
  }

  @Test func aDeviceWithTooFewChannelsIsRefused() async throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let stereoOnly = AudioOutputDevice(id: 0, uid: "x", name: "Speakers", outputChannels: 2)
    await #expect(throws: CueOutputError.notEnoughChannels(device: "Speakers", has: 2)) {
      try await dj.enableCueOutput(device: stereoOnly)
    }
  }
}

struct CueControlTests {
  @Test func inpulseButtonsAndFaderDriveTheCue() throws {
    let dj = try DJEngine(offline: true)
    let s = SurfaceController(profile: .inpulse200MK3, engine: dj)
    let prof = SurfaceProfile.inpulse200MK3
    let pflB = prof.number(group: "deckB.buttons", index: 7)!
    #expect(!dj["B"]!.pfl)
    s.handle(bytes: [0x92, pflB, 0x7F])
    #expect(dj["B"]!.pfl && !dj["A"]!.pfl)
    #expect(s.ledFrame().contains([0x92, pflB, prof.leds!.singleOn]))
    s.handle(bytes: [0x92, pflB, 0x7F])
    #expect(!dj["B"]!.pfl)
    // mixer fader 2 = headphone level (cc14 on channel 0: CC 4 MSB, CC 36 LSB)
    s.handle(bytes: [0xB0, 0x04, 0x7F])
    s.handle(bytes: [0xB0, 0x24, 0x7F])
    #expect(dj.headphoneLevel > 0.99)
    s.handle(bytes: [0xB0, 0x04, 0x20])
    s.handle(bytes: [0xB0, 0x24, 0x00])
    #expect(abs(dj.headphoneLevel - 0.25) < 0.01)
  }

  @Test func apcFaderFiveIsTheHeadphoneMix() throws {
    let dj = try DJEngine(offline: true)
    let s = SurfaceController(profile: .apcMiniMK2, engine: dj)
    #expect(dj.headphoneMix == 0)
    s.handle(bytes: [0xB0, 52, 0x7F])
    #expect(dj.headphoneMix == 1)
  }
}
