import Testing

@testable import DJCore

@MainActor
struct PadLightsTests {
  func make() async throws -> (DJEngine, ControllerRouter, SurfaceController, String) {
    let dj = try DJEngine(offline: true, sampleRate: 22_050)
    dj["B"]!.loadDemo()
    await dj["A"]!.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let router = ControllerRouter(engine: dj)
    let port = "APC mini mk2 Control"
    router.attach(port: port)
    return (dj, router, router.surfaces[port]!, port)
  }

  @Test func theMirrorSaysWhatTheLEDsSay() async throws {
    let (_, router, s, _) = try await make()
    let lights = s.lights(now: 1_000)
    #expect(
      lights["pads"]?.count == 64 && lights["track"]?.count == 8 && lights["scene"]?.count == 8)
    // deck A's section pads (16…31) are lit orange; the current section is full, the rest dim
    let secs = router.dj["A"]!.sections.count
    #expect(secs >= 5)
    let pads = lights["pads"]!
    #expect(pads[16] == PadLight(colorIndex: 9, level: .full), "section 0 is current")
    #expect(pads[17] == PadLight(colorIndex: 9, level: .dim))
    #expect(pads[16 + secs] == PadLight(colorIndex: 0, level: .dim), "past the song's end: dark")
    // deck B (sample) has no sections: its launcher rows are dark
    #expect(pads[32].colorIndex == 0)
    // and it agrees with what ledFrame would send for the same state
    let frame = s.ledFrame(now: 1_000)
    #expect(frame.contains([0x96, 16, 9]) && frame.contains([0x92, 17, 9]))
  }

  @Test func singleLEDsReportOnOffBlink() async throws {
    let (dj, _, s, _) = try await make()
    #expect(s.lights()["track"]![0].level == .full, "play button is lit")
    dj["A"]!.setPlaying(true)
    #expect(s.lights()["track"]![0].level == .blink, "a playing deck's button blinks")
    #expect(s.lights()["track"]![1].level == .full, "kick role is on")
    dj["A"]!.setRole("kick", on: false)
    // (the mirror of a role lives on the mute mirror: nothing rendered yet, so it still shows on)
    #expect(s.lights()["scene"] != nil)
  }

  @Test func pressingOnScreenIsPressingTheHardware() async throws {
    let (dj, router, _, port) = try await make()
    #expect(router.press(port: port, group: "scene", index: 1))  // deck B play
    #expect(dj["B"]!.playing)
    #expect(router.press(port: port, group: "pads", index: 4))  // deck B hot cue 0
    #expect(dj["B"]!.hotCues[0] != nil)
    #expect(!router.press(port: port, group: "pads", index: 99))
    #expect(
      !router.press(port: port, group: "faders", index: 0), "continuous controls aren't clickable")
    #expect(!router.press(port: "nope", group: "pads", index: 0))
  }

  @Test func onScreenPressesAreRecordedLikeHardware() async throws {
    let dj = try DJEngine(offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    let router = ControllerRouter(engine: dj)
    let port = "APC mini mk2 Control"
    router.attach(port: port)
    let rec = try SessionRecorder.start(on: dj)
    router.press(port: port, group: "scene", index: 0)  // deck A play
    let s = rec.finish()
    #expect(
      s.events.map(\.kind) == [
        .midi(port: port, bytes: [0x90, 112, 127]), .midi(port: port, bytes: [0x80, 112, 0]),
      ])
  }

  @Test func routerFindsASurfaceByProfileName() async throws {
    let (_, router, _, port) = try await make()
    let found = try #require(router.lights(profileName: "APC mini mk2"))
    #expect(found.port == port && found.groups["pads"]?.count == 64)
    #expect(router.lights(profileName: "MPK Mini mk2") == nil)
  }
}
