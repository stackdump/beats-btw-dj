import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct LoopRowViewTests {
  /// Deck A plays the demo loop (120 bpm); one bar of it is taken with LOOP record.
  func model() throws -> (AppModel, DJEngine) {
    let rate = 22_050.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    try dj.start()
    let bar = Int(rate * 2)  // 4 beats at 120 bpm
    func run(_ frames: Int) throws {
      var done = 0
      while done < frames {
        done += try renderOffline(dj, frames: 512)
        dj.serviceLoopTakes()
      }
    }
    let m = AppModel(engine: dj)
    m.start()
    try run(bar + bar / 2)
    m.loopRecord("A", on: true)
    m.poll()
    #expect(m.recording["A"] != nil, "the take shows while it is held")
    try run(bar)
    m.loopRecord("A", on: false)
    try run(bar)
    m.poll()
    return (m, dj)
  }

  @Test func aTakeAppearsAsAClipLoopingUnderTheMixer() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    #expect(m.recording.isEmpty)
    let clip = try #require(m.clips.first)
    #expect(m.clips.count == 1 && clip.source == "A" && clip.bars >= 1)
    #expect(clip.playingOn == "L" && m.loopChannel.playing && m.loopChannel.clipID == clip.id)

    let view = LoopRowView(model: m).padding().background(Color.black)
      .environment(\.colorScheme, .dark)
    savePNG(view, width: 700, height: 160, name: "loop-row")
    let px = try #require(renderPixels(view, width: 700, height: 160))
    // the playing clip's waveform and frame, in the loop channel's violet
    // (below the header row: the tile, not the header's play button)
    let violet = px.count(inX: 0..<700, y: 60..<160) { r, g, b in b > 180 && r > 120 && g < r }
    #expect(violet > 300, "the looping clip is drawn (\(violet) violet pixels)")

    // moved onto deck B, the row says so and the loop channel stops
    m.playClip(clip.id, on: "B")
    m.poll()
    #expect(m.clips.first?.playingOn == "B" && !m.loopChannel.playing)
    #expect(m.decks["B"]?.clipID == clip.id)
  }
}
