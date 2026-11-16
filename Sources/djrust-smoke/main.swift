import DJRust
import Foundation

// Smoke test of the Rust engine through the XCFramework + UniFFI Swift bindings: open the
// default CoreAudio output, compose and play on deck A, read the engine's meters.
// SKIPPED (not failed) if the output never calls back (headless / lid closed).
// The spike also rendered offline; djandroid's crate has no offline render yet
// (docs/ANDROID-PORT.md, "Engine changes wanted" 1).
// Usage: djrust-smoke [genre] [seed] [seconds] [--require-live]
let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
let flags = Set(CommandLine.arguments.filter { $0.hasPrefix("--") })
let genre = args.count > 1 ? args[1] : "house"
let seed = Int64(args.count > 2 ? args[2] : "42") ?? 42
let seconds = Double(args.count > 3 ? args[3] : "6") ?? 6

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }

do {
  print("genres:", RustEngine.genres.count, RustEngine.genres.prefix(6).joined(separator: ", "), "…")
  guard RustEngine.genres.contains(genre) else { fail("unknown genre \(genre)") }
  print("title:", trackTitle(genre: genre, seed: seed))

  // live
  let e = try RustEngine()
  print("live engine: \(e.info.sampleRate) Hz, \(e.info.soundFonts) soundfonts")
  try e.load(deck: "A", genre: genre, seed: seed)
  var peak: Float = 0, master: Float = 0, firstTick: Int64 = -1, lastTick: Int64 = 0, tempo = 0.0
  let t0 = Date()
  while Date().timeIntervalSince(t0) < seconds {
    let s = try e.state("A")
    if s.loaded && s.playing {
      if firstTick < 0 { firstTick = s.tick }
      lastTick = s.tick; peak = max(peak, s.level); tempo = s.tempo
    }
    master = max(master, try e.mix().masterLevel)
    Thread.sleep(forTimeInterval: 0.1)
  }
  let s = try e.state("A")
  print("live deck A: \(s.title ?? "?") \(String(format: "%.1f", tempo)) bpm, playing=\(s.playing), tick \(firstTick)→\(lastTick), deck peak \(peak), master peak \(master)")
  e.shutdown()
  if firstTick < 0 || lastTick <= firstTick {
    let m = "live: the output never called back (no audio in this session: lid closed or headless?)"
    if flags.contains("--require-live") { fail(m) }
    print("SKIP \(m)"); exit(0)
  }
  if peak <= 0.001 || master <= 0.001 { fail("live: silence") }
  print("OK live: audio through CoreAudio via the Rust engine")
} catch { fail("\(error)") }
