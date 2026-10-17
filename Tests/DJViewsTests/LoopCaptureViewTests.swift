import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The deck's new ways to take a loop: the tap-length chip beside LOOP and the ⟲ 1 2 4 grab.
@MainActor
struct LoopCaptureViewTests {
  /// Deck A plays the demo loop (120 bpm) for a few bars.
  func model() throws -> (AppModel, DJEngine) {
    let rate = 22_050.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    try dj.start()
    let m = AppModel(engine: dj)
    m.defaults = scratchDefaults()
    m.start()
    let bar = Int(rate * 2)
    var done = 0
    while done < 3 * bar + bar / 2 {
      done += try renderOffline(dj, frames: 512)
      dj.serviceLoopTakes()
    }
    m.poll()
    return (m, dj)
  }

  @Test func grabTakesTheLastBarsAsAClipOnTheRow() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    #expect(m.clips.isEmpty)
    m.grabBars("A", bars: 2)
    let clip = try #require(m.clips.first)
    #expect(m.clips.count == 1 && clip.bars == 2 && clip.source == "A")
    #expect(clip.loop == .starting || clip.loop == .on, "loops like a fresh take")
    #expect(clip.provenance.first { $0.hasPrefix("Grabbed after the fact") } != nil)
    m.grabBars("B", bars: 1)  // B is not playing: nothing
    #expect(m.clips.count == 1)
  }

  @Test func theTapLengthStepsIsSavedAndReachesTheEngine() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    #expect(m.tapBars == 2 && dj.tapTakeBars == 2, "2 bars until changed")
    m.stepTapBars()
    #expect(m.tapBars == 4 && dj.tapTakeBars == 4)
    #expect(m.defaults.integer(forKey: AppModel.tapBarsKey) == 4)
    m.stepTapBars()
    m.stepTapBars()
    #expect(m.tapBars == 1, "8, then round to 1")
    m.setTapBars(3)
    #expect(m.tapBars == 1, "only 1, 2, 4, 8")
    #expect(m.controlState()["loops"]?["tapBars"] == .int(1))
    // the next launch finds it
    m.setTapBars(8)
    let dj2 = try DJEngine(decks: ["A"], offline: true, sampleRate: dj.sampleRate)
    let m2 = AppModel(engine: dj2)
    m2.defaults = m.defaults
    m2.start()
    #expect(m2.tapBars == 8 && dj2.tapTakeBars == 8)
  }

  @Test func aTapOfTheButtonRecordsTheTapLength() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    m.setTapBars(1)
    m.loopRecord("A", on: true)
    m.loopRecord("A", on: false)
    m.poll()
    #expect(m.recording["A"]?.bars == 1 && m.recording["A"]?.released == true)
    var done = 0
    while m.clips.isEmpty, done < 3 * 44_100 {
      done += try renderOffline(dj, frames: 512)
      dj.serviceLoopTakes()
      m.poll()
    }
    #expect(m.clips.first?.bars == 1)
  }

  @Test func theCaptureControlsAreDrawnBesideLoop() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let view = LoopCaptureControls(name: "A", model: m).padding(4).background(Color.black)
      .environment(\.colorScheme, .dark)
    savePNG(view, width: 260, height: 40, name: "loop-capture-controls")
    let px = try #require(renderPixels(view, width: 260, height: 40))
    // LOOP and its tap chip in red on the left, the grab buttons in the loop channel's violet
    let red = px.count(inX: 0..<130, y: 0..<40) { r, g, b in r > 150 && g < 90 && b < 90 }
    let violet = px.count(inX: 100..<260, y: 0..<40) { r, g, b in b > 150 && r > 90 && g < r }
    #expect(red > 40, "LOOP and the tap chip (\(red) red pixels)")
    #expect(violet > 20, "the grab buttons (\(violet) violet pixels)")
  }
}
