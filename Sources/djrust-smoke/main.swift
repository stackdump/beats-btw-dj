import DJRust
import Foundation

// Smoke test of the Rust engine through the XCFramework + UniFFI Swift bindings.
//   1. offline: compose + render through the engine's own mixer, no sound card; asserts the
//      signal is non-silent and bit-exact repeatable.
//   2. live: open the default CoreAudio output, play on deck A, read the engine's meters.
//      SKIPPED (not failed) if the host's audio device never calls back (headless / lid closed).
// Usage: djrust-smoke [genre] [seed] [seconds] [--no-live] [--require-live]
let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
let flags = Set(CommandLine.arguments.filter { $0.hasPrefix("--") })
let genre = args.count > 1 ? args[1] : "house"
let seed = Int64(args.count > 2 ? args[2] : "42") ?? 42
let seconds = Double(args.count > 3 ? args[3] : "6") ?? 6

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }

do {
  print("genres:", RustEngine.genres.count, RustEngine.genres.prefix(6).joined(separator: ", "), "…")
  guard RustEngine.genres.contains(genre) else { fail("unknown genre \(genre)") }

  // 1. offline
  let a = try renderOffline(genre: genre, seed: seed, seconds: 8, sampleRate: 48000)
  let b = try renderOffline(genre: genre, seed: seed, seconds: 8, sampleRate: 48000)
  print("offline: \(a.title) \(String(format: "%.1f", a.tempo)) bpm, \(a.frames) frames, peak \(a.peak), rms \(a.rms), active \(a.active), checksum \(String(a.checksum, radix: 16))")
  if a.peak <= 0.01 || a.rms <= 0.001 || a.active < 0.5 { fail("offline render is silent") }
  if a.checksum != b.checksum { fail("offline render is not repeatable") }
  print("OK offline: audio rendered through the Rust engine, repeatable")

  // 2. live
  if flags.contains("--no-live") { exit(0) }
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
