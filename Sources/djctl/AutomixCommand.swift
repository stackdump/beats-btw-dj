import DJCore
import Foundation

// djctl automix <genre> <seed> [--bars N] [--every P] [--handoffs K] [--structure S]
//   [--crossfade-only] [--out f.wav] — an offline auto-mix set (AutoMixMeasure): per hand-off
// the outgoing deck alone over the 8 bars before it, the incoming alone over the 8 after, the
// short-term loudness per beat across it, its dip and bump; and the set's peaks. JSON.

let automixUsage =
  "usage: djctl automix <genre> <seed> [--bars 4|8|16|32] [--every 0|4|8|16] [--handoffs K] "
  + "[--structure S|loop] [--crossfade-only] [--out f.wav]"

@MainActor func automixCommand() {
  let bars = Int(option("--bars") ?? 8)
  let every = Int(option("--every") ?? 4)
  let count = Int(option("--handoffs") ?? 1)
  let structure = stringOption("--structure") ?? "standard"
  let crossfadeOnly = flag("--crossfade-only")
  let out = stringOption("--out")
  guard positional.count == 2, BeatsTables.shared.genres[positional[0]] != nil,
    let seed = Double(positional[1]), AutoMixSettings.lengths.contains(bars),
    AutoMixSettings.everies.contains(every), count >= 1
  else {
    stderr(automixUsage)
    exit(2)
  }
  do {
    let m = try AutoMixMeasure.run(
      genre: positional[0], seed: seed, structure: structure == "loop" ? nil : structure,
      bars: bars, every: every, count: count, crossfadeOnly: crossfadeOnly, keepAudio: out != nil)
    if let out, let audio = m.audio {
      try WAV.encode(audio).write(to: URL(fileURLWithPath: out))
    }
    let data = try JSONSerialization.data(
      withJSONObject: m.dictionary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  } catch {
    stderr("\(error)")
    exit(1)
  }
}
