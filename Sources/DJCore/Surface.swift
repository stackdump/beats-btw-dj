import Foundation

/// What a control on a surface does. Continuous actions take the control's
/// value (0...1); momentary ones fire on press.
public enum DJActionKind: String, Codable, Sendable {
  case volume  // continuous, per deck
  case filter  // continuous, per deck: < 0.5 low-pass, > 0.5 high-pass
  case pitch  // continuous, per deck: ±8 %
  case crossfader  // continuous: 0 = A, 1 = B
  case master  // continuous
  case play  // press: toggle the deck's transport
  case hotcue  // press: jump to slot, or set it if empty
  case clearcue  // press: forget slot
}

/// A button/knob surface: pads, faders, keys — everything that is not a jog
/// wheel. Loaded from `Resources/profiles/<id>.json`, like `JogProfile`.
public struct SurfaceProfile: Codable, Sendable {
  public enum ControlType: String, Codable, Sendable { case note, cc }

  /// A contiguous run of notes or CCs: `first ..< first + count`.
  public struct Group: Codable, Sendable {
    public var id: String
    public var type: ControlType
    public var first: UInt8
    public var count: UInt8
    /// 0-based MIDI channel, or nil for any (the default, as in beats).
    public var channel: UInt8?
  }

  public struct Binding: Codable, Sendable, Hashable {
    public var group: String
    public var index: Int
    public var action: DJActionKind
    public var deck: String?
    public var slot: Int?
  }

  /// APC-style LED feedback: note-on to the same note lights it.
  public struct LEDs: Codable, Sendable {
    public var rgbGroups: [String]
    public var singleGroups: [String]
    public var rgbDimStatus: UInt8
    public var rgbFullStatus: UInt8
    public var singleOff: UInt8
    public var singleOn: UInt8
    public var singleBlink: UInt8
  }

  public var name: String
  public var manufacturer: String
  public var match: String
  public var matchComment: String?
  public var source: String?
  public var groups: [Group]
  public var leds: LEDs?
  public var layout: [Binding]

  public func matches(portName: String) -> Bool {
    portName.range(of: match, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// Decode a raw MIDI message into the control it came from, if any.
  public func parse(_ data: [UInt8]) -> ControlEvent? {
    guard data.count >= 3 else { return nil }
    let type = data[0] & 0xF0
    let channel = data[0] & 0x0F
    let kind: ControlType
    let pressed: Bool
    switch type {
    case 0x90:
      kind = .note
      pressed = data[2] > 0
    case 0x80:
      kind = .note
      pressed = false
    case 0xB0:
      kind = .cc
      pressed = data[2] > 0
    default: return nil
    }
    for g in groups where g.type == kind && (g.channel == nil || g.channel == channel) {
      let n = Int(data[1]) - Int(g.first)
      if n >= 0 && n < Int(g.count) {
        return ControlEvent(
          group: g.id, index: n, value: Double(data[2]) / 127, pressed: pressed, isCC: kind == .cc)
      }
    }
    return nil
  }

  /// The note/CC number for a control, for LED output.
  public func number(group: String, index: Int) -> UInt8? {
    guard let g = groups.first(where: { $0.id == group }), index >= 0, index < Int(g.count) else {
      return nil
    }
    return g.first + UInt8(index)
  }

  public static func load(_ id: String) throws -> SurfaceProfile {
    try JSONDecoder().decode(SurfaceProfile.self, from: Data(contentsOf: profileURL(id)))
  }

  public static let apcMiniMK2: SurfaceProfile = {
    do { return try load("apc-mini-mk2") } catch { fatalError("bundled profile: \(error)") }
  }()

  public static let mpkMiniMK2: SurfaceProfile = {
    do { return try load("mpk-mini-mk2") } catch { fatalError("bundled profile: \(error)") }
  }()

  public static var all: [SurfaceProfile] { [apcMiniMK2, mpkMiniMK2] }
}

public struct ControlEvent: Equatable, Sendable {
  public var group: String
  public var index: Int
  /// 0...1 (data byte / 127).
  public var value: Double
  /// Note-on with velocity > 0, or CC > 0.
  public var pressed: Bool
  public var isCC: Bool
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
