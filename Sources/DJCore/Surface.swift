import Foundation

/// What a control on a surface does. Continuous actions take the control's
/// value (0...1); momentary ones fire on press. `unbound` parks a control on
/// purpose (with a `reason`) so nothing is ever dropped silently.
public enum DJActionKind: String, Codable, Sendable, CaseIterable {
  case volume  // continuous, per deck
  case filter  // continuous, per deck: < 0.5 low-pass, > 0.5 high-pass
  case pitch  // continuous, per deck: ±8 %
  case gain  // continuous, per deck: trim, 0.5 = unity, 1 = +6 dB
  case eqLow, eqMid, eqHigh  // continuous, per deck: 0.5 = flat, 0 = kill, 1 = +6 dB
  case crossfader  // continuous: 0 = A, 1 = B
  case master  // continuous
  case headphoneMix  // continuous: 0 = cue only … 1 = master only in the headphones
  case headphoneLevel  // continuous
  case pfl  // press: toggle this deck's headphone cue
  case play  // press: toggle the deck's transport
  case cue  // press: playing → back to cue point and pause; paused → set cue point here
  case hotcue  // press: jump to slot, or set it if empty
  case clearcue  // press: forget slot
  case loopIn  // press: loop start at the playhead
  case loopOut  // press: loop end at the playhead and start looping; again: exit loop
  case loopHalve, loopDouble  // press: resize the active loop
  case loopRecord  // hold: take this deck's bars; release: they loop as a clip under the mixer
  case clipToggle  // press: loop number `slot` (0-based, row order) in or out on the next downbeat
  case shift  // hold: software shift layer for this surface
  // Live-net performance (net decks; ignored on sample decks)
  case section  // press: launch section `slot` of the song (at the next bar)
  case sectionPrev, sectionNext  // press: step the section launcher
  case roleMute  // press: toggle `role` (kick, bass, …) on/off
  case stemMute  // press: toggle the role group `role` names ("music" = not drums, "mic" = lead)
  case macro  // press: fire the catalog macro named by `macro` (net or master chain)
  case panic  // press: restore every macro effect now
  case stinger  // press: ring stinger `slot` (0–3) for a bar
  case nextTrack  // press: hand over to the pre-composed next track
  case sync  // press: match tempo + phase to the other deck (`slot` 0 = beat, 1 = bar)
  case quantize  // press: cycle cue/loop snapping off → beat → bar
  case rewind  // press: back to the start
  case keys  // note-on/off: play the live voice, scale-locked (focus deck)
  case nudge  // continuous, centred: momentary tempo nudge (focus deck)
  case seedStep  // relative: the playing net's seed +/- each click, recomposed; grabs wander
  // The aimed deck: a binding with deck "*" acts on `DJEngine.focus` (the APC as an FX surface)
  case masterFx  // continuous: master-chain FX slider `macro` (lp-freq, hp-freq, crush-bits…)
  case reverbWet, reverbSize  // continuous, per deck: the channel's reverb
  case fxUnit  // continuous: FX unit control `param` (an `FxParam` id) on its own travel
  case fxKill  // press: the FX unit's kill on / off, on the next beat
  case fxReset  // press: every FX unit control to neutral and the kill off, on the next beat
  case focusDeck  // press: aim the deck-less ("*") bindings at deck A (`slot` 0) or B (1)
  case regenerate  // press: the deck's next version (new seed, same song settings), at the bar
  case autoNext  // press: toggle the deck's auto-next
  case wander  // press: wander on/off (focus deck)
  case wanderPace  // relative: wander's pace 4 → 8 → 16 → 32 bars and back (focus deck)
  case unbound  // parked on purpose; see `reason`
}

/// A button/knob surface: pads, faders, keys, jog-wheel decks' buttons —
/// anything that is note/CC/pitch-bend. Loaded from
/// `Resources/profiles/<id>.json`, like `JogProfile`.
public struct SurfaceProfile: Codable, Sendable {
  public enum ControlType: String, Codable, Sendable {
    case note  // note on/off (velocity 0 = release)
    case cc  // 7-bit absolute
    case cc14  // 14-bit absolute: MSB on CC n, LSB on CC n+32
    case relative  // 7-bit two's-complement increments (0x01 = +1, 0x7F = -1)
    case pitchbend  // 0xEn, 14-bit; one control per channel
    case program  // 0xCn program change (e.g. MPK pads in PROG CHANGE mode)
  }

  /// A run of controls of one type on one channel. Either contiguous
  /// (`first ..< first + count`) or an explicit `numbers` list.
  public struct Group: Codable, Sendable {
    public var id: String
    public var type: ControlType
    public var first: UInt8?
    public var count: UInt8?
    public var numbers: [UInt8]?
    /// Per-index names, for monitors and docs ("play", "cue", …).
    public var names: [String]?
    /// 0-based MIDI channel, or nil for any.
    public var channel: UInt8?
    public var comment: String?

    /// MIDI note/CC numbers of the group's controls, by index.
    public var controlNumbers: [UInt8] {
      if let numbers { return numbers }
      guard let first, let count else { return [] }
      return (0..<count).map { first + $0 }
    }

    public func name(_ index: Int) -> String? {
      guard let names, names.indices.contains(index) else { return nil }
      return names[index]
    }
  }

  public struct Binding: Codable, Sendable, Hashable {
    public var group: String
    /// Control index within the group, or nil for every control in it.
    public var index: Int?
    public var action: DJActionKind
    public var deck: String?
    public var slot: Int?
    /// Only while this surface's shift is held (true), only while it is not
    /// (false), or regardless (nil).
    public var shift: Bool?
    /// Why a control is `unbound` (e.g. "needs BPM — Phase 3").
    public var reason: String?
    /// `roleMute`: the role name ("kick", "bass", …).
    public var role: String?
    /// `macro`: the net macro id ("drop", "beat-repeat", …).
    public var macro: String?
    /// `fxUnit`: the FX unit control (`FxParam` id: "filter", "hp", "room", …).
    public var param: String?
  }

  /// Note-on LED feedback (APC, Inpulse): note-on to the control's own
  /// channel and number lights it.
  public struct LEDs: Codable, Sendable {
    public var rgbGroups: [String]
    public var singleGroups: [String]
    public var rgbDimStatus: UInt8
    public var rgbFullStatus: UInt8
    /// Status byte that blinks an RGB pad (APC: 0x9E, 1/4 note), or nil when the surface has
    /// none: then a pad that would blink shows dim.
    public var rgbBlinkStatus: UInt8?
    public var singleOff: UInt8
    public var singleOn: UInt8
    public var singleBlink: UInt8
    /// Where the status bytes come from, and which are not yet seen on a unit.
    public var comment: String?
  }

  public var name: String
  public var manufacturer: String
  public var match: String
  public var matchComment: String?
  public var source: String?
  /// Id of a `JogProfile` for devices with jog wheels on the same port.
  public var jog: String?
  public var groups: [Group]
  public var leds: LEDs?
  public var layout: [Binding]

  public func matches(portName: String) -> Bool {
    portName.range(of: match, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Stateless decode (7-bit view; a cc14 LSB on its own decodes to nil).
  /// Use `SurfaceDecoder` for full 14-bit resolution.
  public func parse(_ data: [UInt8]) -> ControlEvent? {
    var d = SurfaceDecoder(profile: self)
    return d.decode(data)
  }

  public func group(_ id: String) -> Group? { groups.first { $0.id == id } }

  /// The note/CC number for a control, for LED output.
  public func number(group id: String, index: Int) -> UInt8? {
    guard let nums = group(id)?.controlNumbers, nums.indices.contains(index) else { return nil }
    return nums[index]
  }

  public static func load(_ id: String) throws -> SurfaceProfile {
    try JSONDecoder().decode(SurfaceProfile.self, from: Data(contentsOf: profileURL(id)))
  }

  private static func bundled(_ id: String) -> SurfaceProfile {
    do { return try load(id) } catch { fatalError("bundled profile \(id): \(error)") }
  }

  public static let apcMiniMK2 = bundled("apc-mini-mk2")
  public static let mpkMiniMK2 = bundled("mpk-mini-mk2")
  public static let inpulse200MK3 = bundled("inpulse-200-mk3-surface")

  public static var all: [SurfaceProfile] { [apcMiniMK2, mpkMiniMK2, inpulse200MK3] }
}

public struct ControlEvent: Equatable, Sendable {
  public var group: String
  public var index: Int
  /// 0...1 for absolute controls (7- or 14-bit), 0 for relative.
  public var value: Double
  /// Note-on with velocity > 0, or a CC / bend value > 0.
  public var pressed: Bool
  public var isCC: Bool
  /// Signed increments for `relative` controls, else 0.
  public var delta: Int = 0
  /// Control name from the profile, if it has one.
  public var name: String? = nil
}

/// Decodes one port's messages against a profile. Stateful only for 14-bit
/// controls: the MSB is remembered so the LSB can refine it.
public struct SurfaceDecoder: Sendable {
  public let profile: SurfaceProfile
  private var msb: [UInt16: UInt8] = [:]  // channel<<8 | cc → last MSB

  public init(profile: SurfaceProfile) { self.profile = profile }

  public mutating func decode(_ data: [UInt8]) -> ControlEvent? {
    guard data.count >= 3 else { return nil }
    let status = data[0] & 0xF0
    let ch = data[0] & 0x0F
    let (d1, d2) = (data[1], data[2])

    func event(
      _ g: SurfaceProfile.Group, _ i: Int, value: Double, pressed: Bool, cc: Bool, delta: Int = 0
    )
      -> ControlEvent
    {
      ControlEvent(
        group: g.id, index: i, value: value, pressed: pressed, isCC: cc, delta: delta,
        name: g.name(i))
    }

    for g in profile.groups where g.channel == nil || g.channel == ch {
      switch (status, g.type) {
      case (0x90, .note), (0x80, .note):
        if let i = g.controlNumbers.firstIndex(of: d1) {
          return event(g, i, value: Double(d2) / 127, pressed: status == 0x90 && d2 > 0, cc: false)
        }
      case (0xB0, .cc):
        if let i = g.controlNumbers.firstIndex(of: d1) {
          return event(g, i, value: Double(d2) / 127, pressed: d2 > 0, cc: true)
        }
      case (0xB0, .relative):
        if let i = g.controlNumbers.firstIndex(of: d1) {
          let delta = d2 < 0x40 ? Int(d2) : Int(d2) - 0x80
          return event(g, i, value: 0, pressed: delta != 0, cc: true, delta: delta)
        }
      case (0xB0, .cc14):
        let key = UInt16(ch) << 8
        if let i = g.controlNumbers.firstIndex(of: d1) {
          msb[key | UInt16(d1)] = d2
          let v = Double(UInt16(d2) << 7) / 16383
          return event(g, i, value: min(1, v), pressed: d2 > 0, cc: true)
        }
        if d1 >= 32, let i = g.controlNumbers.firstIndex(of: d1 - 32) {
          let hi = msb[key | UInt16(d1 - 32)] ?? 0
          let v = Double(UInt16(hi) << 7 | UInt16(d2)) / 16383
          return event(g, i, value: v, pressed: v > 0, cc: true)
        }
      case (0xC0, .program):
        if let i = g.controlNumbers.firstIndex(of: d1) {
          return event(g, i, value: 1, pressed: true, cc: false)
        }
      case (0xE0, .pitchbend):
        let v = Double(UInt16(d2) << 7 | UInt16(d1)) / 16383
        return event(g, 0, value: v, pressed: v != 0.5, cc: true)
      default: break
      }
    }
    return nil
  }
}

/// Where profile JSON lives: the .app's Resources first, then SwiftPM's bundle.
func profileURL(_ id: String) throws -> URL {
  // In DJApp.app the profiles sit in Contents/Resources/profiles (see scripts/bundle-app.sh):
  // SwiftPM's Bundle.module only looks at the .app root, where codesign rejects a bundle.
  // Under `swift run` / `swift test`, Bundle.module finds them in .build.
  let url =
    Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "profiles")
    ?? Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "profiles")
  guard let url else {
    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "profiles/\(id).json"])
  }
  return url
}

extension SurfaceProfile.Binding {
  /// The action this binding fires, as the lock list names it: "<deck>.<action>[.<param>]"
  /// ("A.panic", "B.hotcue.2", "A.macro.drop", "-.crossfader"). The same key names the
  /// on-screen button for that action, so locking either locks both.
  public var lockKey: String {
    // SYNC's slot is a variant (beat / bar) of the one button, not another button
    DJActionKind.lockKey(
      deck: deck, action,
      param: macro ?? role ?? param ?? (action == .sync ? nil : slot.map { String($0) }))
  }
}

extension DJActionKind {
  public static func lockKey(deck: String?, _ action: DJActionKind, param: String? = nil)
    -> String
  {
    "\(deck ?? "-").\(action.rawValue)" + (param.map { ".\($0)" } ?? "")
  }
}
