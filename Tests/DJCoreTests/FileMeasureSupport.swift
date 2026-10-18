import Foundation

@testable import DJCore

// Helpers for FileMeasureTests / PitchMeasureTests (Foundation stays out of files that import
// Testing): temporary files, written and measured back.

/// `seconds` of a synth render (techno 42, `OfflineRender`) and the same render written as a
/// 16-bit WAV and measured back with `FileMeasure`.
func renderedWAVRoundTrip(seconds: Double, sampleRate sr: Double = 48_000) throws -> (
  memory: OfflineRender, file: FileMeasure
) {
  let source = WaveDeckSource(sampleRate: sr, opts: .extended)
  let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
  let track = PreparedTrack(spec: spec, sampleRate: sr, opts: .extended(samplers: nil))
  let r = OfflineRender(track: track, source: source, seconds: seconds)
  let m = try measureTemporary(r.wav(), ext: "wav")
  return (r, m)
}

/// `samples` as a mono 16-bit WAV at `sr`, measured back.
func measureMonoWAV(_ samples: [Float], sampleRate sr: Double) throws -> FileMeasure {
  var d = Data()
  func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
  func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
  d.append(contentsOf: Array("RIFF".utf8))
  u32(UInt32(36 + samples.count * 2))
  d.append(contentsOf: Array("WAVEfmt ".utf8))
  u32(16)
  u16(1)
  u16(1)
  u32(UInt32(sr))
  u32(UInt32(sr) * 2)
  u16(2)
  u16(16)
  d.append(contentsOf: Array("data".utf8))
  u32(UInt32(samples.count * 2))
  let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
  pcm.withUnsafeBytes { d.append(contentsOf: $0) }
  return try measureTemporary(d, ext: "wav")
}

private func measureTemporary(_ data: Data, ext: String) throws -> FileMeasure {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("filemeasure-\(UUID().uuidString).\(ext)")
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  return try FileMeasure(url: url)
}

/// `hz` raised by `cents`.
func hzAbove(_ hz: Double, cents: Double) -> Double { hz * pow(2, cents / 1200) }

/// BS.1770 integrated loudness of a render, as `djctl render` reports it.
func renderLUFS(_ r: OfflineRender) -> Double {
  IntegratedLoudness.lufs(left: r.left, right: r.right, sampleRate: r.sampleRate)
}

/// `FileMeasure.audioBlock`'s `lufs` for a measured file.
func fileLUFS(_ m: FileMeasure) -> Double { m.dictionary["lufs"] as? Double ?? .nan }
