@preconcurrency import AVFoundation
import Foundation

@testable import DJCore

// Kept out of files that `import Testing`: importing Foundation next to
// Testing needs the _Testing_Foundation overlay, which ships only with Xcode.

/// Distinct messages captured from the real hardware, keyed by device.
func capturedMessages() throws -> [String: [[UInt8]]] {
  guard
    let url = Bundle.module.url(
      forResource: "captured-messages", withExtension: "json", subdirectory: "Fixtures")
  else { throw CocoaError(.fileNoSuchFile) }
  return try JSONDecoder().decode([String: [[UInt8]]].self, from: Data(contentsOf: url))
}

/// Raw text of a Phase 2 parity fixture written by scripts/beats-parity.mjs.
func beatsFixtureText(_ name: String) throws -> String {
  guard
    let url = Bundle.module.url(
      forResource: name, withExtension: "json", subdirectory: "Fixtures/beats")
  else { throw CocoaError(.fileNoSuchFile) }
  return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Wave-engine render helpers (Foundation lives here, not next to Testing)

func decodeFloat32(base64: String) -> [Float] {
  guard let data = Data(base64Encoded: base64) else { return [] }
  return data.withUnsafeBytes { raw in
    (0..<(data.count / 4)).map {
      Float(bitPattern: raw.load(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
    }
  }
}

struct WaveRenderResult {
  var left: [Float]
  var right: [Float]
  var tempoAtEnd: Double
  var stopped: Bool
  var samples: Double
  var graphTick: Int
}

private func waveProject(_ spec: JSONValue) -> Project {
  var ov = JSONObject()
  ov["seed"] = spec["seed"] ?? .number(42)
  if let s = spec["structure"]?.string, s != "loop" { ov["structure"] = .string(s) }
  return compose(genre: spec["genre"]?.string ?? "techno", overrides: .object(ov))
}

/// The Swift twin of scripts/beats-wave.mjs::render — same scripted operations, same
/// 128-frame blocks.
func renderWaveCase(_ c: JSONValue) -> WaveRenderResult {
  let sr = c["sr"]!.double!
  var opts = WaveOptions()
  if let r = c["runner"] {
    if let m = r["master"]?.string { opts.master = m }
    if let g = r["masterGain"]?.double { opts.masterGain = g }
    for (id, v) in r["voices"]?.object?.entries ?? [] { opts.voices[id] = VoiceSpec(json: v) }
    for m in r["mods"]?.array ?? [] {
      opts.mods.append(
        WaveMod(
          target: m["target"]!.string!, source: m["source"]!.string!, kind: m["kind"]!.string!,
          depth: m["depth"]!.double!, silentSource: m["silentSource"]?.bool ?? false))
    }
  }
  let runner = WaveRunner(sampleRate: sr, opts: opts)
  runner.load(waveProject(c["project"]!))
  if let t = c["tempo"]?.double { runner.setTempo(t) }
  runner.play()
  let frames = Int((c["seconds"]!.double! * sr).rounded())
  var left = [Float](repeating: 0, count: frames)
  var right = [Float](repeating: 0, count: frames)
  let ops = (c["ops"]?.array ?? []).enumerated().sorted {
    let a = $0.element["block"]!.double!
    let b = $1.element["block"]!.double!
    return a != b ? a < b : $0.offset < $1.offset
  }.map(\.element)
  var oi = 0
  var blk = 0
  var off = 0
  while off < frames {
    while oi < ops.count && ops[oi]["block"]!.double! <= Double(blk) {
      let op = ops[oi]
      oi += 1
      switch op["op"]!.string! {
      case "tempo": runner.setTempo(op["bpm"]!.double!)
      case "mute": runner.setMute(op["netId"]!.string!, op["muted"]!.bool!)
      case "load": runner.load(waveProject(op["project"]!))
      case "pause": runner.pause()
      case "play": runner.play()
      case "stop": runner.stop()
      default: break
      }
    }
    let n = min(128, frames - off)
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        runner.process(l.baseAddress! + off, r.baseAddress! + off, frames: n)
      }
    }
    off += 128
    blk += 1
  }
  return WaveRenderResult(
    left: left, right: right, tempoAtEnd: runner.tempo, stopped: runner.stopped,
    samples: runner.samples, graphTick: runner.graph!.tick)
}

// MARK: - Offline deck rendering

/// Render `frames` of an offline `DJEngine` (already started), returning the left channel.
func renderOffline(_ dj: DJEngine, frames: Int) throws -> [Float] {
  let out = AVAudioPCMBuffer(pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: 4096)!
  var left: [Float] = []
  while left.count < frames {
    let n = AVAudioFrameCount(min(4096, frames - left.count))
    let status = try dj.engine.renderOffline(n, to: out)
    guard status == .success else { break }
    left += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
  }
  return left
}
