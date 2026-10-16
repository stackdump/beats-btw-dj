import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct ControllersViewTests {
  @Test func everyDeviceIsDrawnWithItsBindings() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let m = AppModel(engine: dj)
    m.start()
    m.poll()
    for layout in ControllerLayout.all {
      let view = ControllerCard(
        layout: layout, unit: 30, attached: false, lights: nil,
        touched: layout.spots.first?.bindings.first.map { ($0.group, $0.index) }
      )
      .background(Color.black).environment(\.colorScheme, .dark)
      let w = Int(layout.width * 30 + 60)
      let h = Int(layout.height * 30 + 80)
      savePNG(
        view, width: w, height: h, name: "controllers-\(layout.title.split(separator: " ")[0])")
      let px = try #require(renderPixels(view, width: w, height: h))
      let drawn = px.count(inX: 0..<w, y: 0..<h) { r, g, b in r > 40 || g > 40 || b > 40 }
      #expect(drawn > w * h / 20, "\(layout.title) is drawn (\(drawn) lit pixels)")
    }
    // the whole panel lays out from the model
    let panel = ControllersView(model: m).background(Color.black)
    #expect(renderPixels(panel, width: 1400, height: 520) != nil)
  }

  @Test func bindingsReadShort() {
    #expect(SpotView.short("section 3 · deck A") == "A sec 3")
    #expect(SpotView.short("hot cue 2 · deck B") == "B cue 2")
    #expect(SpotView.short("loop 5 in/out · deck B") == "B loop 5")
    #expect(SpotView.short("unbound — not named") == "—")
    #expect(SpotView.short("mute kick · deck A") == "A ✕ kick")
  }
}
