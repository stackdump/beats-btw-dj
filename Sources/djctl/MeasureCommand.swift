import DJCore
import Foundation

// djctl measure <file> [--start S] [--seconds N] [--note N] — any local audio file (wav, aiff,
// mp3, m4a, flac) through the audio block `djctl render` prints (`FileMeasure`), as one JSON
// object: the render keys plus the file's basename and sha256 prefix. --note N adds `pitch`:
// the first second measured against MIDI note N (`PitchMeasure`).

let measureUsage = "usage: djctl measure <file> [--start S] [--seconds N] [--note N]"

@MainActor func measureCommand() {
  let start = option("--start") ?? 0
  let seconds = option("--seconds")
  let note = option("--note")
  guard positional.count == 1, start.isFinite, start >= 0,
    seconds.map({ $0.isFinite && $0 > 0 }) ?? true,
    note.map({ $0.isFinite && $0 >= 0 && $0 <= 127 && $0 == $0.rounded() }) ?? true
  else {
    stderr(measureUsage)
    exit(2)
  }
  do {
    let m = try FileMeasure(
      url: URL(fileURLWithPath: positional[0]), start: start, seconds: seconds)
    var doc = m.dictionary
    if let note { doc["pitch"] = m.pitch(note: Int(note)) }
    let data = try JSONSerialization.data(
      withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
  } catch {
    stderr("\(error)")
    exit(1)
  }
}
