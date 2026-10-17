import Foundation

@testable import DJCore

// Helpers for SampledKitTests (Foundation stays out of files that import Testing).

/// MuseScore_General.sf2 when downloaded (`make soundfonts`).
var floorBank: String? {
  let path = (SamplerSource.soundFontDir as NSString).appendingPathComponent(
    SamplerSource.floorSoundFont)
  return FileManager.default.fileExists(atPath: path) ? path : nil
}

/// Apple's GM bank, when this Mac has it.
var appleBank: String? {
  FileManager.default.fileExists(atPath: SamplerSource.gmBank.path)
    ? SamplerSource.gmBank.path : nil
}

/// The id of MuseScore_General's Standard kit.
let floorKit = "\(SamplerSource.floorSoundFont)#128:0"

/// `SamplerInstrument.kitPhrase` as a net project at 120 BPM (one bar of 16ths, looped):
/// kick, snare and hats on beats' drum channels, velocity 100. `only` keeps one GM key.
func kitPhraseProject(only: Int? = nil, kit: String? = nil) -> Project {
  var p = Project()
  p.tempo = 120
  func net(_ note: Int, _ channel: Int, _ steps: [Int]) -> NetBundle {
    var n = NetBundle.ring(16)
    for s in steps { n.bind(s, note: note, channel: channel, velocity: 100, duration: 50) }
    n.track.channel = channel
    n.track.kit = kit
    return n
  }
  let parts: [(String, Int, Int, [Int])] = [
    ("kick", 36, 10, [0, 4, 8, 12]), ("snare", 38, 11, [4, 12]),
    ("hihat", 42, 12, Array(0..<16)),
  ]
  for (id, note, ch, steps) in parts where only == nil || only == note {
    p.nets[id] = net(note, ch, steps)
  }
  return p
}

/// `seconds` of `project` through a runner with `opts`, mono, after `skip` seconds.
func renderRunner(
  _ project: Project, opts: WaveOptions, sampleRate sr: Double, seconds: Double,
  skip: Double = 0
) -> [Float] {
  let runner = WaveRunner(sampleRate: sr, opts: opts)
  runner.load(prepared: WaveRunner.prepare(project, sampleRate: sr, opts: opts))
  runner.play()
  let total = Int((seconds + skip) * sr)
  var out = [Float](repeating: 0, count: total)
  var n = 0
  out.withUnsafeMutableBufferPointer { b in
    while n < total {
      let m = min(512, total - n)
      runner.process(b.baseAddress! + n, nil, frames: m)
      n += m
    }
  }
  return Array(out[Int(skip * sr)...])
}

/// Options that play the drums on the deck's bank (the instrument table on, no fixes, a
/// linear master): what the kit level checks compare against the synth kit.
func kitOptions(_ bank: SamplerBank?) -> WaveOptions {
  var o = WaveOptions()
  o.master = "linear"
  o.instruments = .shared
  o.samplers = bank
  return o
}
