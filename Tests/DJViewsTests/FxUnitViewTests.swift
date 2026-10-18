import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The FX unit panel (FxUnitViews.swift): its moves are the `fx` pokes (a drag coalesced to 30 Hz),
/// it follows the focus until aimed, it draws in the target's tint with the values' arcs, and
/// dj_state reports every target.
@MainActor
struct FxUnitViewTests {
  func model(netB: Bool = false) throws -> (AppModel, DJEngine) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    if netB {
      dj["B"]!.loadNet(
        PreparedTrack(
          spec: TrackSpec(genre: "trance", seed: 7, structure: "standard"), sampleRate: 22_050))
    } else {
      dj["B"]!.loadDemo()
    }
    try dj.start()
    let m = AppModel(
      engine: dj, favorites: temporaryFavorites(), loops: try temporaryLoopLibrary(),
      voices: temporaryVoiceVariations(), notes: temporaryNotes())
    m.defaults = scratchDefaults()
    m.start()
    m.poll()
    return (m, dj)
  }

  @Test func movesArePokesAndADragIsCoalesced() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let rec = try SessionRecorder.start(on: dj)
    var t = 100.0
    m.uptime = { t }
    // a 1 s drag at 120 mouse events a second
    for i in 0...120 {
      m.fxMove("A", .filter, -Double(i) / 120, ended: i == 120)
      t += 1.0 / 120
      if i % 4 == 0 { m.poll() }  // the app polls at 30 Hz
    }
    #expect(dj["A"]!.fxUnit[.filter] == -1, "the last value landed")
    let moves = rec.finish().events.filter {
      if case .action(.fx(deck: "A", param: "filter", _)) = $0.kind { return true }
      return false
    }
    #expect(moves.count <= 32 && moves.count >= 20, "\(moves.count) actions for a 1 s drag")
    #expect(m.fxUnits["A"]?.settings[.filter] == -1)
    #expect(m.fxUnits["A"]?.settings.isActive == true)
    // follows the focus until aimed
    #expect(m.fxTargetName == "A")
    dj.perform(.focus(deck: "L"))
    m.poll()
    #expect(m.fxTargetName == "L")
    m.setFxTarget("B")
    dj.perform(.focus(deck: "A"))
    m.poll()
    #expect(m.fxTargetName == "B")
    // kill and reset, on the beat
    m.fxOnBeat = true
    m.fxKill("A", true)
    #expect(dj["A"]!.fxUnit.killed)
    m.fxReset("A")
    #expect(dj["A"]!.fxUnit.isNeutral && !dj["A"]!.fxUnit.killed)
  }

  @Test func dj_stateReportsEveryTarget() async throws {
    let (m, dj) = try model(netB: true)
    defer { dj.stop() }
    _ = try await m.control(
      "perform", try JSONValue.parse(#"{"action":{"op":"fx","deck":"B","param":"room","value":0.5}}"#))
    _ = try await m.control(
      "perform", try JSONValue.parse(#"{"action":{"op":"fx","deck":"L","param":"pitch","value":-3}}"#))
    let s = try await m.control("state", .object(JSONObject()))
    let fx = try #require(s["fxUnit"])
    #expect(fx["B"]?["values"]?["room"]?.double == 0.5)
    #expect(fx["B"]?["active"]?.bool == true)
    #expect(fx["B"]?["controls"]?.array?.contains(.string("echo")) == true, "trance has an echo")
    #expect(fx["L"]?["values"]?["pitch"]?.double == -3)
    #expect(fx["L"]?["missing"]?["room"]?.string != nil)
    #expect(fx["A"]?["moved"]?.array?.isEmpty == true)
    for (params, words) in [
      (#"{"action":{"op":"fx","deck":"A","param":"wobble","value":0.5}}"#, "unknown FX unit param"),
      (#"{"action":{"op":"fx","deck":"A","param":"hp","value":1.5}}"#, "0…1"),
      (#"{"action":{"op":"fx","deck":"A","param":"room","value":0.5}}"#, "sample deck"),
      (#"{"action":{"op":"fx","deck":"L","param":"echo","value":0.5}}"#, "loops"),
    ] {
      await #expect {
        try await m.control("perform", try JSONValue.parse(params))
      } throws: { "\($0)".contains(words) }
    }
  }

  /// The panel draws in its target's tint: the knobs' arcs for the values moved (more of them for
  /// more), the pad's frame; another target, another tint.
  @Test func thePanelDrawsTheTargetsTintAndItsValues() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    m.setFxTarget("A")
    func render() throws -> Pixels {
      m.poll()
      let v = FxUnitPanel(model: m).padding(12).background(Color.black)
        .environment(\.colorScheme, .dark)
      return try #require(renderPixels(v, width: 1240, height: 300))
    }
    func count(_ px: Pixels, _ c: Color) -> Int {
      let rgb = NSColorRGB(c)
      return px.count(inX: 0..<px.width, y: 0..<px.height) { r, g, b in
        abs(r - rgb.0) < 30 && abs(g - rgb.1) < 30 && abs(b - rgb.2) < 30
      }
    }
    let rest = try render()
    m.fxSet("A", .drive, 0.2)
    let some = try render()
    m.fxSet("A", .drive, 1)
    m.fxSet("A", .filter, -0.8)
    let more = try render()
    let a0 = count(rest, DJStyle.deckA)
    let a1 = count(some, DJStyle.deckA)
    let a2 = count(more, DJStyle.deckA)
    #expect(a1 > a0 + 20, "a drive arc: \(a0) → \(a1)")
    #expect(a2 > a1 + 200, "a full drive arc and the big filter's: \(a1) → \(a2)")
    #expect(count(more, DJStyle.deckB) < 20, "nothing of B's tint while aimed at A")
    m.setFxTarget("B")
    let neutralB = try render()
    #expect(count(neutralB, DJStyle.deckA) < a0 + 20, "A's arcs gone from the panel aimed at B")
    m.fxSet("B", .drive, 0.8)
    let b = try render()
    #expect(count(b, DJStyle.deckB) > count(neutralB, DJStyle.deckB) + 50, "B's arc in B's tint")
    #expect(count(b, DJStyle.deckA) < a0 + 20, "A's arcs gone from the panel aimed at B")
  }
}

/// For a human: `make swift-shots SHOT_DIR=… FILTER=FxUnitShots`.
@MainActor
struct FxUnitShots {
  @Test func theFxUnitPanel() throws {
    let t = FxUnitViewTests()
    let (m, dj) = try t.model(netB: true)
    defer { dj.stop() }
    m.fxSet("B", .filter, -0.45)
    m.fxSet("B", .crush, 0.55)
    m.fxSet("B", .room, 0.6)
    m.fxSet("B", .pitch, 3)
    m.fxSet("B", .phaserMix, 0.4)
    m.fire("B", .riser)
    m.setFxTarget("B")
    m.poll()
    for (name, width) in [("fx-unit-b-net", 1240), ("fx-unit-b-narrow", 900)] {
      _ = saveWindowPNG(
        FxUnitPanel(model: m).djCard(tint: m.fxTint).padding(12)
          .frame(width: CGFloat(width), alignment: .topLeading).background(Color(white: 0.1)),
        width: width, height: 330, name: name)
    }
    m.fxSet("L", .hp, 0.35)
    m.fxKill("L", true)
    m.setFxTarget("L")
    m.poll()
    _ = saveWindowPNG(
      FxUnitPanel(model: m).djCard(tint: m.fxTint).padding(12)
        .frame(width: 1240, alignment: .topLeading).background(Color(white: 0.1)),
      width: 1240, height: 330, name: "fx-unit-l-killed")
    m.setFxTarget("A")
    m.fxSet("A", .drive, 0.7)
    m.poll()
    m.setShowFxUnit(true)
    let window = ZStack {
      Color(white: 0.1)
      ContentView(model: m)
    }
    .environment(\.colorScheme, .dark)
    .defaultAppStorage(scratchDefaults())
    _ = saveWindowPNG(window, width: 1500, height: 1100, name: "fx-unit-window")
  }
}
