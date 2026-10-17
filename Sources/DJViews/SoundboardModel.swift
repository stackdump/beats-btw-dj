import AppKit
import DJCore
import SwiftUI

// The soundboard: every loop on the row as one big pad. A pad is a simpler view of the same
// clip the Loops row shows (`ClipState`), and everything it does goes through the same
// `DeckAction`s, so launch quantize, the countdown, fades, mute and solo, tempo follow, sessions
// and the journal all treat a pad press exactly as a tile's ▶/■ or a controller's loop pad.

/// One pad: just what a performer reads at a glance.
struct SoundPad: Equatable, Identifiable {
  var id: String
  var title: String
  /// Its colour (`LoopClip.palette`), nil for the loops' violet.
  var color: String?
  /// "2 bars", "6 beats".
  var lengthLabel: String
  var beats: Int
  var bpm: Double
  /// Off, coming in, looping, going out (under the mixer).
  var state: DJEngine.LoopState
  /// How the controllers' LEDs show that state (`SoundPad.light`).
  var light: PadLight.Level
  /// How far through its loop it is (0…1), while it sounds.
  var phase: Double?
  /// While it waits for its boundary: how long until it switches.
  var countdown: LoopCountdown?
  var muted: Bool
  var soloed: Bool
  var keyLock: Bool
  /// The deck (A/B) holding it, when it has been moved onto one.
  var onDeck: String?
  /// The Inpulse pad that switches it in LOOP pad mode ("A1"…"B4"), if it has one.
  var slot: String?
  var isSequence: Bool
  var overview: WaveformOverview

  init(_ c: ClipState, slot: String?) {
    id = c.id
    title = c.title
    color = c.color
    lengthLabel = c.lengthLabel
    beats = c.beats
    bpm = c.bpm
    state = c.loop
    light = Self.light(c.loop)
    phase = c.playhead
    countdown = c.countdown
    muted = c.muted
    soloed = c.soloed
    keyLock = c.keyLock
    onDeck = c.onDeck
    self.slot = slot
    isSequence = c.steps != nil
    overview = c.overview
  }

  /// A loop pad's LED, as the APC's loop page and the Inpulse's LOOP pads light it
  /// (`SurfaceController.clipState` / `singleState`): full while it plays, blinking on its way
  /// in or out, dark when off.
  static func light(_ s: DJEngine.LoopState) -> PadLight.Level {
    switch s {
    case .on: .full
    case .starting, .stopping: .blink
    case .off: .off
    }
  }

  /// Is it heard (or about to be) under the mixer: on, or still on until its boundary.
  var sounding: Bool { state == .on || state == .stopping }
  var pending: Bool { state == .starting || state == .stopping }

  /// "off", "in 3", "on", "out 2".
  var stateLabel: String {
    switch state {
    case .off: "off"
    case .on: "on"
    case .starting: countdown.map { $0.label } ?? "in"
    case .stopping: countdown.map { "out " + $0.label.dropFirst(3) } ?? "out"
    }
  }
}

/// What a pad (its click, its right-click menu, the arrow-key focus' Return) can do to its clip.
/// Each is one of the Loops row's own `DeckAction`s (`AppModel.soundboardAction`).
enum SoundPadCommand: Equatable {
  /// In on the next launch boundary, or out on it (a tile's ▶/■).
  case toggle
  case mute(Bool)
  case solo(Bool)
  case keyLock(Bool)
  case color(String?)
  case rename(String)
  /// How every loop comes in and goes out (the loop channel's, not this clip's alone).
  case fade(LoopFade)
  /// Onto deck A or B ("A", "B"), or back under the mixer ("L").
  case move(String)
  /// Off the row, with Undo (`AppModel.removeClip`).
  case remove
}

/// How the pads are laid out for `count` pads in `width` points: as many columns as fit at the
/// smallest pad size (never more than there are pads), each pad as wide as the columns leave,
/// up to the largest size.
enum SoundboardLayout {
  static let minPad: CGFloat = 132
  static let maxPad: CGFloat = 220
  static let spacing: CGFloat = DJStyle.s
  /// Height over width.
  static let aspect: CGFloat = 0.72

  static func columns(count: Int, width: CGFloat) -> Int {
    guard count > 0 else { return 0 }
    let fit = Int(((width + spacing) / (minPad + spacing)).rounded(.down))
    return max(1, min(count, fit))
  }

  static func padWidth(count: Int, width: CGFloat) -> CGFloat {
    let cols = columns(count: count, width: width)
    guard cols > 0 else { return 0 }
    let w = (width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
    return max(1, min(maxPad, w.rounded(.down)))
  }

  static func rows(count: Int, width: CGFloat) -> Int {
    let cols = columns(count: count, width: width)
    return cols == 0 ? 0 : (count + cols - 1) / cols
  }

  /// The grid's size for `count` pads in `width`.
  static func size(count: Int, width: CGFloat) -> CGSize {
    let cols = columns(count: count, width: width)
    guard cols > 0 else { return .zero }
    let w = padWidth(count: count, width: width)
    let r = rows(count: count, width: width)
    return CGSize(
      width: CGFloat(cols) * w + CGFloat(cols - 1) * spacing,
      height: CGFloat(r) * (w * aspect).rounded() + CGFloat(r - 1) * spacing)
  }
}

/// The pads' grid: `SoundboardLayout` worked out from the width it is offered, in one layout
/// pass (so it adapts to the window as it resizes, and draws offscreen too).
struct SoundboardGrid: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 660
    let s = SoundboardLayout.size(count: subviews.count, width: width)
    return CGSize(width: max(s.width, proposal.width ?? s.width), height: s.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let n = subviews.count
    let cols = SoundboardLayout.columns(count: n, width: bounds.width)
    guard cols > 0 else { return }
    let w = SoundboardLayout.padWidth(count: n, width: bounds.width)
    let h = (w * SoundboardLayout.aspect).rounded()
    let gap = SoundboardLayout.spacing
    for (i, v) in subviews.enumerated() {
      let x = bounds.minX + CGFloat(i % cols) * (w + gap)
      let y = bounds.minY + CGFloat(i / cols) * (h + gap)
      v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: h))
    }
  }
}

extension AppModel {
  /// One pad per clip on the row, in row order (the Inpulse's loop pads follow the same order).
  var soundPads: [SoundPad] { clips.map { SoundPad($0, slot: padSlot($0.id)) } }

  /// The window's Soundboard toggle, its View menu item and the control socket's `view`.
  func setShowSoundboard(_ on: Bool) { showSoundboard = on }
  public func toggleSoundboard() { showSoundboard.toggle() }

  /// A pad's click: ⌥ solos it (or unsolos), ⇧ mutes it (or unmutes), a plain click brings it in
  /// or out on the next launch boundary.
  func padClick(_ id: String, option: Bool = false, shift: Bool = false) {
    guard let c = clips.first(where: { $0.id == id }) else { return }
    soundboard(option ? .solo(!c.soloed) : shift ? .mute(!c.muted) : .toggle, id)
  }

  /// The `DeckAction` a pad command performs: the Loops row's own (`toggleLoop`,
  /// `setClipMute`, …), worked out from the engine as it is now. Nil for an unknown clip, or for
  /// a rename to nothing.
  func soundboardAction(_ c: SoundPadCommand, _ id: String) -> DeckAction? {
    guard let dj = engine, dj.clip(id) != nil else { return nil }
    switch c {
    case .toggle:
      let s = dj.loopState(id)
      return .clipLoop(id: id, on: s == .off || s == .stopping)
    case .mute(let on): return .clipMute(id: id, on: on)
    case .solo(let on): return .clipSolo(id: id, on: on)
    case .keyLock(let on): return .clipKeyLock(id: id, on: on)
    case .color(let name): return .clipColor(id: id, color: name)
    case .rename(let t):
      let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : .clipRename(id: id, title: t)
    case .fade(let f): return .loopFade(mode: f.rawValue)
    case .move(let deck): return .clip(deck: deck, id: id)
    case .remove: return .clipRemove(id: id)
    }
  }

  /// Do a pad command. Removal and renaming go through the row's own model calls (Undo, and
  /// the trimmed, unchanged-name-skipping rename); everything else is `perform`ed as is.
  func soundboard(_ c: SoundPadCommand, _ id: String) {
    switch c {
    case .remove: removeClip(id)
    case .rename(let t): renameClip(id, t)
    default:
      guard let dj = engine, let a = soundboardAction(c, id) else { return }
      dj.perform(a)
      pollLoops(dj)
    }
  }

  /// The decks playing the track clip `id` was taken from now (by the favorite's CID of its
  /// source), whose instruments its settings can open for tuning. Empty for a sample's loop.
  func decksPlayingOrigin(_ id: String) -> [String] {
    guard let cid = originCID(id) else { return [] }
    return decks.keys.sorted().filter { decks[$0]?.sourceCID == cid }
  }

  /// The favorite CID of the net clip `id` was taken from (nil for a sample, a sequence's
  /// sample steps, or no record).
  func originCID(_ id: String) -> String? {
    guard let source = engine?.clip(id)?.originSource else { return nil }
    switch source {
    case .net, .rawNets: return source.favoriteCID
    default: return nil
    }
  }

  /// The control socket's `view`: show or hide the window's panels (`soundboard`,
  /// `controllers`, `map`, `scopes`, `pads`); returns what shows now.
  func controlView(_ p: JSONValue) -> JSONValue {
    if let on = p["soundboard"]?.bool { setShowSoundboard(on) }
    if let on = p["controllers"]?.bool { showControllers = on }
    if let on = p["map"]?.bool { showMap = on }
    if let on = p["scopes"]?.bool { showScopes = on }
    if let on = p["pads"]?.bool { setShowPads(on) }
    poll()
    return viewJSON
  }

  var viewJSON: JSONValue {
    .object(
      JSONObject([
        ("soundboard", .bool(showSoundboard)), ("controllers", .bool(showControllers)),
        ("map", .bool(showMap)), ("scopes", .bool(showScopes)), ("pads", .bool(showPads)),
      ]))
  }
}
