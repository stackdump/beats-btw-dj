import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct StageAppModelTests {
  func model() throws -> (AppModel, DJEngine) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, structure: "standard"), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    return (AppModel(engine: dj), dj)
  }

  @Test func theAppOwnsTheStageModelOverTheScopeHub() throws {
    let (m, dj) = try model()
    #expect(m.stageModel == nil, "it appears with the engine, at start()")
    m.start()
    let stage = try #require(m.stageModel)
    #expect(stage.hub === m.scopeHub && stage.hub.engine === dj)
    #expect(
      !stage.isAttached && stage.hub.activeFeeds.isEmpty, "nothing is tapped until the window is up"
    )
    #expect(!dj.masterTap.isEnabled && !dj["A"]!.tap.isEnabled)
    m.start()  // a second start keeps it
    #expect(m.stageModel === stage)
  }

  @Test func theWindowContentWaitsForTheEngineThenShowsTheStage() throws {
    let (m, dj) = try model()
    let window = StageWindowView(app: m)
    let before = try #require(renderPixels(window, width: 700, height: 500))
    let waiting = before.count(inX: 0..<700, y: 0..<500) { r, g, b in r > 80 && g > 80 }
    #expect(waiting > 100, "the placeholder text is drawn (\(waiting))")
    m.start()
    let stage = try #require(m.stageModel)
    dj["A"]!.setPlaying(true)
    try dj.start()
    stage.attach()
    defer { stage.detach() }
    try renderOffline(dj, frames: 22_050)
    let after = try #require(renderPixels(window, width: 700, height: 500))
    let drawn = after.count(inX: 0..<700, y: 0..<500) { r, g, b in
      abs(r - 10) + abs(g - 10) + abs(b - 26) > 24
    }
    #expect(drawn > 8_000, "the stage is drawn (\(drawn))")
    #expect(stage.context.panels.count == 6, "deck A's nets are panels")
    dj.stop()
  }

  @Test func theStageWindowOpensOnlyOnceTheEngineExists() throws {
    // The "Stage" button next to "Scopes" opens `Window(StageWindow.title, id: StageWindow.id)` and
    // is disabled until `StageWindow.canOpen`: the model appears with the audio engine.
    let (m, _) = try model()
    #expect(!StageWindow.canOpen(m))
    m.start()
    #expect(StageWindow.canOpen(m))
    #expect(StageWindow.id == "stage" && StageWindow.title == "Stage")
  }

  @Test func theContentViewStillRendersWithTheStageButtonInIt() throws {
    let (m, _) = try model()
    m.start()
    m.poll()
    // (Offscreen, SwiftUI draws every button as a placeholder, so this cannot find the Stage
    // button: its wiring is `StageWindow`, above. It checks that the toolbar row it joined lays
    // out and draws.)
    let px = try #require(renderPixels(ContentView(model: m), width: 1100, height: 700))
    let ink = px.count(inX: 0..<1100, y: 0..<120) { r, g, b in r + g + b > 300 }
    #expect(ink > 500, "the top bar is drawn (\(ink) light pixels)")
    savePNG(ContentView(model: m), width: 1100, height: 700, name: "app-stage-button")
  }
}
