import Foundation

// Where each control sits on the real hardware, for the Controllers view: a drawing of every
// attached device with each control labelled by what it is bound to. Geometry is in "units"
// (about one APC pad), origin top-left; positions follow the panels (APC: Akai's grid with the
// track row below and the scene column right; MPK: joystick, 2×4 pads, 2×4 knobs over 25 keys;
// Inpulse: deck A, the mixer, deck B). A spot carries every binding the control has, one per
// mode (an Inpulse pad is a hot cue, a loop, an FX…, depending on the pad mode).

/// One physical control.
public struct ControlSpot: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case pad, button, knob, fader, jog, joystick, keyboard, encoder
  }
  public var kind: Kind
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double
  /// The profile controls this one physical control is: (group, index, mode label). The first
  /// is the one the drawing labels; the others show in its help.
  public var bindings: [(group: String, index: Int, mode: String?)]
  /// Printed on the panel (drawn small, above the binding).
  public var caption: String?

  public init(
    _ kind: Kind, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
    _ bindings: [(group: String, index: Int, mode: String?)], caption: String? = nil
  ) {
    self.kind = kind
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.bindings = bindings
    self.caption = caption
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.kind == b.kind && a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h
      && a.caption == b.caption
      && a.bindings.map { "\($0.group)/\($0.index)/\($0.mode ?? "")" }
        == b.bindings.map { "\($0.group)/\($0.index)/\($0.mode ?? "")" }
  }
}

/// A device drawn as it looks.
public struct ControllerLayout: Equatable, Sendable {
  /// The surface profile's name (what `ControllerHub.Device.profile` reports).
  public var profileName: String
  /// A short name for the card.
  public var title: String
  public var width: Double
  public var height: Double
  public var spots: [ControlSpot]

  /// The devices the app knows, in the order the Controllers view shows them.
  public static var all: [ControllerLayout] { [apcMiniMK2, mpkMiniMK2, inpulse200MK3] }

  public static func layout(for profileName: String) -> ControllerLayout? {
    all.first { $0.profileName == profileName }
  }

  // MARK: APC mini mk2

  /// 8×8 grid (pad 0 bottom-left, +1 right, +8 up), 8 track buttons below, 8 scene buttons
  /// right (top to bottom), SHIFT under the scene column, 9 faders along the bottom.
  public static let apcMiniMK2: ControllerLayout = {
    var s: [ControlSpot] = []
    for i in 0..<64 {
      s.append(ControlSpot(.pad, Double(i % 8), Double(7 - i / 8), 0.92, 0.92, [("pads", i, nil)]))
    }
    for i in 0..<8 {
      s.append(ControlSpot(.button, Double(i), 8.15, 0.92, 0.5, [("track", i, nil)]))
      s.append(ControlSpot(.button, 8.25, Double(i) + 0.1, 0.72, 0.72, [("scene", i, nil)]))
    }
    s.append(ControlSpot(.button, 8.25, 8.15, 0.72, 0.5, [("shift", 0, nil)], caption: "SHIFT"))
    for i in 0..<9 {
      s.append(
        ControlSpot(
          .fader, i == 8 ? 8.35 : Double(i) + 0.2, 8.95, 0.52, 2.6, [("faders", i, nil)]))
    }
    return ControllerLayout(
      profileName: SurfaceProfile.apcMiniMK2.name, title: "APC mini mk2", width: 9.05,
      height: 11.6, spots: s)
  }()

  // MARK: MPK mini mk2

  /// Joystick top-left, 8 pads (5-8 over 1-4) in the middle, 8 knobs (1-4 over 5-8) right,
  /// 25 keys below. A pad is a program change, a bank A note or a bank B note, by pad mode.
  public static let mpkMiniMK2: ControllerLayout = {
    var s: [ControlSpot] = [
      ControlSpot(.joystick, 0.2, 0.3, 1.7, 1.7, [("joystickX", 0, nil)], caption: "joystick")
    ]
    for n in 0..<8 {
      let col = Double(n % 4)
      let row = n < 4 ? 1.35 : 0.2  // pads 1-4 are the bottom row
      s.append(
        ControlSpot(
          .pad, 2.3 + col * 1.25, row, 1.12, 1.05,
          [("pads", n, "PROG"), ("padNotes", n, "NOTE A"), ("padNotes", n + 8, "NOTE B")],
          caption: "pad \(n + 1)"))
    }
    for k in 0..<8 {
      let col = Double(k % 4)
      let row = k < 4 ? 0.25 : 1.35
      s.append(
        ControlSpot(
          .knob, 7.6 + col * 1.05, row, 0.9, 0.9, [("knobs", k, nil)], caption: "K\(k + 1)"))
    }
    s.append(ControlSpot(.keyboard, 0.2, 2.75, 11.6, 2.1, [("keys", 60, nil)], caption: "keys"))
    return ControllerLayout(
      profileName: SurfaceProfile.mpkMiniMK2.name, title: "MPK mini mk2", width: 12.0,
      height: 5.05, spots: s)
  }()

  // MARK: Inpulse 200 MK3

  /// Deck A, the mixer, deck B. A deck: the jog, its pitch fader, the LOOP / STEMS / pad-mode
  /// buttons, four pads (numbered down the columns: pad 1 = index 0, the one under it index 1),
  /// SHIFT / SYNC / CUE / PLAY. The mixer: each deck's EQ and filter knobs, volume fader and
  /// headphone cue, the browser and LOAD buttons, master / headphones and the crossfader.
  public static let inpulse200MK3: ControllerLayout = {
    var s: [ControlSpot] = []
    for (deck, x0, strip) in [("A", 0.0, 5.0), ("B", 10.6, 9.1)] {
      let b = "deck\(deck).buttons"
      let sb = "deck\(deck).shiftButtons"
      let f = "deck\(deck).faders"
      // buttons index: loop 0, shift 1, sync 2, cue 3, play 4, stemsMusic 5, stemsMic 6, pfl 7,
      // load 8, hotCueMode 9, fxMode 10, loopPadMode 11, loopPadModeHeld 12
      s.append(
        ControlSpot(.jog, x0 + 0.3, 0.3, 3.9, 3.9, [], caption: "jog: scratch · bend · SHIFT seek"))
      let pitchX = deck == "A" ? x0 + 4.35 : x0 - 0.5
      s.append(ControlSpot(.fader, pitchX, 0.4, 0.42, 3.6, [(f, 5, nil)], caption: "pitch"))
      // SHIFT + STEMS are Mixxx's loop in / out (0x09 / 0x0A on the shift channel); SHIFT +
      // HOT CUE selects LOOP pad mode (0x11, with 0x40 while it is held)
      let top: [(Int, String, [(String, Int, String)])] = [
        (0, "LOOP", [(sb, 5, "SHIFT")]), (5, "♪ STEMS", [(sb, 3, "SHIFT")]),
        (6, "🎤 STEMS", [(sb, 4, "SHIFT")]),
        (9, "HOT CUE", [(b, 11, "SHIFT"), (b, 12, "SHIFT, held")]), (10, "FX", []),
      ]
      for (k, item) in top.enumerated() {
        var bs: [(group: String, index: Int, mode: String?)] = [(b, item.0, nil)]
        for sh in item.2 { bs.append((sh.0, sh.1, sh.2)) }
        s.append(
          ControlSpot(.button, x0 + 0.15 + Double(k) * 0.85, 4.45, 0.78, 0.5, bs, caption: item.1))
      }
      for i in 0..<4 {
        let col = Double(i / 2)
        let row = Double(i % 2)
        let p = "deck\(deck)"
        s.append(
          ControlSpot(
            .pad, x0 + 0.6 + col * 1.6, 5.15 + row * 1.15, 1.45, 1.0,
            [
              ("\(p).hotcuePads", i, "HOT CUE"), ("\(p).loopPads", i, "LOOP"),
              ("\(p).rollPads", i, "FX"), ("\(p).samplerPads", i, "SAMPLER"),
              ("\(p).hotcueClearPads", i, "SHIFT+HOT CUE"), ("\(p).fxPads", i, "FX (old 200)"),
            ]))
      }
      let bottom: [(Int, String, Int?)] = [
        (1, "SHIFT", nil), (2, "SYNC", 0), (3, "CUE", 1), (4, "PLAY", 2),
      ]
      for (k, item) in bottom.enumerated() {
        var bs: [(group: String, index: Int, mode: String?)] = [(b, item.0, nil)]
        if let sh = item.2 { bs.append((sb, sh, "SHIFT")) }
        s.append(
          ControlSpot(
            item.0 == 4 || item.0 == 3 ? .pad : .button, x0 + 0.15 + Double(k) * 1.05, 7.6,
            0.9, 0.75, bs, caption: item.1))
      }
      // the mixer strip: high (gain on SHIFT), mid, low, filter, the volume fader, PFL
      let knobs: [(Int, String)] = [(4, "HIGH"), (3, "MID"), (2, "LOW"), (1, "FILTER")]
      for (k, item) in knobs.enumerated() {
        var bs: [(group: String, index: Int, mode: String?)] = [(f, item.0, nil)]
        if item.0 == 4 { bs.append(("deck\(deck).shiftFaders", 0, "SHIFT")) }
        s.append(ControlSpot(.knob, strip, 0.35 + Double(k) * 1.0, 0.8, 0.8, bs, caption: item.1))
      }
      s.append(ControlSpot(.fader, strip + 0.2, 4.4, 0.42, 2.7, [(f, 0, nil)], caption: "vol"))
      s.append(ControlSpot(.button, strip, 7.3, 0.8, 0.45, [(b, 7, nil)], caption: "🎧"))
      s.append(ControlSpot(.button, strip, 7.9, 0.8, 0.45, [(b, 8, nil)], caption: "LOAD"))
    }
    s.append(
      ControlSpot(
        .encoder, 6.9, 0.35, 1.1, 1.1,
        [
          ("mixer.browser", 0, nil), ("mixer.buttons", 0, "push"),
          ("mixer.shiftBrowser", 0, "SHIFT"),
          ("mixer.shiftButtons", 0, "SHIFT + push"),
        ],
        caption: "browser"))
    s.append(ControlSpot(.knob, 6.3, 1.75, 0.8, 0.8, [("mixer.faders", 1, nil)], caption: "master"))
    s.append(ControlSpot(.knob, 7.8, 1.75, 0.8, 0.8, [("mixer.faders", 2, nil)], caption: "phones"))
    for c in 0..<3 {
      s.append(
        ControlSpot(
          .button, 6.25 + Double(c) * 0.8, 3.0, 0.7, 0.45, [("mixer.buttons", c + 1, nil)],
          caption: ["ASSIST", "MASTER", "GUIDE"][c]))
    }
    s.append(
      ControlSpot(.fader, 6.2, 7.75, 2.5, 0.42, [("mixer.faders", 0, nil)], caption: "crossfader"))
    return ControllerLayout(
      profileName: SurfaceProfile.inpulse200MK3.name, title: "Inpulse 200 MK3", width: 15.1,
      height: 8.55, spots: s)
  }()

  public static func == (a: Self, b: Self) -> Bool {
    a.profileName == b.profileName && a.spots == b.spots
  }
}

extension SurfaceProfile {
  /// Is this control's binding (or its group) not yet seen on a real unit (`[MIXXX]` /
  /// `[UNVERIFIED]` in the group's comment or the binding's reason)?
  public func isUnverified(group: String, index: Int) -> Bool {
    func marked(_ s: String?) -> Bool {
      guard let s else { return false }
      return s.contains("[MIXXX]") || s.contains("[UNVERIFIED]")
    }
    let b = layout.first { $0.group == group && ($0.index == index || $0.index == nil) }
    return marked(b?.reason) || marked(self.group(group)?.comment)
  }
}
