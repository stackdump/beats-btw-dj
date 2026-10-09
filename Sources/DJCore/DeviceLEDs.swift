import Foundation

// SPEC mode 25: the live LED mirror of beats' device map (lib/ui/device-map.js `paint`, with
// the LED protocol of lib/backend/apc-mini-mk2.js), folded into the app's device map.
//
// What the Swift app already had, and what this adds. `SurfaceController.lights` is the
// controller's own LED state as data, and `PadGridView` mirrors the APC with it (pads, track
// and scene columns). The device map list (`DeviceMapView`) showed controls and actions but not
// what their LEDs say. `DeviceLights` carries that state to the list, `LEDSwatch` turns one LED
// into what the row draws (colour, brightness, blink), and `APCPalette` pins device-map.js's
// velocity-to-colour table (`PALETTE`) for the indices it knows.

/// The APC mini mk2's velocity-to-colour chart, as device-map.js draws it (`PALETTE`), and the
/// colours of its two single-LED columns (petri-note.css `.pn-dm-track`, `.pn-dm-scene`).
public enum APCPalette {
  /// device-map.js `PALETTE`, by palette index. `0` is `transparent` (off) and is not listed.
  public static let entries: [(index: UInt8, name: String, hex: String)] = [
    (3, "white", "#ffffff"),
    (5, "red", "#ff2d2d"),
    (9, "orange", "#ff8c00"),
    (13, "yellow", "#ffd400"),
    (21, "green", "#19c34d"),
    (37, "cyan", "#1ec8ff"),
    (45, "blue", "#3a5cff"),
    (53, "magenta", "#d63ad6"),
  ]

  /// The pinned colour of an index; nil for off (0) and for an index beats does not draw.
  public static func pinned(_ index: UInt8) -> ScopeColor? {
    entries.first { $0.index == index }.flatMap { ScopeColor(hex: $0.hex) }
  }

  /// Any index as a colour: the pinned one, else a hue picked from the index (a stray index
  /// shows something rather than nothing). Off (0) is black.
  public static func color(_ index: UInt8) -> ScopeColor {
    if index == 0 { return ScopeColor(r: 0, g: 0, b: 0) }
    if let c = pinned(index) { return c }
    return SectionTimeline.hsb(Double(index % 64) / 64, 0.8, 0.9)
  }

  /// A lit single LED of the track row (`.pn-dm-track.pn-dm-on`: `#ff2d2d`, border `#ff5050`).
  public static let trackOn = ScopeColor(hex: "#ff2d2d")!
  /// An unlit track LED (`.pn-dm-track`: `#1a0a0a`, shown at opacity 0.4).
  public static let trackOff = ScopeColor(hex: "#1a0a0a")!
  /// A lit single LED of the scene column (`.pn-dm-scene.pn-dm-on`: `#19c34d`).
  public static let sceneOn = ScopeColor(hex: "#19c34d")!
  /// An unlit scene LED (`.pn-dm-scene`: `#0a1a0a`, opacity 0.4).
  public static let sceneOff = ScopeColor(hex: "#0a1a0a")!
  /// `.pn-dm-off` / the unlit scene button: `opacity: 0.4`.
  public static let offOpacity = 0.4
}

/// One LED as a row of the device map draws it.
public struct LEDSwatch: Equatable, Sendable {
  public var color: ScopeColor
  /// Brightness while steady (1 full, less for a dim RGB pad or an unlit single LED).
  public var opacity: Double
  /// Whether the LED is on at all (off draws as a dark, faint dot).
  public var lit: Bool
  /// `pn-dm-blink`: alternates between full and 0.3.
  public var blinks: Bool

  public init(color: ScopeColor, opacity: Double, lit: Bool, blinks: Bool) {
    self.color = color
    self.opacity = opacity
    self.lit = lit
    self.blinks = blinks
  }

  /// The opacity at time `t` seconds on any steady clock.
  public func opacity(at t: Double) -> Double {
    blinks ? DeviceLEDs.blinkOpacity(at: t) : opacity
  }
}

public enum DeviceLEDs {
  /// `animation: pn-dm-blink 600ms infinite`.
  public static let blinkPeriod = 0.6
  /// `@keyframes pn-dm-blink`: `0%, 49% { opacity: 1 } 50%, 100% { opacity: 0.3 }`.
  public static func blinkOpacity(at t: Double) -> Double {
    let phase = (t / blinkPeriod).truncatingRemainder(dividingBy: 1)
    let p = phase < 0 ? phase + 1 : phase
    return p < 0.5 ? 1 : 0.3
  }

  /// How bright a dim RGB pad is drawn: the hardware's own 50 % (`PAD_DIM = 0x92`, "solid 50%",
  /// apc-mini-mk2.js), against 100 % for the pad that just fired (`PAD_FULL`). The JS panel does
  /// not show this: it draws a pad that has a binding at 0.85 and the one just fired at 1.0 with
  /// a glow, which says what is bound, not what the LED does. The list mirrors the LED.
  /// (`PadGridView` has always drawn its dim pads at 28 %.)
  public static let dimBrightness = 0.5
  /// How bright a `dim` single LED is drawn (`PadGridView`: its colour at 40 %).
  public static let dimSingleOpacity = 0.4

  /// The colour of a single-colour LED group on the APC: the red track row, the green scene
  /// column. Any other single-LED group (the Inpulse's buttons) has no colour in the profile:
  /// white.
  public static func singleColors(group: String) -> (on: ScopeColor, off: ScopeColor) {
    switch group {
    case "track": (APCPalette.trackOn, APCPalette.trackOff)
    case "scene": (APCPalette.sceneOn, APCPalette.sceneOff)
    default: (ScopeColor(r: 1, g: 1, b: 1), ScopeColor(r: 0.1, g: 0.1, b: 0.1))
    }
  }

  /// One LED of `group`. `rgb`: the group is an RGB grid (its `colorIndex` picks the colour);
  /// otherwise a single LED whose colour comes from the group.
  public static func swatch(_ light: PadLight, group: String, rgb: Bool) -> LEDSwatch {
    if rgb {
      guard light.colorIndex != 0, light.level != .off else {
        return LEDSwatch(color: APCPalette.color(0), opacity: 0, lit: false, blinks: false)
      }
      let k = light.level == .dim ? dimBrightness : 1
      return LEDSwatch(
        color: APCPalette.color(light.colorIndex), opacity: k, lit: true,
        blinks: light.level == .blink)
    }
    let c = singleColors(group: group)
    switch light.level {
    case .off:
      return LEDSwatch(color: c.off, opacity: APCPalette.offOpacity, lit: false, blinks: false)
    case .dim: return LEDSwatch(color: c.on, opacity: dimSingleOpacity, lit: true, blinks: false)
    case .full: return LEDSwatch(color: c.on, opacity: 1, lit: true, blinks: false)
    case .blink: return LEDSwatch(color: c.on, opacity: 1, lit: true, blinks: true)
    }
  }
}

/// What every LED of one controller shows right now: `SurfaceController.lights`, with which
/// of its groups are RGB grids.
public struct DeviceLights: Equatable, Sendable {
  /// LED state by group id, one entry per control of the group.
  public var groups: [String: [PadLight]]
  /// The groups whose LEDs take a palette colour (`SurfaceProfile.LEDs.rgbGroups`).
  public var rgbGroups: Set<String>

  public init(groups: [String: [PadLight]], rgbGroups: Set<String>) {
    self.groups = groups
    self.rgbGroups = rgbGroups
  }

  /// The LED of control `index` of `group`, nil where the control has none.
  public func swatch(group: String, index: Int) -> LEDSwatch? {
    guard let g = groups[group], g.indices.contains(index) else { return nil }
    return DeviceLEDs.swatch(g[index], group: group, rgb: rgbGroups.contains(group))
  }

  public var isEmpty: Bool { groups.isEmpty }
  /// Does any LED blink (the list then needs a clock)?
  public var anyBlinking: Bool { groups.values.contains { $0.contains { $0.level == .blink } } }
}

extension ControllerRouter {
  /// The LED state of the attached controller with profile `profileName`, for the device map;
  /// nil if that controller is not attached or its profile has no LEDs.
  public func deviceLights(profileName: String) -> DeviceLights? {
    guard let leds = surfaceProfiles.first(where: { $0.name == profileName })?.leds,
      let l = lights(profileName: profileName)
    else { return nil }
    return DeviceLights(groups: l.groups, rgbGroups: Set(leds.rgbGroups))
  }
}
