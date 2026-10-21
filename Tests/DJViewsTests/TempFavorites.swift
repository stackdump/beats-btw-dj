import Foundation

@testable import DJCore

/// A favorites store in a fresh temporary directory (kept out of the Testing files: importing
/// Foundation next to Testing needs a cross-import overlay Command Line Tools doesn't ship).
func temporaryFavorites() -> FavoritesStore {
  FavoritesStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("favorites-\(UUID().uuidString)/favorites.json"))
}

/// An Apple Loop installed on this Mac to test with (nil without GarageBand / Logic content).
let installedAppleLoop: URL? = {
  let u = URL(
    fileURLWithPath: "/Library/Audio/Apple Loops/Apple/01 Hip Hop/Chill Hip-Hop Beat 08.caf")
  return FileManager.default.fileExists(atPath: u.path) ? u : nil
}()

/// A loops library over a fresh folder holding a copy of `installedAppleLoop` as
/// `<root>/Apple/Test Pack/…`, with its index in the same temporary folder.
func temporaryLoopLibrary() throws -> StockLoopLibrary {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "loops-\(UUID().uuidString)")
  let pack = dir.appendingPathComponent("root/Apple/Test Pack")
  try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
  if let src = installedAppleLoop {
    try FileManager.default.copyItem(
      at: src, to: pack.appendingPathComponent(src.lastPathComponent))
  }
  return StockLoopLibrary(
    roots: [dir.appendingPathComponent("root")], indexFile: dir.appendingPathComponent("index.json")
  )
}

/// A voice-variation library in a fresh temporary directory.
func temporaryVoiceVariations() -> VoiceVariationStore {
  VoiceVariationStore(
    file: FileManager.default.temporaryDirectory
      .appendingPathComponent("voices-\(UUID().uuidString)/voices.json"))
}

/// A stand-in stock loop: `beats` beats at `bpm` of a quiet tone, written as a WAV in a fresh
/// temporary folder, described as `category` (no Apple Loops content needed).
func temporaryStockLoop(
  _ name: String, category: String, beats: Int = 4, bpm: Double = 120,
  sampleRate: Double = 22_050, pitch: Double = 220
) throws -> StockLoop {
  let frames = Int((Double(beats) * 60 / bpm * sampleRate).rounded())
  let tone = (0..<frames).map { Float(0.2 * sin(2 * Double.pi * pitch * Double($0) / sampleRate)) }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "stock-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("\(name).wav")
  try WAV.encode(RenderedAudio(sampleRate: sampleRate, left: tone, right: tone), float32: true)
    .write(to: url)
  return StockLoop(
    path: url.path, name: name, pack: "Test Pack", category: category, subcategory: "",
    genre: "Test", beats: beats, seconds: Double(frames) / sampleRate, key: nil)
}

/// A described stock loop with no file behind it, for the filters.
func describedStockLoop(_ name: String, category: String, beats: Int, seconds: Double)
  -> StockLoop
{
  StockLoop(
    path: "/nowhere/\(category)/\(name).caf", name: name, pack: "Test Pack", category: category,
    subcategory: "", genre: "Test", beats: beats, seconds: seconds, key: nil)
}

/// A compositions store in a fresh temporary folder (so `dj_compose` tests never write to the
/// app's real one).
func temporaryCompositions() -> CompositionStore {
  CompositionStore(
    directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("compositions-\(UUID().uuidString)", isDirectory: true))
}
