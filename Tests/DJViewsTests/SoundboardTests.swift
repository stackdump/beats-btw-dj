import SwiftUI
import Testing

@testable import DJCore
@testable import DJViews

/// The Soundboard: a pad per loop on the row, worked out from the engine; its clicks and its
/// right-click menu are the Loops row's own `DeckAction`s; its settings edit the row's clip.
@MainActor
struct SoundboardTests {
  static let rate = 22_050.0
  static let bar = Int(rate * 2)  // 4 beats at 120 bpm

  /// Deck A plays the demo loop (120 bpm); one bar of it is taken with LOOP record, and loops.
  func model() throws -> (AppModel, DJEngine) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    try dj.start()
    let m = AppModel(engine: dj)
    m.defaults = scratchDefaults()
    m.start()
    try run(dj, Self.bar + Self.bar / 2)
    m.loopRecord("A", on: true)
    try run(dj, Self.bar)
    m.loopRecord("A", on: false)
    try run(dj, Self.bar)
    m.poll()
    return (m, dj)
  }

  func run(_ dj: DJEngine, _ frames: Int) throws {
    var done = 0
    while done < frames {
      done += try renderOffline(dj, frames: 512)
      dj.serviceLoopTakes()
    }
  }

  /// `n` pads: the take, then sequences of it repeated 2, 3… times (each its own audio).
  func pads(_ n: Int) throws -> (AppModel, DJEngine) {
    let (m, dj) = try model()
    let id = try #require(m.clips.first?.id)
    for k in 1..<max(1, n) {
      dj.perform(.clipSequence(steps: [SequenceStep(clipID: id, repeats: k + 1)], replacing: nil))
    }
    m.poll()
    #expect(m.soundPads.count == n)
    return (m, dj)
  }

  @Test func aPadIsTheClipAtAGlanceAndFollowsTheEngine() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let clip = try #require(m.clips.first)
    let pad = try #require(m.soundPads.first)
    #expect(m.soundPads.count == m.clips.count)
    #expect(pad.id == clip.id && pad.title == clip.title)
    #expect(pad.lengthLabel == clip.lengthLabel && pad.lengthLabel.hasSuffix("bars"))
    #expect(pad.state == .on && pad.light == .full && pad.stateLabel == "on")
    #expect(pad.phase != nil, "a looping pad shows where it is in its loop")
    #expect(pad.slot == "A1", "the first loop is the Inpulse's LOOP pad A1")
    #expect(pad.color == nil && !pad.muted && !pad.soloed)

    m.setClipColor(clip.id, "red")
    m.setClipMute(clip.id, true)
    #expect(m.soundPads.first?.color == "red" && m.soundPads.first?.muted == true)

    // out on the next bar: blinking, with its countdown, then dark
    m.padClick(clip.id)
    m.poll()
    let going = try #require(m.soundPads.first)
    #expect(going.state == .stopping && going.light == .blink)
    #expect(going.stateLabel.hasPrefix("out"), "\(going.stateLabel)")
    #expect(going.countdown != nil)
    try run(dj, Self.bar + Self.bar / 4)
    m.poll()
    #expect(m.soundPads.first?.state == .off && m.soundPads.first?.light == .off)
    #expect(m.soundPads.first?.stateLabel == "off")
    // and back in, blinking until the boundary
    m.padClick(clip.id)
    m.poll()
    #expect(m.soundPads.first?.state == .starting && m.soundPads.first?.light == .blink)
    #expect(m.soundPads.first?.stateLabel.hasPrefix("in") == true)
  }

  /// A pad lights as the APC's loop page lights the same loop (and the Inpulse's LOOP pads).
  @Test func padLightsMatchTheControllersLoopPads() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    m.setShowPads(true)  // the on-screen APC
    let id = try #require(m.clips.first?.id)
    func apc() throws -> PadLight {
      let l = try #require(
        m.router?.lights(profileName: SurfaceProfile.apcMiniMK2.name, shift: true))
      return try #require(l.groups["pads"]?[56])  // top-left: loop 1
    }
    func check() throws {
      m.poll()
      let pad = try #require(m.soundPads.first)
      let led = try apc()
      switch pad.light {
      case .full: #expect(led.level == .full && led.colorIndex != 0)
      case .blink: #expect(led.level == .blink && led.colorIndex != 0)
      case .off, .dim: #expect(led.colorIndex == 0, "dark")
      }
    }
    try check()  // on
    m.padClick(id)
    try check()  // going out
    try run(dj, Self.bar + Self.bar / 4)
    try check()  // off
    #expect(SoundPad.light(.on) == .full && SoundPad.light(.starting) == .blink)
    #expect(SoundPad.light(.stopping) == .blink && SoundPad.light(.off) == .off)
  }

  /// A click is the row's ▶/■ (`clipLoop`), ⌥ its S, ⇧ its M: the same actions, recorded.
  @Test func aClickPerformsTheRowsDeckAction() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (first, dj0) = try model()
    let id = try #require(first.clips.first?.id)
    #expect(first.soundboardAction(.toggle, id) == .clipLoop(id: id, on: false), "on: stops it")
    try lib.save(dj0.clips, scenes: [])
    dj0.stop()
    // the next launch, its loop off on the board and the decks at rest, recording a session
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    for d in dj.decks.values { d.loadDemo() }
    try dj.start()
    defer { dj.stop() }
    let m = AppModel(engine: dj, takes: lib)
    m.defaults = scratchDefaults()
    m.start()
    #expect(m.soundPads.map(\.id) == [id] && m.soundPads.first?.state == .off)
    let rec = try SessionRecorder.start(on: dj)
    m.padClick(id)
    m.padClick(id, option: true)
    m.padClick(id, shift: true)
    let actions = rec.finish().events.compactMap { e -> DeckAction? in
      if case .action(let a) = e.kind { return a }
      return nil
    }
    #expect(
      actions == [
        .clipLoop(id: id, on: true), .clipSolo(id: id, on: true), .clipMute(id: id, on: true),
      ])
    m.poll()
    #expect(m.soundPads.first?.state != .off, "coming in")
    #expect(m.clips.first?.soloed == true && m.clips.first?.muted == true)
    // ⌥ / ⇧ again undo them
    m.padClick(id, option: true)
    m.padClick(id, shift: true)
    #expect(m.clips.first?.soloed == false && m.clips.first?.muted == false)
  }

  /// The right-click menu's quick ones route to the row's actions, and do what the row does.
  @Test func theMenusCommandsAreTheRowsActions() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    let expected: [(SoundPadCommand, DeckAction?)] = [
      (.mute(true), .clipMute(id: id, on: true)),
      (.solo(true), .clipSolo(id: id, on: true)),
      (.keyLock(true), .clipKeyLock(id: id, on: true)),
      (.color("teal"), .clipColor(id: id, color: "teal")),
      (.color(nil), .clipColor(id: id, color: nil)),
      (.rename("  kick  "), .clipRename(id: id, title: "kick")),
      (.rename("  "), nil),
      (.fade(.bar), .clipFade(id: id, mode: "bar")),
      (.fade(nil), .clipFade(id: id, mode: nil)),
      (.quantize(8), .clipQuantize(id: id, beats: 8)),
      (.quantize(nil), .clipQuantize(id: id, beats: nil)),
      (.follow(.source), .clipFollow(id: id, mode: "source")),
      (.follow(nil), .clipFollow(id: id, mode: nil)),
      (.loopFade(.bar), .loopFade(mode: "bar")),
      (.move("B"), .clip(deck: "B", id: id)),
      (.move("L"), .clip(deck: "L", id: id)),
      (.remove, .clipRemove(id: id)),
    ]
    for (c, a) in expected { #expect(m.soundboardAction(c, id) == a, "\(c)") }
    #expect(m.soundboardAction(.toggle, "nope") == nil)

    m.soundboard(.rename("kick"), id)
    m.soundboard(.keyLock(true), id)
    m.soundboard(.fade(.beat), id)
    m.poll()
    #expect(m.clips.first?.title == "kick" && m.clips.first?.keyLock == true)
    #expect(m.clips.first?.fade == .beat && dj.clipFade(id) == .beat, "the pad's own fade")
    #expect(m.loopChannel.fade == .declick && dj.loopFade == .declick, "not the row's")
    m.soundboard(.loopFade(.bar), id)
    m.poll()
    #expect(m.loopChannel.fade == .bar && dj.loopFade == .bar, "all loops")
    #expect(dj.loopFade(for: id) == .beat, "its own fade still wins")
    // onto deck B and back under the mixer
    m.soundboard(.move("B"), id)
    m.poll()
    #expect(m.soundPads.first?.onDeck == "B" && m.decks["B"]?.clipID == id)
    m.soundboard(.move("L"), id)
    try run(dj, Self.bar + Self.bar / 4)
    m.poll()
    #expect(m.soundPads.first?.state == .on)
    // remove, with Undo
    m.soundboard(.remove, id)
    #expect(m.soundPads.isEmpty && m.lastRemoval?.id == id)
    m.undoRemove()
    m.poll()
    #expect(m.soundPads.map(\.id) == [id] && m.soundPads.first?.title == "kick")
  }

  /// A pad's fade, launch boundary and tempo follow are its clip's alone: the other pads keep the
  /// row's, the pad (and its settings) shows them, and "row" hands it back to the loop channel.
  @Test func aPadsLaunchRulesAreItsOwn() throws {
    let (m, dj) = try pads(2)
    defer { dj.stop() }
    let ids = m.soundPads.map(\.id)
    let (one, other) = (ids[0], ids[1])
    #expect(m.soundPads.allSatisfy { $0.launchBadge == nil }, "no rules of their own yet")

    m.soundboard(.fade(.bar), one)
    m.soundboard(.quantize(8), one)
    m.soundboard(.follow(.source), one)
    m.poll()
    #expect(dj.clipFade(one) == .bar && dj.clipQuantum(one) == 8 && dj.clipFollow(one) == .source)
    #expect(
      dj.clipFade(other) == nil && dj.clipQuantum(other) == nil, "the other clip is as it was")
    #expect(dj.loopFade(for: other) == .declick && dj.quantum(for: other) == dj.loopQuantum)
    #expect(dj.loopFade == .declick && dj.loopFollow == .louder, "the row is as it was")
    let pad = try #require(m.soundPads.first { $0.id == one })
    #expect(pad.fade == .bar && pad.quantum == 8 && pad.follow == .source)
    #expect(pad.launchBadge == "2 bars · fade 1 bar · own deck", "\(pad.launchBadge ?? "nil")")
    #expect(m.soundPads.first { $0.id == other }?.launchBadge == nil)
    let shown = try #require(ClipSettingsView.clip(one, in: m))
    #expect(shown.fade == .bar && shown.quantum == 8 && shown.follow == .source)
    #expect(
      shown.hasLaunchOverride && !(ClipSettingsView.clip(other, in: m)?.hasLaunchOverride ?? true))

    // the settings' "row" choices give it back to the loop channel
    m.setClipFade(one, nil)
    m.setClipQuantum(one, nil)
    m.setClipFollow(one, nil)
    m.poll()
    #expect(dj.clipFade(one) == nil && dj.clipQuantum(one) == nil && dj.clipFollow(one) == nil)
    #expect(m.soundPads.first { $0.id == one }?.launchBadge == nil)
  }

  /// The badge draws on the pad: a red pad with rules of its own shows the loops' violet in its
  /// bottom line, the same pad without them shows none.
  @Test func aPadWithItsOwnRulesShowsTheBadge() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.setClipColor(id, "red")
    m.soundboard(.toggle, id)  // going out: the pad's face stays dim
    try run(dj, Self.bar + Self.bar / 4)
    m.poll()
    let (w, h) = (220, 130)
    func violet(_ pad: SoundPad) throws -> Int {
      let view = SoundPadView(pad: pad).frame(width: CGFloat(w), height: CGFloat(h))
        .background(Color.black).environment(\.colorScheme, .dark)
      savePNG(
        view, width: w, height: h, name: "sound-pad-\(pad.launchBadge == nil ? "row" : "own")")
      let px = try #require(renderPixels(view, width: w, height: h))
      return px.count(inX: 0..<w, y: (h - 30)..<h) { r, g, b in b > 150 && r > 90 && g < r }
    }
    let plain = try #require(m.soundPads.first)
    #expect(plain.launchBadge == nil)
    m.soundboard(.quantize(16), id)
    m.soundboard(.fade(.beat), id)
    m.poll()
    let own = try #require(m.soundPads.first)
    #expect(own.launchBadge == "4 bars · fade 1 beat")
    let (before, after) = (try violet(plain), try violet(own))
    #expect(after > before + 50, "the badge: \(before) → \(after) violet pixels")
  }

  /// The settings editor shows the row's own clip: a change from the row shows there and on the
  /// pad, and its crop follows the clip to the cropped one.
  @Test func theSettingsEditorEditsTheRowsClip() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.setClipGain(id, 0.4)
    m.setClipSolo(id, true)
    m.poll()
    let shown = try #require(ClipSettingsView.clip(id, in: m))
    #expect(shown == m.clips.first, "the same ClipState the row's tile draws")
    #expect(shown.gain == 0.4 && shown.soloed && m.soundPads.first?.soloed == true)
    // crop it (the editor's "Crop"): the cropped clip takes its place, and the editor follows
    var editing = id
    ClipSettingsView.crop(id, from: 0, to: 2, in: m) { editing = $0 }
    m.poll()
    #expect(editing != id && m.clips.first?.id == editing)
    #expect(ClipSettingsView.clip(editing, in: m)?.beats == 2)
    #expect(ClipSettingsView.clip(editing, in: m)?.gain == 0.4, "its level carries over")
    #expect(m.soundPads.first?.lengthLabel == "2 beats")
    // a loop from a sample has no instruments to tune
    #expect(m.originCID(editing) == nil && m.decksPlayingOrigin(editing).isEmpty)
  }

  /// A sequence's pad edits its steps as the row's tile does (`SequenceStepsEditor`): repeats,
  /// a loop added from the menu, a step moved and one removed; each edit remakes the sequence in
  /// its place under a new id, and the settings follow it.
  @Test func aSequencesStepsAreEditableFromItsPad() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    let take = try #require(m.clips.first)
    // a second, different loop: two beats from the middle of the take twice over
    dj.perform(.clipSequence(steps: [SequenceStep(clipID: take.id, repeats: 2)], replacing: nil))
    m.poll()
    let twice = try #require(m.clips.last?.id)
    m.cropClip(twice, from: take.beats - 1, to: take.beats + 1)
    let other = try #require(m.clips.last)
    #expect(other.steps == nil && other.beats == 2)
    dj.perform(
      .clipSequence(
        steps: [SequenceStep(clipID: take.id), SequenceStep(clipID: other.id)], replacing: nil))
    m.poll()
    #expect(m.clips.count == 3 && m.soundPads.count == 3)
    var editing = try #require(m.clips.last?.id)
    #expect(ClipSettingsView.clip(editing, in: m)?.steps?.map(\.clipID) == [take.id, other.id])
    // the menu offers every other loop on the row, never the sequence itself
    #expect(SequenceStepsEditor.addable(to: editing, in: m).map(\.id) == [take.id, other.id])
    #expect(SequenceStepsEditor.nextRepeats(1) == 2 && SequenceStepsEditor.nextRepeats(4) == 1)

    func steps() -> [SequenceStep]? {
      ClipSettingsView.clip(editing, in: m)?.steps.map(SequenceStepsEditor.sequenceSteps)
    }
    func edit(_ change: (inout [SequenceStep]) -> Void) throws {
      let before = editing
      var s = try #require(steps())
      change(&s)
      SequenceStepsEditor.edit(editing, s, in: m) { editing = $0 }
      m.poll()
      #expect(editing != before, "the remade sequence has a new id, which the settings follow")
      #expect(m.clips.count == 3 && m.clips[2].id == editing, "in the old one's place")
      #expect(m.soundPads.map(\.id) == m.clips.map(\.id), "its pad follows")
    }
    let t = take.beats
    let o = other.beats
    // a tap on the first chip: ×1 → ×2
    try edit { $0[0].repeats = SequenceStepsEditor.nextRepeats($0[0].repeats) }
    #expect(steps()?.map(\.repeats) == [2, 1])
    #expect(ClipSettingsView.clip(editing, in: m)?.beats == 2 * t + o)
    // "Add a loop": the take as a new last step
    try edit { $0.append(SequenceStep(clipID: take.id)) }
    #expect(steps()?.map(\.clipID) == [take.id, other.id, take.id])
    #expect(ClipSettingsView.clip(editing, in: m)?.beats == 3 * t + o)
    // "Move later" on the middle step, then "Remove" on the first
    try edit { $0.swapAt(1, 2) }
    #expect(steps()?.map(\.clipID) == [take.id, take.id, other.id])
    try edit { $0.remove(at: 0) }
    #expect(steps()?.map(\.clipID) == [take.id, other.id])
    let last = try #require(ClipSettingsView.clip(editing, in: m))
    #expect(last.beats == t + o && m.soundPads[2].lengthLabel == last.lengthLabel)

    let view = ClipSettingsView(id: .constant(editing), model: m).background(Color(white: 0.12))
    savePNG(view, width: 400, height: 640, name: "soundboard-sequence-settings")
    #expect(renderPixels(view, width: 400, height: 640) != nil)
  }

  /// A loop taken from a net can open that track's instruments while a deck plays it.
  @Test func aNetLoopsSettingsReachItsInstruments() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    let m = AppModel(engine: dj)
    m.defaults = scratchDefaults()
    m.start()
    #expect(await m.prepareAndLoad("A", .net(spec)))
    dj["A"]!.wave.setTempo(300)
    dj["A"]!.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    try run(dj, 40 * 4096)
    let id = try #require(dj.grabLastBars("A", bars: 1))
    m.poll()
    #expect(m.originCID(id) != nil && m.originCID(id) == m.decks["A"]?.sourceCID)
    #expect(m.decksPlayingOrigin(id) == ["A"])
    #expect(m.decks["A"]?.voices.isEmpty == false, "its instruments, for the sound panel")
  }

  /// At the window's narrowest the pads fill the width in whole columns for any count.
  @Test func padsLayOutAtTheWindowsMinimumWidth() throws {
    // the window's 720 less its padding (16 each side) and the card's (14 each side)
    let width: CGFloat = 720 - 2 * 16 - 2 * DJStyle.cardPadding
    for n in [1, 2, 4, 7, 9, 16, 24] {
      let cols = SoundboardLayout.columns(count: n, width: width)
      let pad = SoundboardLayout.padWidth(count: n, width: width)
      let size = SoundboardLayout.size(count: n, width: width)
      #expect(cols >= 1 && cols <= n, "\(n) pads: \(cols) columns")
      #expect(pad >= SoundboardLayout.minPad && pad <= SoundboardLayout.maxPad, "\(n): \(pad)")
      #expect(size.width <= width, "\(n) pads fit across (\(size.width) of \(width))")
      #expect(SoundboardLayout.rows(count: n, width: width) == (n + cols - 1) / cols)
    }
    #expect(SoundboardLayout.columns(count: 24, width: width) == 4)
    #expect(SoundboardLayout.columns(count: 2, width: width) == 2, "few pads: one row")
    #expect(SoundboardLayout.columns(count: 0, width: width) == 0)
    #expect(SoundboardLayout.columns(count: 9, width: 1400) == 9, "a wide window: one row")
  }

  /// ↑ / ↓ on the board move a row of the grid as laid out at that width.
  @Test func arrowsMoveARowOfTheBoard() {
    let width: CGFloat = 720 - 2 * 16 - 2 * DJStyle.cardPadding
    let ids = (0..<9).map { "pad\($0)" }
    let cols = SoundboardLayout.columns(count: ids.count, width: width)
    #expect(cols > 1 && cols < ids.count, "more than one row at the minimum width")
    #expect(
      HoverKeys.step(ids, from: "pad0", by: 1, vertical: true, columns: cols) == "pad\(cols)")
    #expect(
      HoverKeys.step(ids, from: "pad\(cols)", by: -1, vertical: true, columns: cols) == "pad0")
    #expect(HoverKeys.step(ids, from: "pad0", by: 1, vertical: false, columns: cols) == "pad1")
    let wide = SoundboardLayout.columns(count: ids.count, width: 1400)
    #expect(
      HoverKeys.step(ids, from: "pad3", by: 1, vertical: true, columns: wide) == "pad3",
      "one row: ↓ stays put")
  }

  @Test func theBoardDrawsItsPadsInRowsAtTheMinimumWidth() throws {
    let (m, dj) = try pads(5)
    defer { dj.stop() }
    let width = 720 - 2 * 16 - 2 * Int(DJStyle.cardPadding)
    let view = SoundboardView(model: m).frame(width: CGFloat(width)).padding(0)
      .background(Color.black).environment(\.colorScheme, .dark)
    let grid = SoundboardLayout.size(count: 5, width: CGFloat(width))
    let height = Int(grid.height) + 90
    savePNG(view, width: width, height: height, name: "soundboard")
    let px = try #require(renderPixels(view, width: width, height: height))
    // the loops' violet: the playing pad's face, and the other pads' outlines, in both rows
    let violet = { (ys: Range<Int>) in
      px.count(inX: 0..<width, y: ys) { r, g, b in b > 150 && r > 90 && g < r }
    }
    let rows = SoundboardLayout.rows(count: 5, width: CGFloat(width))
    #expect(rows == 2)
    #expect(violet((height - Int(grid.height))..<(height - Int(grid.height) / 2)) > 500)
    #expect(violet((height - Int(grid.height) / 2 + 4)..<height) > 100, "the second row")
  }

  /// A fresh engine with deck A playing the demo loop (120 bpm), nothing on the row.
  func stockModel(_ defaults: UserDefaults? = nil) throws -> (AppModel, DJEngine) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    try dj.start()
    let m = AppModel(engine: dj)
    m.defaults = defaults ?? scratchDefaults()
    m.start()
    try run(dj, Self.bar / 2)
    m.poll()
    return (m, dj)
  }

  /// A Stock pad puts its loop on the row (a recorded `clipImport`), in on the next launch
  /// boundary; it lights as its clip does; a click on a sounding one takes it out, and another
  /// brings the same clip back. The Row page shows the clip like any other loop.
  @Test func aStockPadImportsAndLaunchesTheLoop() async throws {
    let (m, dj) = try stockModel()
    defer { dj.stop() }
    let loop = try temporaryStockLoop("Test Beat 01", category: "Drums")
    m.stockLoops = [loop]
    m.setSoundboardPage(.stock)
    #expect(m.soundboardPage == .stock)
    let pad = try #require(m.stockPads.first)
    #expect(pad.id == loop.path && pad.title == "Test Beat 01" && pad.bpm == 120)
    #expect(!pad.onRow && pad.state == .off && pad.light == .off && !pad.loading)
    let rec = try SessionRecorder.start(on: dj)
    let id = try #require(await m.stockPadClick(loop.path))
    m.poll()
    #expect(m.clips.map(\.id) == [id] && m.soundPads.map(\.id) == [id], "the Row page has it")
    #expect(m.stockClipsOnRow == [loop.path: id])
    let coming = try #require(m.stockPads.first)
    #expect(coming.clipID == id && coming.onRow && !coming.loading)
    #expect(coming.state == .starting || coming.state == .on, "\(coming.state)")
    try run(dj, Self.bar + Self.bar / 4)
    m.poll()
    #expect(m.stockPads.first?.state == .on && m.stockPads.first?.light == .full)
    #expect(dj.loopingClips == [id], "it loops under the mixer")
    // a sounding pad: out on the next boundary
    #expect(await m.stockPadClick(loop.path) == id)
    m.poll()
    #expect(m.stockPads.first?.state == .stopping && m.stockPads.first?.light == .blink)
    try run(dj, Self.bar + Self.bar / 4)
    m.poll()
    #expect(m.stockPads.first?.state == .off && m.stockPads.first?.onRow == true)
    // and back in: the same clip, not a second one
    #expect(await m.stockPadClick(loop.path) == id)
    m.poll()
    #expect(m.clips.count == 1 && m.stockPads.first?.state != .off)
    let imports = rec.finish().events.compactMap { e -> DeckAction? in
      if case .action(let a) = e.kind, case .clipImport = a { return a }
      return nil
    }
    #expect(imports.count == 2, "each import is recorded")
    // an unknown pad does nothing
    #expect(await m.stockPadClick("/nope.caf") == nil)
  }

  /// The Stock page: the loops of the chosen category (a second click on it is All again)
  /// matching the search, nearest the decks' tempo first (half / double time count as near),
  /// at most `stockPadLimit` of them.
  @Test func theStockPageFiltersByCategoryAndTempo() throws {
    let (m, dj) = try stockModel()
    defer { dj.stop() }
    let tempo = try #require(m.stockPadTempo)
    #expect(abs(tempo - 120) < 0.5, "the playing deck's tempo (\(tempo))")
    func loop(_ name: String, _ category: String, bpm: Double) -> StockLoop {
      describedStockLoop(name, category: category, beats: 8, seconds: 8 * 60 / bpm)
    }
    let named = [
      loop("Beat 90", "Drums", bpm: 90), loop("Beat 120", "Drums", bpm: 120),
      loop("Beat 61", "Drums", bpm: 61), loop("Beat 140", "Drums", bpm: 140),
      loop("Bass 120", "Bass", bpm: 120), loop("Pad 100", "Synths", bpm: 100),
    ]
    let filler = (0..<40).map { loop("Filler \($0)", "Drums", bpm: 100) }
    m.stockLoops = named + filler
    #expect(m.stockPads.count == AppModel.stockPadLimit, "a page is at most 32 pads")
    #expect(m.stockPadMatches.count == named.count + filler.count)
    #expect(Array(m.stockPads.prefix(2).map(\.title)) == ["Bass 120", "Beat 120"])
    m.setStockPadCategory("Drums")
    #expect(m.stockPadCategory == "Drums")
    #expect(m.stockPads.allSatisfy { $0.category == "Drums" })
    #expect(
      Array(m.stockPads.prefix(3).map(\.title)) == ["Beat 120", "Beat 61", "Beat 140"],
      "nearest 120 first: 61 is 122 at double time")
    m.stockPadQuery = "beat"
    #expect(m.stockPads.map(\.title) == ["Beat 120", "Beat 61", "Beat 140", "Beat 90"])
    m.setStockPadCategory("Drums")
    #expect(m.stockPadCategory == "", "a second click is All again")
    #expect(m.stockPads.count == 4, "the search still applies")
    m.stockPadQuery = ""
    m.setStockPadCategory("Synths")
    #expect(m.stockPads.map(\.title) == ["Pad 100"])
  }

  /// The page switch is remembered across launches; the Row page is the default.
  @Test func theBoardsPageIsRemembered() throws {
    let defaults = scratchDefaults()
    let (m, dj) = try stockModel(defaults)
    #expect(m.soundboardPage == .row)
    m.stockLoops = [describedStockLoop("Beat", category: "Drums", beats: 4, seconds: 2)]
    m.setSoundboardPage(.stock)
    dj.stop()
    let (m2, dj2) = try stockModel(defaults)
    #expect(m2.soundboardPage == .stock)
    m2.setSoundboardPage(.crate)
    dj2.stop()
    let (m3, dj3) = try stockModel(defaults)
    defer { dj3.stop() }
    #expect(m3.soundboardPage == .crate)
  }

  /// The Stock page draws its pads (and the switch above them) at the window's minimum width.
  @Test func theStockPageDrawsItsPads() throws {
    let (m, dj) = try stockModel()
    defer { dj.stop() }
    m.stockLoops = (0..<5).map {
      describedStockLoop("Beat \($0)", category: $0 < 3 ? "Drums" : "Bass", beats: 4, seconds: 2)
    }
    m.setSoundboardPage(.stock)
    let width = 720 - 2 * 16 - 2 * Int(DJStyle.cardPadding)
    let view = SoundboardView(model: m).frame(width: CGFloat(width)).padding(0)
      .background(Color.black).environment(\.colorScheme, .dark)
    let grid = SoundboardLayout.size(count: 5, width: CGFloat(width))
    let height = Int(grid.height) + 120
    savePNG(view, width: width, height: height, name: "soundboard-stock")
    let px = try #require(renderPixels(view, width: width, height: height))
    let violet = px.count(inX: 0..<width, y: (height - Int(grid.height))..<height) { r, g, b in
      b > 150 && r > 90 && g < r
    }
    #expect(violet > 100, "the pads' outlines (\(violet) pixels)")
  }

  @Test func anEmptyBoardSaysHowToMakeLoops() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    try dj.start()
    defer { dj.stop() }
    let m = AppModel(engine: dj)
    m.defaults = scratchDefaults()
    m.start()
    #expect(m.soundPads.isEmpty)
    let view = SoundboardView(model: m).frame(width: 660).background(Color.black)
      .environment(\.colorScheme, .dark)
    let px = try #require(renderPixels(view, width: 660, height: 160))
    let text = px.count(inX: 0..<660, y: 0..<160) { r, g, b in r > 120 && g > 120 && b > 120 }
    #expect(text > 400, "the header and the how-to are drawn (\(text) pixels)")
  }

  @Test func theWindowShowsTheBoardAndTheSocketTogglesIt() async throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    #expect(!m.showSoundboard)
    let on = try await m.control("view", try JSONValue.parse(#"{"soundboard":true}"#))
    #expect(on["soundboard"]?.bool == true && m.showSoundboard)
    #expect(m.controlState()["view"]?["soundboard"]?.bool == true)
    m.toggleSoundboard()
    #expect(!m.showSoundboard)
    let off = try await m.control("view", try JSONValue.parse("{}"))
    #expect(off["soundboard"]?.bool == false, "left out: as it was")
  }

  /// The board's open state is kept in the app's defaults: every path (the window's toggle, the
  /// View menu, the socket's `view`) saves it, and the next launch opens as the last one left it.
  @Test func theBoardsOpenStateIsRemembered() async throws {
    let defaults = scratchDefaults()
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: Self.rate)
    try dj.start()
    defer { dj.stop() }
    let fresh = AppModel(engine: dj)
    fresh.defaults = defaults
    fresh.start()
    #expect(!fresh.showSoundboard, "a fresh suite starts closed")
    fresh.setShowSoundboard(true)
    #expect(defaults.bool(forKey: AppModel.showSoundboardKey))
    let next = AppModel(engine: dj)
    next.defaults = defaults
    next.start()
    #expect(next.showSoundboard, "the next launch opens it")
    next.toggleSoundboard()
    #expect(!next.showSoundboard && !defaults.bool(forKey: AppModel.showSoundboardKey))
    _ = try await next.control("view", try JSONValue.parse(#"{"soundboard":true}"#))
    #expect(defaults.bool(forKey: AppModel.showSoundboardKey), "the socket's view saves it too")
    let third = AppModel(engine: dj)
    third.defaults = defaults
    third.start()
    #expect(third.showSoundboard)
  }

  @Test func returnAndSpaceActivateTheHoveredList() {
    let keys = HoverKeys()
    var stepped = 0
    var activated = 0
    let a = newListID()
    keys.enter(a, step: { stepped += $0 }, activate: { activated += 1 })
    #expect(keys.handle(keyDown(36)) && activated == 1, "Return")
    #expect(keys.handle(keyDown(49)) && activated == 2, "Space")
    #expect(!keys.handle(keyDown(36, commandKey)), "⌘Return is not ours")
    #expect(keys.handle(keyDown(124)) && stepped == 1, "the arrows still step")
    let b = newListID()
    keys.enter(b) { stepped += $0 }
    #expect(!keys.handle(keyDown(36)), "a list without activate lets Return through")
  }
}

/// Pictures for a human: the window with the Soundboard open, and a pad's settings, drawn in
/// an offscreen window (real controls). `make swift-shots SHOT_DIR=… FILTER=SoundboardShots`.
@MainActor
struct SoundboardShots {
  @Test func theWindowWithTheSoundboardOpen() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.pads(6)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    m.setClipColor(ids[1], "teal")
    m.setClipColor(ids[2], "orange")
    m.setClipColor(ids[4], "pink")
    m.renameClip(ids[0], "drums 1")
    m.renameClip(ids[1], "drums ×2")
    m.saveScene()
    m.soundboard(.toggle, ids[2])  // coming in
    m.soundboard(.toggle, ids[0])  // going out
    m.soundboard(.solo(true), ids[3])
    m.setShowSoundboard(true)
    m.poll()
    #expect(m.soundPads.count == 6 && m.scenes.count == 1)
    let window = ZStack {
      Color(white: 0.1)
      ContentView(model: m)
    }
    saveWindowPNG(window, width: 1440, height: 900, name: "soundboard-window")
    saveWindowPNG(
      ClipSettingsView(id: .constant(ids[0]), model: m).background(Color(white: 0.12)),
      width: 400, height: 900, name: "soundboard-settings")
  }
}
