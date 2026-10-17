import Foundation

@testable import DJCore

// Helpers for PaletteTests (Foundation stays out of files that import Testing).

/// `seconds` of `spec` rendered as a deck plays it (`OfflineRender`: the runner, its samplers
/// and the master chain), from `startTick`; `sampled` false prepares without a sampler bank.
func renderSpec(
  _ spec: TrackSpec, seconds: Double, sampleRate sr: Double = 24_000, startTick: Int = 0,
  sampled: Bool = true
) -> (left: [Float], right: [Float]) {
  let source = WaveDeckSource(sampleRate: sr, opts: .extended)
  let opts = WaveOptions.extended(samplers: sampled ? source.samplers : nil)
  let track = PreparedTrack(spec: spec, sampleRate: sr, opts: opts, startTick: startTick)
  let r = OfflineRender(track: track, source: source, seconds: seconds)
  return (r.left, r.right)
}

/// Does the source's `tracks` override set `field` to `value` on any channel?
func sourceNames(_ d: DeckSourceDescriptor?, _ field: String, _ value: String) -> Bool {
  guard case .net(let spec)? = d, let tracks = spec.layers["tracks"]?.object else { return false }
  return tracks.entries.contains { $0.value[field]?.string == value }
}

/// Does the spec's `tracks` override have `field` anywhere?
func specHas(_ s: TrackSpec, _ field: String) -> Bool {
  (s.layers["tracks"]?.object?.entries ?? []).contains { $0.value[field] != nil }
}

/// A sine at `hz` whose RMS is `rmsDB` dBFS.
func sineWave(_ hz: Double, rmsDB: Double, seconds: Double, sampleRate sr: Double) -> [Float] {
  let a = pow(10, rmsDB / 20) * 2.0.squareRoot()
  return (0..<Int(sr * seconds)).map { Float(a * sin(2 * Double.pi * hz * Double($0) / sr)) }
}
