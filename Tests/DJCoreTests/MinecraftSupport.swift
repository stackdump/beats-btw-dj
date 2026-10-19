import Foundation

@testable import DJCore

// Helpers for MinecraftTests (Foundation stays out of files that import Testing).

/// The installed game assets, or nil (tests skip as SoundFontTests does without its bank).
let minecraftAssets: MinecraftAssets? = try? MinecraftAssets.locate()

/// A bank imported into a scratch folder once per test run (nil without the assets).
let scratchMinecraftBank: (dir: String, report: MinecraftImport.Report)? = {
  guard let assets = minecraftAssets else { return nil }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mc-\(UUID().uuidString)"
  ).path
  guard let report = try? MinecraftImport.run(assets: assets, to: dir) else { return nil }
  return (dir, report)
}()

func lastPathComponent(_ path: String) -> String { (path as NSString).lastPathComponent }

/// The same decoded twice compares equal: the import is a pure function of the assets.
func bankBytes(_ dir: String) -> [UInt8]? {
  FileManager.default.contents(atPath: MinecraftBank.path(dir: dir)).map { [UInt8]($0) }
}

/// A scratch folder with nothing in it.
func emptyScratchDir() -> String {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "empty-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir.path
}

/// `Fixtures/mc-recent-events.json`: what `mc_recent_events` returns, made by the valoper
/// server's own EventBuffer + LogWatcher (the log events) with a players/joined notification
/// in the management protocol's `[player]` params.
func mcRecentEventsFixture() throws -> String {
  guard
    let url = Bundle.module.url(
      forResource: "mc-recent-events", withExtension: "json", subdirectory: "Fixtures")
  else { throw CocoaError(.fileNoSuchFile) }
  return try String(contentsOf: url, encoding: .utf8)
}

/// The event map loaded with a scratch bundle holding `json` as voices/minecraft-events.json
/// ahead of the default bundles (as the app's Contents/Resources is ahead of SwiftPM's).
func eventMapWithOverride(_ json: String) throws -> MinecraftEventMap {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mcmap-\(UUID().uuidString)")
  let voices = dir.appendingPathComponent("voices")
  try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
  try json.write(
    to: voices.appendingPathComponent("minecraft-events.json"), atomically: true, encoding: .utf8)
  guard let b = Bundle(path: dir.path) else { throw CocoaError(.fileNoSuchFile) }
  return try MinecraftEventMap.load(bundles: [b] + MinecraftEventMap.defaultBundles)
}

/// A sine at `freq` Hz, `seconds` long, amplitude 0.5.
func sineWave(_ freq: Double, sampleRate sr: Double, seconds: Double) -> [Float] {
  (0..<Int(seconds * sr)).map { Float(0.5 * sin(2 * Double.pi * freq * Double($0) / sr)) }
}

/// The level of one frequency in `x` (Hann-windowed DFT, dB re a full-scale sine).
func toneLevelDB(_ x: ArraySlice<Float>, freq: Double, sampleRate sr: Double) -> Double {
  let v = Array(x)
  let n = v.count
  guard n > 1 else { return -200 }
  var re = 0.0
  var im = 0.0
  var wsum = 0.0
  for i in 0..<n {
    let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
    let ph = 2 * Double.pi * freq * Double(i) / sr
    re += w * Double(v[i]) * cos(ph)
    im -= w * Double(v[i]) * sin(ph)
    wsum += w
  }
  return 20 * log10(max(2 * (re * re + im * im).squareRoot() / wsum, 1e-12))
}

/// Writes a Minecraft sidecar into `dir`, as the import would — or, `format` nil, as a
/// format-1 bank's (no `format` key).
func writeMinecraftSidecar(dir: String, assetIndex: String, format: Int?) throws {
  var json = MinecraftBank.Sidecar(
    assetIndex: assetIndex, sha1: [:], programs: ["harp2"], format: format ?? 1
  ).json
  if format == nil, case .object(var o) = json {
    o["format"] = nil
    json = .object(o)
  }
  try (json.canonicalJS + "\n").write(
    toFile: (dir as NSString).appendingPathComponent(MinecraftBank.sidecarName),
    atomically: true, encoding: .utf8)
}
