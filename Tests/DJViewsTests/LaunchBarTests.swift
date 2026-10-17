import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The Loops row's launch controls: "Launch on", the countdown on a waiting tile, and scenes.
@MainActor
struct LaunchBarTests {
  /// Deck A playing the demo loop (120 bpm, 22.05 kHz), one bar of it taken and looping.
  func model(takes: LoopLibrary? = nil) throws -> (AppModel, DJEngine) {
    try LoopRowViewTests().model(takes: takes)
  }

  func run(_ dj: DJEngine, _ frames: Int) throws {
    var done = 0
    while done < frames {
      done += try renderOffline(dj, frames: 512)
      dj.serviceLoopTakes()
    }
  }

  static let bar = 44_100  // 4 beats at 120 bpm, 22.05 kHz

  @Test func aSceneWithNoLoopsOnTheRowIsNeverLit() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.saveScene()
    m.poll()
    #expect(m.scenes.first?.active == true, "its loop plays")
    m.removeClip(id)
    try run(dj, Self.bar)
    m.poll()
    #expect(dj.loopingClips.isEmpty)
    #expect(m.scenes.first?.count == 0 && m.scenes.first?.active == false, "\(m.scenes)")
    // nor one saved with nothing playing
    m.saveScene("empty")
    m.poll()
    #expect(m.scenes.last?.name == "empty" && m.scenes.last?.active == false)
    #expect(m.controlState()["loops"]?["scenes"]?[1]?["active"] == .bool(false))
  }

  @Test func launchOnIsRecordedAndRemembered() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    m.defaults = scratchDefaults()
    #expect(m.loopQuantum == 4 && dj.loopQuantum == 4, "a bar by default")
    m.setLoopQuantum(16)
    #expect(dj.loopQuantum == 16 && m.loopQuantum == 16)
    #expect(m.defaults.object(forKey: AppModel.loopQuantizeKey) as? Int == 16)
    // a change from elsewhere (the control socket) shows, and is remembered too
    dj.perform(.loopQuantize(beats: 1))
    m.poll()
    #expect(m.loopQuantum == 1 && m.defaults.object(forKey: AppModel.loopQuantizeKey) as? Int == 1)
  }

  @Test func aWaitingTileCountsDown() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.setLoopQuantum(16)
    m.toggleLoop(id)  // out, on the next 4-bar line
    m.poll()
    let c = try #require(m.clips.first)
    #expect(c.loop == .stopping)
    let cd = try #require(c.countdown)
    #expect(cd.beats >= 1 && cd.beats <= 16, "\(cd)")
    #expect(cd.label == (cd.beats > 8 ? "in \((cd.beats + 3) / 4) bars" : "in \(cd.beats)"))
    try run(dj, Self.bar)
    m.poll()
    if let later = m.clips.first?.countdown {
      #expect(later.beats < cd.beats && later.progress > cd.progress, "\(later) after \(cd)")
    }
    try run(dj, 4 * Self.bar)
    m.poll()
    #expect(m.clips.first?.loop == .off && m.clips.first?.countdown == nil)
  }

  @Test func theCountdownLabelSaysBeatsThenBars() {
    #expect(LoopCountdown(beats: 2.4, of: 4).label == "in 3")
    #expect(LoopCountdown(beats: 3.0, of: 4).beats == 3, "on the beat: not one more")
    #expect(LoopCountdown(beats: 0.1, of: 4).label == "in 1")
    #expect(LoopCountdown(beats: 13.5, of: 16).label == "in 4 bars")
    #expect(LoopCountdown(beats: 1, of: 4).progress == 0.75)
  }

  @Test func theBadgeDrawsItsRing() throws {
    let badge = { (stopping: Bool) in
      LoopCountdownBadge(countdown: LoopCountdown(beats: 1, of: 4), stopping: stopping)
        .padding(4).background(Color.black)
    }
    savePNG(badge(false), width: 60, height: 24, name: "loop-countdown")
    let inPx = try #require(renderPixels(badge(false), width: 60, height: 24))
    let violet = inPx.count(inX: 0..<60, y: 0..<24) { r, g, b in b > 180 && r > 120 && g < r }
    #expect(violet > 15, "the ring and label in the loops' violet (\(violet))")
    let outPx = try #require(renderPixels(badge(true), width: 60, height: 24))
    let amber = outPx.count(inX: 0..<60, y: 0..<24) { r, g, b in r > 200 && g > 120 && b < 120 }
    #expect(amber > 15, "going out: amber (\(amber))")
  }

  @Test func scenesAreChipsSavedWithTheLibrary() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try model(takes: lib)
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.saveScene()
    #expect(m.scenes.map(\.name) == ["Scene 1"] && m.scenes.first?.count == 1)
    #expect(m.scenes.first?.active == true, "exactly its loops are playing")
    m.toggleLoop(id)
    try run(dj, 2 * Self.bar)
    m.poll()
    #expect(m.clips.first?.loop == .off && m.scenes.first?.active == false)
    m.launchScene("Scene 1")
    m.poll()
    #expect(m.clips.first?.loop == .starting && m.clips.first?.countdown != nil)
    try run(dj, 2 * Self.bar)
    m.poll()
    #expect(m.clips.first?.loop == .on && m.scenes.first?.active == true)
    m.renameScene("Scene 1", to: "  drop ")
    #expect(m.scenes.map(\.name) == ["drop"])
    m.saveScene()
    #expect(m.scenes.map(\.name) == ["drop", "Scene 2"])
    m.deleteScene("Scene 2")
    m.flushLoopLibrary()
    #expect(lib.loadScenes().map(\.name) == ["drop"])
    #expect(lib.loadScenes().first?.clips.map(\.clipID) == [id])

    // the next launch finds it there
    let dj2 = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: dj.sampleRate)
    let m2 = AppModel(engine: dj2, takes: lib)
    m2.start()
    m2.poll()
    #expect(m2.scenes.map(\.name) == ["drop"] && m2.scenes.first?.active == false)

    let view = LoopRowView(model: m).padding().background(Color.black)
      .environment(\.colorScheme, .dark)
    savePNG(view, width: 900, height: 200, name: "loop-row-scenes")
  }
}
