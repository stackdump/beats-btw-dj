import Testing

@testable import DJCore

// SPEC mode 25: the LED mirror of the device map. Pinned values are device-map.js's `PALETTE`,
// petri-note.css `.pn-dm-track` / `.pn-dm-scene` / `pn-dm-blink`.
struct DeviceLEDsTests {
  func rgb(_ c: ScopeColor) -> [Int] { [c.rgb8.r, c.rgb8.g, c.rgb8.b] }

  @Test func thePaletteIsDeviceMapJsTable() {
    let want: [(UInt8, String, [Int])] = [
      (3, "white", [255, 255, 255]), (5, "red", [255, 45, 45]), (9, "orange", [255, 140, 0]),
      (13, "yellow", [255, 212, 0]), (21, "green", [25, 195, 77]), (37, "cyan", [30, 200, 255]),
      (45, "blue", [58, 92, 255]), (53, "magenta", [214, 58, 214]),
    ]
    #expect(APCPalette.entries.count == want.count)
    for (i, name, c) in want {
      #expect(rgb(APCPalette.pinned(i)!) == c, "\(i) \(name)")
      #expect(rgb(APCPalette.color(i)) == c)
      #expect(APCPalette.entries.first { $0.index == i }?.name == name)
    }
    #expect(APCPalette.pinned(0) == nil, "0 is `transparent`: off")
    #expect(rgb(APCPalette.color(0)) == [0, 0, 0])
    // an index beats does not draw still shows a colour (a hue picked from the index)
    #expect(APCPalette.pinned(17) == nil)
    #expect(APCPalette.color(17) == SectionTimeline.hsb(17.0 / 64, 0.8, 0.9))
    #expect(APCPalette.color(17 + 64) == APCPalette.color(17), "wraps at 64")
  }

  @Test func theSingleLEDColoursAreTheDeviceMapsCss() {
    #expect(rgb(APCPalette.trackOn) == [255, 45, 45] && rgb(APCPalette.trackOff) == [26, 10, 10])
    #expect(rgb(APCPalette.sceneOn) == [25, 195, 77] && rgb(APCPalette.sceneOff) == [10, 26, 10])
    #expect(APCPalette.offOpacity == 0.4)
  }

  @Test func blinkIsSixHundredMillisecondsHalfOnHalfDim() {
    #expect(DeviceLEDs.blinkPeriod == 0.6)
    func o(_ t: Double) -> Double { DeviceLEDs.blinkOpacity(at: t) }
    #expect(o(0) == 1 && o(0.2) == 1 && o(0.29) == 1, "0%...49%")
    #expect(o(0.3) == 0.3 && o(0.45) == 0.3 && o(0.59) == 0.3, "50%...100%")
    #expect(o(0.6) == 1 && o(0.95) == 0.3 && o(1.3) == 1 && o(6.1) == 1 && o(6.4) == 0.3)
    #expect(o(-0.1) == 0.3, "a negative clock wraps the same way")
  }

  @Test func rgbPadsTakeTheirPaletteColourAndBrightness() {
    let full = DeviceLEDs.swatch(PadLight(colorIndex: 9, level: .full), group: "pads", rgb: true)
    #expect(rgb(full.color) == [255, 140, 0] && full.opacity == 1 && full.lit && !full.blinks)
    let dim = DeviceLEDs.swatch(PadLight(colorIndex: 9, level: .dim), group: "pads", rgb: true)
    #expect(
      rgb(dim.color) == [255, 140, 0] && dim.opacity == 0.5 && dim.lit, "PAD_DIM is solid 50%")
    // an unbound pad (index 0), or an LED that is off, is dark
    for l in [PadLight(colorIndex: 0, level: .dim), PadLight(colorIndex: 9, level: .off)] {
      let off = DeviceLEDs.swatch(l, group: "pads", rgb: true)
      #expect(!off.lit && off.opacity == 0 && !off.blinks)
    }
  }

  @Test func singleLEDsAreRedOnTheTrackRowAndGreenOnTheSceneColumn() {
    func s(_ level: PadLight.Level, _ group: String) -> LEDSwatch {
      DeviceLEDs.swatch(PadLight(colorIndex: 0, level: level), group: group, rgb: false)
    }
    #expect(rgb(s(.full, "track").color) == [255, 45, 45] && s(.full, "track").opacity == 1)
    #expect(rgb(s(.full, "scene").color) == [25, 195, 77])
    let off = s(.off, "track")
    #expect(rgb(off.color) == [26, 10, 10] && off.opacity == 0.4 && !off.lit, ".pn-dm-off")
    #expect(s(.dim, "scene").opacity == 0.4 && s(.dim, "scene").lit)
    let blink = s(.blink, "scene")
    #expect(
      blink.blinks && blink.lit && blink.opacity(at: 0) == 1 && blink.opacity(at: 0.35) == 0.3)
    #expect(s(.full, "track").opacity(at: 0.35) == 1, "a steady LED ignores the clock")
    // any other single-LED group (the Inpulse's buttons) is white: its colour is not in the profile
    #expect(rgb(s(.full, "deckA.buttons").color) == [255, 255, 255])
  }

  @Test func deviceLightsLooksUpOneControl() {
    let lights = DeviceLights(
      groups: [
        "pads": [PadLight(colorIndex: 5, level: .full)],
        "scene": [PadLight(colorIndex: 0, level: .blink), PadLight(colorIndex: 0, level: .off)],
      ], rgbGroups: ["pads"])
    #expect(lights.swatch(group: "pads", index: 0).map { rgb($0.color) } == [255, 45, 45])
    #expect(lights.swatch(group: "scene", index: 0)?.blinks == true)
    #expect(lights.swatch(group: "scene", index: 1)?.lit == false)
    #expect(lights.swatch(group: "pads", index: 1) == nil, "past the group")
    #expect(lights.swatch(group: "faders", index: 0) == nil, "a group with no LEDs")
    #expect(lights.anyBlinking && !lights.isEmpty)
    #expect(!DeviceLights(groups: [:], rgbGroups: []).anyBlinking)
  }
}

/// Against the real controller: what the router reports is what the map will draw.
@MainActor
struct DeviceLightsFromTheRouterTests {
  func make() async throws -> (DJEngine, ControllerRouter) {
    let dj = try DJEngine(offline: true, sampleRate: 22_050)
    dj["B"]!.loadDemo()
    await dj["A"]!.generate(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    let router = ControllerRouter(engine: dj)
    router.attach(port: "APC mini mk2 Control")
    return (dj, router)
  }

  @Test func theAPCsLightsCarryItsRGBGroupAndEveryLED() async throws {
    let (dj, router) = try await make()
    let l = try #require(router.deviceLights(profileName: "APC mini mk2"))
    #expect(l.rgbGroups == ["pads"])
    #expect(l.groups["pads"]?.count == 64 && l.groups["track"]?.count == 8)
    // the macro grid, aimed at deck A (a net): drop and sweep-lp lit dim in their group colours
    let drop = try #require(l.swatch(group: "pads", index: 0))
    let sweep = try #require(l.swatch(group: "pads", index: 8))
    #expect(drop.lit && drop.opacity == 0.5 && sweep.lit)
    #expect(drop.color != sweep.color, "Mute red vs FX cyan")
    // a beats macro dj doesn't have: dark
    #expect(l.swatch(group: "pads", index: 11)?.lit == false)
    // the aimed deck's play button blinks while it plays, and the map is told
    #expect(!l.anyBlinking)
    dj["A"]!.setPlaying(true)
    let playing = try #require(router.deviceLights(profileName: "APC mini mk2"))
    #expect(playing.anyBlinking, "the play LED blinks while the aimed deck plays")
  }

  @Test func aControllerThatIsNotAttachedHasNoLights() async throws {
    let (_, router) = try await make()
    #expect(router.deviceLights(profileName: "MPK Mini mk2") == nil, "not attached")
    #expect(router.deviceLights(profileName: "no such device") == nil)
    let inpulse = SurfaceProfile.all.first { $0.name.contains("Inpulse") }
    if let inpulse {
      #expect(
        router.deviceLights(profileName: inpulse.name) == nil, "profile has LEDs, not attached")
    }
  }
}
