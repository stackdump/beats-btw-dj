import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 28 in the app: the master meter in the Mixer column.

@MainActor
struct MasterFlameMixerTests {
  /// An offline engine: deck A a net at 300 BPM, deck B the demo loop.
  func engine(play: Bool) throws -> DJEngine {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    if play { dj["A"]!.setPlaying(true) }
    try dj.start()
    return dj
  }

  @Test func theMixerShowsTheMasterMeterOnceTheEngineExists() throws {
    let dj = try engine(play: false)
    defer { dj.stop() }
    let m = AppModel(engine: dj)
    /// The meter's dark box in a Mixer render, and how many columns of its middle row are the
    /// idle line's colour (the box's own ring is the same colour, so only the middle counts).
    func box<V: View>(_ view: V) throws -> (rows: Int, lineColumns: Int) {
      let px = try #require(
        renderPixels(
          ZStack {
            Color(white: 0.6)
            view
          }.environment(\.displayScale, 1), width: 160, height: 300))
      let dark = (0..<px.height).filter { y in
        let c = px.color(80, y)
        return c.r + c.g + c.b < 140
      }
      guard let first = dark.first, let last = dark.last else { return (0, 0) }
      let mid = (first + last) / 2
      let columns = (4..<156).filter {
        px.near($0, mid, (26, 42, 58), tol: 8) || px.near($0, mid + 1, (26, 42, 58), tol: 8)
      }
      return (dark.count, columns.count)
    }
    let before = try box(MixerView(model: m))
    m.start()
    let after = try box(MixerView(model: m))
    #expect(before.rows < 10, "no hub, no meter (\(before.rows))")
    #expect(after.rows >= 36 && after.rows <= 42, "a 38 pt box appeared (\(after.rows))")
    #expect(after.lineColumns > 140, "idle: its flat line across the box (\(after.lineColumns))")
    savePNG(
      ZStack {
        Color(white: 0.6)
        MixerView(model: m)
      }, width: 160, height: 300, name: "mixer-idle")
  }

  @Test func theMixerMeterLeavesTheIdleLineWhenADeckPlays() throws {
    let dj = try engine(play: true)
    defer { dj.stop() }
    let m = AppModel(engine: dj)
    m.start()
    let hub = try #require(m.scopeHub)
    let feed = hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    for _ in 0..<4 {
      try renderOffline(dj, frames: 11_025)
      hub.pump()
    }
    m.poll()
    #expect(m.decks["A"]?.playing == true)
    let view = ZStack {
      Color(white: 0.6)
      MixerView(model: m)
    }.environment(\.displayScale, 1)
    savePNG(view, width: 160, height: 300, name: "mixer-playing")
    let px = try #require(renderPixels(view, width: 160, height: 300))
    // the idle line is gone from the middle of the box: bars, not a flat line
    let dark = (0..<px.height).filter { y in
      let c = px.color(80, y)
      return c.r + c.g + c.b < 140
    }
    let mid = ((dark.first ?? 0) + (dark.last ?? 0)) / 2
    let flat = (4..<156).filter { px.near($0, mid, (26, 42, 58), tol: 8) }.count
    #expect(dark.count >= 36 && flat < 20, "box rows \(dark.count), \(flat) flat columns")
    // and a bar is lit somewhere in the box (hue 200 ... 40: blue-green to amber)
    let colourful = px.count(inX: 2..<158, y: 0..<300) { r, g, b in
      max(r, g, b) - min(r, g, b) > 60 && g > 60 && r < 255
    }
    #expect(colourful > 20, "\(colourful) coloured pixels")
  }
}
