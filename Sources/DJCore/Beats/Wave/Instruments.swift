import Foundation

/// Per-instrument voices beyond beats' wave engine, which folds every tonal instrument into a
/// handful of wavetable families (`tonalVoice`). An entry here overlays that family voice with
/// its own engine and parameters, taken from beats' Tone.js presets (audio/tone-engine.js), so
/// `acoustic-guitar` plucks a string instead of playing the default saw.
///
/// Data, like the device profiles: `Resources/voices/instruments.json`. The parity path
/// (`WaveOptions()`, what the beats fixtures run) does not consult it; the app does
/// (`WaveOptions.extended`).
public final class InstrumentTable: @unchecked Sendable {
  public static let shared: InstrumentTable = {
    do { return try InstrumentTable(json: .parse(try loadText())) } catch {
      fatalError("instrument table: \(error)")
    }
  }()

  static func loadText() throws -> String {
    // In DJApp.app the table sits in Contents/Resources/voices (scripts/bundle-app.sh).
    guard
      let url = Bundle.main.url(
        forResource: "instruments", withExtension: "json", subdirectory: "voices")
        ?? Bundle.module.url(
          forResource: "instruments", withExtension: "json", subdirectory: "voices")
    else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "voices/instruments.json"])
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Instrument name → overlay (only the fields that differ from its family voice).
  public let entries: [String: JSONValue]

  public init(json: JSONValue) throws {
    guard let o = json["instruments"]?.object else {
      throw JSONError.syntax("expected {\"instruments\": {…}}", offset: 0)
    }
    var e: [String: JSONValue] = [:]
    for (k, v) in o.entries { e[k] = v }
    entries = e
  }

  public var names: [String] { entries.keys.sorted() }

  /// The voice for an instrument: its family voice, overlaid by its entry if it has one.
  public func voice(instrument: String?, group: String?) -> VoiceSpec {
    var v = tonalVoice(instrument: instrument, group: group)
    if let name = instrument, let e = entries[name] { v.overlay(e) }
    return v
  }
}

extension VoiceSpec {
  /// Set the fields `v` names; leave the rest.
  mutating func overlay(_ v: JSONValue) {
    if let x = v["level"]?.double { level = x }
    if let x = v["wave"]?.string { wave = x }
    if let x = v["attack"]?.double { attack = x }
    if let x = v["decayScale"]?.double { decayScale = x }
    if let x = v["maxDecay"]?.double { maxDecay = x }
    applyExtended(v)
  }

  mutating func applyExtended(_ v: JSONValue) {
    if let x = v["engine"]?.string { engine = x }
    if let x = v["attackNoise"]?.double { attackNoise = x }
    if let x = v["dampening"]?.double { dampening = x }
    if let x = v["resonance"]?.double { resonance = x }
    if let x = v["vibratoRate"]?.double { vibratoRate = x }
    if let x = v["vibratoDepth"]?.double { vibratoDepth = x }
    if let x = v["lowpass"]?.double { lowpass = x }
    if let x = v["distortion"]?.double { distortion = x }
  }
}

extension WaveOptions {
  /// What the app plays: beats' wave engine plus the instrument table.
  public static var extended: WaveOptions {
    var o = WaveOptions()
    o.instruments = .shared
    return o
  }
}

/// Tone.Distortion's waveshaping curve (`amount` 0…1).
@inline(__always)
func toneDistortion(_ x: Double, amount: Double) -> Double {
  let k = amount * 100
  return (3 + k) * x * 20 * (Double.pi / 180) / (Double.pi + k * abs(x))
}
