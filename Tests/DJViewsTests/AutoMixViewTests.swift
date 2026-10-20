import SwiftUI
import Testing

@testable import DJCore
@testable import DJViews

/// Auto-mix in the app: the control socket, dj_state, what is remembered, and the panel.
@MainActor
struct AutoMixViewTests {
  func model(_ defaults: UserDefaults = scratchDefaults()) throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites())
    m.defaults = defaults
    m.start()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  @Test func djStateShowsItAndPerformSetsItUp() async throws {
    let defaults = scratchDefaults()
    let m = try model(defaults)
    let off = try await call(m, "state")["autoMix"]
    #expect(off?["on"]?.bool == false && off?["phase"]?.string == "off")
    #expect(off?["bars"]?.int == 8 && off?["every"]?.int == 0)
    let rec = try SessionRecorder.start(on: try #require(m.engine))
    _ = try await call(m, "perform", #"{"action":{"op":"autoMix","on":true,"bars":16,"every":4}}"#)
    let s = try await call(m, "state")["autoMix"]
    #expect(s?["on"]?.bool == true && s?["bars"]?.int == 16 && s?["every"]?.int == 4)
    #expect(s?["phase"]?.string == "idle" && s?["idle"]?.string == "start a deck")
    #expect(s?["log"]?.array?.isEmpty == true && s?["handoffs"]?.int == 0)
    _ = try await call(m, "perform", #"{"action":{"op":"autoMixNow"}}"#)
    #expect(
      rec.finish().events.map(\.kind) == [
        .action(.autoMix(on: true, bars: 16, every: 4)), .action(.autoMixNow),
      ])
    // the length and phrases are remembered, on is not
    #expect(defaults.integer(forKey: AppModel.autoMixBarsKey) == 16)
    #expect(defaults.integer(forKey: AppModel.autoMixEveryKey) == 4)
    let again = try model(defaults)
    let st = again.engine!.autoMix.settings
    #expect(st == AutoMixSettings(on: false, bars: 16, every: 4))
    #expect(again.autoMix.on == false && again.autoMix.bars == 16)
  }

  @Test func badAutoMixRequestsSayWhatIsWrong() async throws {
    let m = try model()
    for (params, words) in [
      (#"{"action":{"op":"autoMix","on":true,"bars":7}}"#, "bars must be one of"),
      (#"{"action":{"op":"autoMix","on":true,"every":3}}"#, "every must be one of"),
      (#"{"action":{"op":"autoMixDefer","handoff":0}}"#, "recorded by the app"),
    ] {
      do {
        _ = try await call(m, "perform", params)
        Issue.record("\(params) was accepted")
      } catch {
        #expect("\(error)".contains(words), "\(error)")
      }
    }
    #expect(m.engine?.autoMix.settings.on == false)
  }

  @Test func thePanelShowsItLit() throws {
    let m = try model()
    let off = try #require(renderPixels(AutoMixPanel(model: m), width: 170, height: 110))
    m.setAutoMix(on: true, bars: 8, every: 0)
    #expect(m.autoMix.on && m.autoMix.status.hasPrefix("waiting"))
    let panel = AutoMixPanel(model: m)
    savePNG(panel.background(Color.black), width: 170, height: 110, name: "auto-mix-panel")
    let on = try #require(renderPixels(panel, width: 170, height: 110))
    let lit = on.count(inX: 0..<170, y: 0..<110) { r, g, b in r + g + b > 120 }
    #expect(lit > 50, "it draws")
    let differ = on.rgba != off.rgba  // (never #expect on the arrays themselves)
    #expect(differ, "AUTO lit and the status changed")
  }
}
