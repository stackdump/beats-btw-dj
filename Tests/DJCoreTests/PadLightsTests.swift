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
    let (_, _, s, _) = try await make()
    let lights = s.lights(now: 1_000)
    #expect(
      lights["pads"]?.count == 64 && lights["track"]?.count == 8 && lights["scene"]?.count == 8)
    // the macro grid in beats' group colours, aimed at deck A (a net)
    let pads = lights["pads"]!
    #expect(pads[0] == PadLight(colorIndex: 5, level: .dim), "drop: red")
    #expect(pads[8] == PadLight(colorIndex: 37, level: .dim), "sweep-lp: cyan")
    #expect(pads[11].colorIndex == 0, "a macro dj doesn't have: dark")
    // and it agrees with what ledFrame would send for the same state
    let frame = s.ledFrame(now: 1_000)
    #expect(frame.contains([0x92, 0, 5]) && frame.contains([0x92, 8, 37]))
  }

  @Test func singleLEDsReportOnOffBlink() async throws {
    let (dj, _, s, _) = try await make()
    #expect(s.lights()["scene"]![0].level == .full, "play button is lit")
    dj["A"]!.setPlaying(true)
    #expect(s.lights()["scene"]![0].level == .blink, "a playing deck's button blinks")
    #expect(s.lights()["track"]![0].level == .full, "kick role is on")
    dj["A"]!.setRole("kick", on: false)
    // (the mirror of a role lives on the mute mirror: nothing rendered yet, so it still shows on)
    #expect(s.lights()["scene"] != nil)
  }

  @Test func pressingOnScreenIsPressingTheHardware() async throws {
    let (dj, router, _, port) = try await make()
    #expect(router.press(port: port, group: "scene", index: 4))  // aim at deck B
    #expect(router.press(port: port, group: "scene", index: 0))  // play: deck B
    #expect(dj["B"]!.playing)
    #expect(router.press(port: port, group: "pads", index: 0))  // drop on B (a sample): nothing
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

  @Test func aShiftedPressHoldsShiftAroundThePadAndIsRecorded() async throws {
    let dj = try DJEngine(offline: true, sampleRate: 22_050)
    let router = ControllerRouter(engine: dj)
    let port = "APC mini mk2 Control"
    router.attach(port: port)
    let rec = try SessionRecorder.start(on: dj)
    #expect(router.press(port: port, group: "pads", index: 56, shift: true))  // loop 1
    let s = rec.finish()
    #expect(
      s.events.map(\.kind) == [
        .midi(port: port, bytes: [0x90, 122, 127]), .midi(port: port, bytes: [0x90, 56, 127]),
        .midi(port: port, bytes: [0x80, 56, 0]), .midi(port: port, bytes: [0x80, 122, 0]),
      ])
    #expect(router.surfaces[port]?.shiftHeld == false, "SHIFT is let go again")
    // a surface without a SHIFT control cannot press shifted
    let mpk = "MPK mini"
    router.attach(port: mpk)
    #expect(router.surfaces[mpk] != nil)
    #expect(!router.press(port: mpk, group: "padNotes", index: 8, shift: true))
    #expect(router.press(port: mpk, group: "padNotes", index: 8))
  }

  @Test func routerFindsASurfaceByProfileName() async throws {
    let (_, router, _, port) = try await make()
    let found = try #require(router.lights(profileName: "APC mini mk2"))
    #expect(found.port == port && found.groups["pads"]?.count == 64)
    #expect(router.lights(profileName: "MPK Mini mk2") == nil)
  }
}
