import AppKit
import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 25 on screen: the device map's rows carry a dot per LED, live.
@MainActor
struct DeviceLEDMirrorRenderTests {
  func row(_ group: String, _ i: Int, _ name: String) -> DeviceMapRow {
    DeviceMapRow(
      group: group, index: i, control: name, number: i, action: "x", shiftedAction: nil,
      parked: false)
  }

  /// pads: full orange, dim orange, off; scene: blinking, steady.
  var lights: DeviceLights {
    DeviceLights(
      groups: [
        "pads": [
          PadLight(colorIndex: 9, level: .full), PadLight(colorIndex: 9, level: .dim),
          PadLight(colorIndex: 0, level: .dim),
        ],
        "scene": [PadLight(colorIndex: 0, level: .blink), PadLight(colorIndex: 0, level: .full)],
      ], rgbGroups: ["pads"])
  }

  var rows: [DeviceMapRow] {
    [row("pads", 0, "pad 1"), row("pads", 1, "pad 2"), row("pads", 2, "pad 3")]
      + [row("scene", 0, "scene 1"), row("scene", 1, "scene 2")]
  }

  /// Colours of the LED dots in the dot column, top to bottom: a run of pixels with alpha.
  func dots(_ px: Pixels, x: Int = 40) -> [(r: Int, g: Int, b: Int, a: Int)] {
    var out: [(r: Int, g: Int, b: Int, a: Int)] = []
    var run: [Int] = []
    func close() {
      if let mid = run.sorted().dropFirst(run.count / 2).first { out.append(px.color(x, mid)) }
      run = []
    }
    for y in 0..<px.height {
      if px.color(x, y).a >= 50 { run.append(y) } else if !run.isEmpty { close() }
    }
    if !run.isEmpty { close() }
    return out
  }

  func render(_ time: Double, lights: DeviceLights?) throws -> Pixels {
    try #require(
      renderPixels(
        DeviceMapList(title: "APC", rows: rows, lights: lights, blinkTime: time), width: 300,
        height: 150))
  }

  @Test func everyLitLEDGetsADotInItsColourAndBrightness() throws {
    let px = try render(0, lights: lights)
    let d = dots(px)
    // four lit dots: full orange, dim orange, the blinking scene LED (full at t = 0), a steady one
    #expect(d.count == 4, "\(d)")
    guard d.count == 4 else { return }
    #expect(d[0].r > 240 && d[0].g > 120 && d[0].g < 160 && d[0].b < 30, "full orange \(d[0])")
    #expect(
      d[1].a > 115 && d[1].a < 140 && d[1].r > 115 && d[1].r < 140, "dim orange (50 %) \(d[1])")
    #expect(d[2].g > 170 && d[2].r < 60, "scene green \(d[2])")
    #expect(d[3].g > 170 && d[3].r < 60, "steady scene green \(d[3])")
    savePNG(
      DeviceMapList(title: "APC", rows: rows, lights: lights, blinkTime: 0), width: 300,
      height: 150,
      name: "device-leds")
  }

  @Test func aBlinkingLEDFollowsTheClockAndASteadyOneDoesNot() throws {
    let on = dots(try render(0.1, lights: lights))
    let off = dots(try render(0.35, lights: lights))
    #expect(on.count == 4 && off.count == 4)
    guard on.count == 4, off.count == 4 else { return }
    #expect(off[2].g < on[2].g / 2, "pn-dm-blink: 0.3 in its second half: \(on[2]) -> \(off[2])")
    #expect(off[3].g == on[3].g, "a steady LED ignores the clock")
    #expect(off[0].r == on[0].r)
    // and the period is 600 ms: a whole period later it is full again
    #expect(dots(try render(0.1 + 0.6, lights: lights))[2].g == on[2].g)
  }

  @Test func withoutLightsTheListIsAsItWas() throws {
    let plain = try render(0, lights: nil)
    func coloured(_ p: Pixels) -> Int {
      p.count(inX: 0..<p.width, y: 0..<p.height) { r, g, b in max(r, g, b) - min(r, g, b) > 40 }
    }
    #expect(coloured(plain) == 0, "text is grey: no coloured dot anywhere")
    #expect(coloured(try render(0, lights: lights)) > 100, "and with lights there are")
    // and the text starts further left than with the dots
    let withLights = try render(0, lights: lights)
    func firstTextColumn(_ p: Pixels) -> Int {
      for x in 0..<p.width
      where p.count(
        inX: x..<(x + 1), y: 30..<150, where: { r, g, b in r > 150 && g > 150 && b > 150 }) > 0
      {
        return x
      }
      return p.width
    }
    #expect(firstTextColumn(withLights) > firstTextColumn(plain), "the dots take 16 pt")
  }

  @Test func offLEDsAreDarkNotMissing() throws {
    // the third pad row is off: no lit colour at its dot, but the row is there
    let px = try render(0, lights: lights)
    #expect(dots(px).count == 4, "the off pad adds no lit dot")
  }
}

@MainActor
struct DeviceLEDMirrorModelTests {
  @Test func theAppModelMirrorsEveryAttachedControllersLEDs() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    let m = AppModel(engine: dj)
    m.start()
    #expect(m.deviceLights.isEmpty, "nothing attached")
    m.setShowPads(true)  // a virtual APC mini mk2 attaches
    m.poll()
    let apc = try #require(m.deviceLights["APC mini mk2"])
    #expect(apc.rgbGroups == ["pads"] && apc.groups["pads"]?.count == 64)
    #expect(!apc.anyBlinking)
    dj["A"]!.setPlaying(true)
    m.poll()
    #expect(m.deviceLights["APC mini mk2"]?.anyBlinking == true, "a playing deck blinks its LED")
    // the pad mirror the grid view uses is the same state
    #expect(m.padLights["pads"] == apc.groups["pads"])
  }

  @Test func thePaletteTheGridUsesIsDeviceMapJsTable() {
    func near(_ i: UInt8, _ r: Int, _ g: Int, _ b: Int) -> Bool {
      let c = AkaiPalette.rgb(i)
      return abs(c.r * 255 - Double(r)) < 0.51 && abs(c.g * 255 - Double(g)) < 0.51
        && abs(c.b * 255 - Double(b)) < 0.51
    }
    #expect(near(3, 255, 255, 255) && near(5, 255, 45, 45) && near(9, 255, 140, 0))
    #expect(near(13, 255, 212, 0) && near(21, 25, 195, 77) && near(37, 30, 200, 255))
    #expect(near(45, 58, 92, 255) && near(53, 214, 58, 214) && near(0, 0, 0, 0))
    // an index beats does not draw keeps the hue guess it always had
    let old = NSColor(Color(hue: 17.0 / 64, saturation: 0.8, brightness: 0.9))
      .usingColorSpace(.deviceRGB)!
    let now = AkaiPalette.rgb(17)
    #expect(abs(now.r - Double(old.redComponent)) < 0.01)
    #expect(abs(now.g - Double(old.greenComponent)) < 0.01)
    #expect(abs(now.b - Double(old.blueComponent)) < 0.01)
  }
}
