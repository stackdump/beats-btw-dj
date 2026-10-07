import Foundation

/// A DJ controller's jog-wheel map. The values live in
/// `Resources/profiles/<id>.json` — the single source of truth, shared with
/// the browser lab (web/jog/profile-parity.test.mjs keeps the JS copy honest).
public struct JogProfile: Codable, Sendable, Equatable {
  public struct Touch: Codable, Sendable, Equatable {
    public var note: UInt8
    public var onVelocity: UInt8
    public var releaseAsNoteOff: Bool
  }

  public enum Encoding: String, Codable, Sendable {
    /// 0x01 = +1, 0x7F = -1 (7-bit two's complement)
    case twos
    /// 0x41 = +1, 0x3F = -1 (centred on 0x40)
    case offset64
  }

  public var name: String
  public var manufacturer: String
  /// Case-insensitive regex matched against the MIDI port name.
  public var match: String
  /// Deck name -> MIDI channel (0-based status nibble).
  public var decks: [String: UInt8]
  public var shiftChannelOffset: UInt8
  public var touch: Touch
  public var scratchCC: UInt8
  public var bendCC: UInt8
  public var maxMagnitude: Int
  public var encoding: Encoding
  public var ticksPerRev: Int
  public var platterRpm: Double
  public var usbFrameMs: Double
  public var coastTauSec: Double

  /// Seconds of 1x audio that one encoder tick represents.
  public var secondsPerTick: Double { 60 / platterRpm / Double(ticksPerRev) }

  public func matches(portName: String) -> Bool {
    portName.range(of: match, options: [.regularExpression, .caseInsensitive]) != nil
  }

  public static func load(_ id: String) throws -> JogProfile {
    // In DJApp.app the profiles sit in Contents/Resources/profiles (see scripts/bundle-app.sh):
    // SwiftPM's Bundle.module only looks at the .app root, where codesign rejects a bundle.
    // Under `swift run` / `swift test`, Bundle.module finds them in .build.
    let url =
      Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "profiles")
      ?? Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "profiles")
    guard let url else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "profiles/\(id).json"])
    }
    return try JSONDecoder().decode(JogProfile.self, from: Data(contentsOf: url))
  }

  public static let inpulse200MK3: JogProfile = {
    do { return try load("inpulse-200-mk3") } catch { fatalError("bundled profile: \(error)") }
  }()
}
