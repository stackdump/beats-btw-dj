import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The app's side of the adaptive visual level: the monitor runs while a deck plays, the rings are
// rebuilt at the level's pace, the notice is on the main window.

@MainActor
struct PerfAppModelTests {
  /// An offline engine: deck A a net at 300 BPM (a step is 50 ms), deck B the demo loop.
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

  @Test func theAppHandsItsMonitorToTheHubAndTheLevelFollowsIt() throws {
    let dj = try engine(play: false)
    let perf = PerfMonitor(store: PerfPreferenceStore(load: { .minimal }, save: { _ in }))
    let m = AppModel(engine: dj, perf: perf)
    m.start()
    let hub = try #require(m.scopeHub)
    #expect(hub.perf === perf)
    #expect(hub.vizLevel == 2, "a remembered preference is the level from the start")
    perf.setPreference(.reduced)
    #expect(
      hub.vizLevel == 1 && m.stageModel?.minFrameInterval == StageFramePacer.minInterval(level: 1))
    dj.stop()
  }

  @Test func theMonitorMeasuresWhileADeckPlaysAndNotOtherwise() throws {
    let dj = try engine(play: false)
    defer { dj.stop() }
    let m = AppModel(engine: dj)
    m.start()
    let perf = try #require(m.scopeHub).perf
    #expect(!perf.isRunning, "nothing plays")
    dj["B"]!.setPlaying(true)
    m.poll()
    #expect(perf.isRunning, "a sample deck counts too")
    dj["B"]!.setPlaying(false)
    m.poll()
    #expect(!perf.isRunning)
    dj["A"]!.setPlaying(true)
    m.poll()
    #expect(perf.isRunning)
    dj["A"]!.setPlaying(false)
    m.poll()
    #expect(!perf.isRunning)
  }

  @Test func theRingsAreRebuiltAsOftenAsTheLevelAllows() throws {
    let dj = try engine(play: true)
    defer { dj.stop() }
    let perf = PerfMonitor()
    let m = AppModel(engine: dj, perf: perf)
    var t = 100.0
    m.uptime = { t }
    m.start()  // polls at t = 100
    func tick() -> Int { m.decks["A"]?.snapshot?.tick ?? -1 }
    func advance(to time: Double) throws {
      try renderOffline(dj, frames: 4410)  // 0.2 s of audio: 4 steps
      t = time
      m.poll()
    }
    let t0 = tick()
    #expect(t0 >= 0, "deck A's rings exist")

    // full: every poll
    try advance(to: 100.1)
    let t1 = tick()
    #expect(t1 > t0)
    try advance(to: 100.2)
    let t2 = tick()
    #expect(t2 > t1)

    // minimal: at most every 0.5 s of poll time
    perf.setPreference(.minimal)
    try advance(to: 100.3)
    #expect(tick() == t2, "held back: 0.1 s after the last rebuild")
    try advance(to: 100.6)
    #expect(tick() == t2, "0.4 s after it")
    try advance(to: 100.7)
    let t3 = tick()
    #expect(t3 > t2, "0.5 s since the rebuild at 100.2")
    try advance(to: 101.0)
    #expect(tick() == t3)

    // paused: every 2 s
    perf.setPreference(.paused)
    try advance(to: 102.6)
    #expect(tick() == t3, "1.9 s after 100.7 is not enough")
    try advance(to: 102.7)
    let t4 = tick()
    #expect(t4 > t3)
    try advance(to: 104.0)
    #expect(tick() == t4)

    // back to full: the very next poll
    perf.setPreference(.full)
    try advance(to: 104.1)
    #expect(tick() > t4)
  }

  @Test func theRingsAndTheirSwingAreHeldTogether() throws {
    let dj = try engine(play: true)
    defer { dj.stop() }
    let perf = PerfMonitor()
    perf.setPreference(.paused)
    let m = AppModel(engine: dj, perf: perf)
    var t = 10.0
    m.uptime = { t }
    m.start()
    let arcs0 = try #require(m.decks["A"]).ringArcs
    #expect(arcs0.playing)
    dj["A"]!.setPlaying(false)  // the arc layer dims while a deck plays, so it shows in `playing`
    try renderOffline(dj, frames: 4410)
    t = 10.5
    m.poll()
    #expect(m.decks["A"]?.ringArcs == arcs0, "the arc layer is part of the net canvas")
    #expect(m.decks["A"]?.playing == false, "(the rest of the deck state is not held back)")
    t = 12.1
    m.poll()
    #expect(m.decks["A"]?.ringArcs.playing == false, "and follows when the canvas is rebuilt")
  }

  @Test func aNewTrackOnADeckShowsAtOnceEvenWhileTheRingsAreHeldBack() throws {
    let dj = try engine(play: true)
    defer { dj.stop() }
    let perf = PerfMonitor()
    perf.setPreference(.paused)
    let m = AppModel(engine: dj, perf: perf)
    var t = 10.0
    m.uptime = { t }
    m.start()
    let before = m.decks["A"]?.snapshot
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "house", seed: 7, structure: "standard"), sampleRate: 22_050))
    try renderOffline(dj, frames: 4410)
    t = 10.2
    m.poll()
    #expect(m.decks["A"]?.snapshot != before, "another title: rebuilt out of turn")
    #expect(m.decks["A"]?.title != "—")
  }

  // MARK: the main window

  @Test func theNoticeIsAToastOverTheMainWindowsFootUntilItIsDismissed() throws {
    let dj = try engine(play: false)
    defer { dj.stop() }
    let clock = TestClock()
    let perf = PerfMonitor(clock: { clock.now })
    let m = AppModel(engine: dj, perf: perf)
    m.start()
    perf.start()
    for _ in 0..<110 {
      let t0 = perf.vizBegin()
      clock.advance(ms: 40)
      perf.vizEnd(.scope, t0)
      perf.frame()
    }
    #expect(perf.notice != nil && m.scopeHub?.vizLevel == 1)
    // tall enough for the bottom bar, above which the toast floats
    let with = try #require(renderPixels(ContentView(model: m), width: 1100, height: 1500))
    savePNG(ContentView(model: m), width: 1100, height: 1500, name: "app-with-notice")
    perf.keepFullVisuals()
    let without = try #require(renderPixels(ContentView(model: m), width: 1100, height: 1500))
    // The toast's "Keep full visuals" link is the one thing down here of that light blue
    // (125, 196, 255); the rest of the window animates between two renders, so it cannot be diffed.
    func link(_ px: Pixels) -> (n: Int, x0: Int, x1: Int, y0: Int, y1: Int) {
      var out = (n: 0, x0: px.width, x1: 0, y0: px.height, y1: 0)
      for y in 1000..<1300 {
        for x in 400..<900 where px.near(x, y, (125, 196, 255), tol: 18) {
          out = (out.n + 1, min(out.x0, x), max(out.x1, x), min(out.y0, y), max(out.y1, y))
        }
      }
      return out
    }
    let shown = link(with)
    #expect(shown.n > 40, "the window shows the notice's link (\(shown.n) pixels)")
    #expect(link(without).n == 0, "and only while there is a notice")
    #expect(
      shown.x0 > 550 && shown.x1 < 850, "at the bottom centre, as monitor.js' toast: \(shown)")
    #expect(shown.y0 > 1050 && shown.y1 < 1150, "just above the bottom bar: \(shown)")
    #expect(m.scopeHub?.vizLevel == 0)
  }
}
