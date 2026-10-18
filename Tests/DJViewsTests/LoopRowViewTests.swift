import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct LoopRowViewTests {
  /// Deck A plays the demo loop (120 bpm); one bar of it is taken with LOOP record.
  func model(takes: LoopLibrary? = nil) throws -> (AppModel, DJEngine) {
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
    let m = AppModel(engine: dj, takes: takes)
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

  @Test func theRowIsSavedAndComesBackOnTheNextLaunch() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try model(takes: lib)
    defer { dj.stop() }
    m.flushLoopLibrary()
    let saved = lib.load(sampleRate: dj.sampleRate)
    #expect(saved.map(\.id) == m.clips.map(\.id) && saved.count == 1)
    // a second app over a fresh engine finds it there
    let dj2 = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: dj.sampleRate)
    let m2 = AppModel(engine: dj2, takes: lib)
    m2.start()
    m2.poll()
    #expect(m2.clips.map(\.id) == saved.map(\.id) && m2.clips.first?.loop == .off)
  }

  @Test func aTakeAppearsAsAClipLoopingUnderTheMixer() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    #expect(m.recording.isEmpty)
    let clip = try #require(m.clips.first)
    #expect(m.clips.count == 1 && clip.source == "A" && clip.bars >= 1)
    #expect(clip.loop == .on && m.loopChannel.looping == 1 && clip.playhead != nil)

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
    #expect(m.clips.first?.onDeck == "B" && m.clips.first?.loop != .on)
    #expect(m.decks["B"]?.clipID == clip.id)
  }

  @Test func selectedLoopsJoinIntoASequenceTile() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let one = try #require(m.clips.first)
    m.toggleSelected(one.id)
    #expect(m.selectedClips == [one.id])
    m.joinSelected()
    #expect(m.selectedClips.isEmpty && m.clips.count == 2)
    let seq = try #require(m.clips.last)
    #expect(seq.steps?.map(\.clipID) == [one.id] && seq.steps?.first?.name == "loop 1")
    m.editSequence(seq.id, [SequenceStep(clipID: one.id, repeats: 2)])
    #expect(m.clips.count == 2 && m.clips.last?.steps?.first?.repeats == 2)
    #expect(m.clips.last?.beats == 2 * one.beats)
  }

  @Test func aClipSaysWhereItCameFrom() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let lines = try #require(m.clips.first?.provenance)
    #expect(lines.first == "Deck A: demo loop", "\(lines)")
    #expect(lines.contains("From bar 2, 2 bars"), "\(lines)")
    #expect(lines.contains { $0.hasPrefix("120.0 bpm") })
    #expect(lines.contains("EQ and filter flat") && lines.last?.hasPrefix("Recorded ") == true)
    #expect(m.clips.first?.provenanceJSON?.contains("\"deck\":\"A\"") == true)
    let c = try #require(m.clips.first)
    m.cropClip(c.id, from: 0, to: 4)
    #expect(m.clips.first?.provenance.first == "Cropped to beats 1–4 of:")
  }

  @Test func aTileMutesSolosAndKeyLocksItsLoop() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let clip = try #require(m.clips.first)
    #expect(!clip.muted && !clip.soloed && !clip.keyLock && !clip.stretched)
    #expect(m.loopChannel.fade == .declick && !m.loopChannel.keyLock)
    m.setClipMute(clip.id, true)
    m.setClipSolo(clip.id, true)
    m.setClipKeyLock(clip.id, true)
    let after = try #require(m.clips.first)
    #expect(after.muted && after.soloed && after.keyLock)
    #expect(dj.isClipMuted(clip.id) && dj.isClipSoloed(clip.id) && dj.isKeyLocked(clip.id))
    #expect(after.loop == .on, "muted, it is still looping")
    m.setLoopFade(.beat)
    m.setLoopKeyLock(true)
    #expect(m.loopChannel.fade == .beat && m.loopChannel.keyLock && dj.loopFade == .beat)
    m.setClipKeyLock(clip.id, false)
    #expect(m.clips.first?.keyLock == false, "its own setting wins over the row's")

    let view = LoopRowView(model: m).padding().background(Color.black)
      .environment(\.colorScheme, .dark)
    savePNG(view, width: 900, height: 200, name: "loop-row-sound")
    #expect(renderPixels(view, width: 900, height: 200) != nil)
  }

  @Test func theSoundControlsAreRecordedInASession() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    for d in dj.decks.values { d.loadDemo() }
    let rec = try SessionRecorder.start(on: dj)
    let m = AppModel(engine: dj)
    m.start()
    m.setClipMute("abc", true)
    m.setClipSolo("abc", true)
    m.setClipKeyLock("abc", true)
    m.setLoopKeyLock(true)
    m.setLoopFade(.bar)
    m.setClipQuantum("abc", 8)
    m.setClipFade("abc", .beat)
    m.setClipFollow("abc", .source)
    m.setClipFade("abc", nil)
    let actions = rec.finish().events.compactMap { e -> DeckAction? in
      if case .action(let a) = e.kind { return a }
      return nil
    }
    #expect(
      actions == [
        .clipMute(id: "abc", on: true), .clipSolo(id: "abc", on: true),
        .clipKeyLock(id: "abc", on: true), .loopKeyLock(on: true), .loopFade(mode: "bar"),
        .clipQuantize(id: "abc", beats: 8), .clipFade(id: "abc", mode: "beat"),
        .clipFollow(id: "abc", mode: "source"), .clipFade(id: "abc", mode: nil),
      ])
  }

  /// A clip's own launch boundary, fade and tempo follow show on its `ClipState` (what its
  /// settings and its pad read); a row-wide change leaves them, and nil hands it back.
  @Test func aClipsOwnLaunchRulesShowOnItsState() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let clip = try #require(m.clips.first)
    #expect(clip.quantum == nil && clip.fade == nil && clip.follow == nil)
    #expect(!clip.hasLaunchOverride && clip.launchBadge == nil)
    m.setClipQuantum(clip.id, 4)
    m.setClipFade(clip.id, .off)
    m.setClipFollow(clip.id, .louder)
    m.setLoopFade(.bar)
    let own = try #require(m.clips.first)
    #expect(own.quantum == 4 && own.fade == .off && own.follow == .louder)
    #expect(own.launchBadge == "bar · fade off · louder deck")
    #expect(dj.loopFade(for: clip.id) == .off && m.loopChannel.fade == .bar)
    m.setClipQuantum(clip.id, 3)
    #expect(m.clips.first?.quantum == 4, "a boundary that isn't one of launchQuanta is refused")
    m.setClipFollow(clip.id, nil)
    #expect(m.clips.first?.follow == nil && m.clips.first?.launchBadge == "bar · fade off")
  }
}
