import Foundation

@testable import DJCore

// Helpers for LoopFxTests (Foundation kept out of the Testing files): a loop bank playing sine
// clips, rendered block by block, and the measurements the FX tests make on it.

/// A stereo sine clip that loops seamlessly: `periods` whole periods of `hz` at 48 kHz.
func fxSineBuffer(hz: Double = 375, amplitude: Double = 0.25, seconds: Double = 1) -> SampleBuffer {
  let sr = 48_000.0
  let n = Int(sr * seconds)
  let l = (0..<n).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / sr)) }
  return SampleBuffer(left: l, right: l, sampleRate: sr)
}

/// A loop bank with `clips` on voices 0…, each looping from frame 0 at full level, the FX of
/// each set before it starts (`fx[v]`, if given). `render` pulls it in 512-frame blocks.
final class FxBankRig {
  let bank = LoopBank(sampleRate: 48_000)
  private(set) var frame = 0
  private let l = UnsafeMutablePointer<Float>.allocate(capacity: 512)
  private let r = UnsafeMutablePointer<Float>.allocate(capacity: 512)

  init(_ clips: [SampleBuffer], fx: [LoopFX] = []) {
    for (v, b) in clips.enumerated() {
      let tt = bank.voices[v]
      tt.load(b)
      tt.send(.loop(start: 0, end: Double(b.length)))
      tt.send(.start)
      bank.send(.gain(voice: v, 1))
      if v < fx.count { set(v, fx[v]) }
      bank.send(.start(voice: v, frame: 0, fade: 0))
    }
  }

  deinit {
    l.deallocate()
    r.deallocate()
  }

  func set(_ v: Int, _ fx: LoopFX) {
    bank.send(.fx(voice: v, LoopFxParams(fx, sampleRate: 48_000)))
  }

  /// The next `frames` frames (a multiple of 512), both channels.
  func render(_ frames: Int) -> (left: [Float], right: [Float]) {
    var outL: [Float] = []
    var outR: [Float] = []
    outL.reserveCapacity(frames)
    outR.reserveCapacity(frames)
    var done = 0
    while done < frames {
      let n = min(512, frames - done)
      bank.render(frames: n, left: l, right: r, startFrame: frame)
      outL += UnsafeBufferPointer(start: l, count: n)
      outR += UnsafeBufferPointer(start: r, count: n)
      frame += n
      done += n
    }
    return (outL, outR)
  }

  /// Render without keeping it.
  func skip(_ frames: Int) { _ = render(frames) }
}

func rms(_ x: [Float]) -> Double {
  (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
}

func dB(_ ratio: Double) -> Double { 20 * log10(ratio) }

/// The amplitude of `hz` in `x` (a Goertzel over the whole slice; exact for whole periods).
func toneAmplitude(_ x: [Float], hz: Double, sampleRate sr: Double = 48_000) -> Double {
  let w = 2 * Double.pi * hz / sr
  let c = 2 * cos(w)
  var s1 = 0.0
  var s2 = 0.0
  for v in x {
    let s = Double(v) + c * s1 - s2
    s2 = s1
    s1 = s
  }
  let p = s1 * s1 + s2 * s2 - c * s1 * s2
  return 2 * p.squareRoot() / Double(x.count)
}

/// Total harmonic distortion of a tone at `hz`: harmonics 2…10 against the fundamental.
func thd(_ x: [Float], hz: Double) -> Double {
  let f = toneAmplitude(x, hz: hz)
  let h = (2...10).map { toneAmplitude(x, hz: hz * Double($0)) }
  return (h.reduce(0) { $0 + $1 * $1 }).squareRoot() / max(f, 1e-12)
}

/// The largest jump from one sample to the next.
func maxStep(_ x: ArraySlice<Float>) -> Float {
  zip(x.dropFirst(), x).map { abs($0 - $1) }.max() ?? 0
}

/// A clip for the engine tests: one bar at 120 bpm of a sine (48 kHz).
func fxTestClip(_ n: Int, amplitude: Double = 0.2) -> LoopClip {
  let b = fxSineBuffer(hz: 375 + 125 * Double(n), amplitude: amplitude, seconds: 2)
  return LoopClip(
    id: b.contentID, title: "fx loop \(n)", source: "A", bars: 1, bpm: 120, startBeat: 0,
    buffer: b, waveform: WaveformOverview(buffer: b, columns: 40))
}

/// The newest temporary directory for a test's journal or library.
func fxTempDir() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "loopfx-\(UUID().uuidString)", isDirectory: true)
}

/// A recorded set on the demo loop: a one-bar take looping under the mixer, its FX set to
/// `first`, then changed to `second` mid-loop, then off. Returns the session and what played.
func loopFxSet(first: LoopFX, second: LoopFX, blocks: Int = 4500) throws -> (
  Session, RenderedAudio
) {
  let rate = 48_000.0
  let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
  dj.deterministic = true
  dj["A"]!.loadDemo()
  try dj.start()
  defer { dj.stop() }
  let router = ControllerRouter(engine: dj)
  let recorder = try SessionRecorder.start(on: dj)
  let conductor = OfflineConductor(engine: dj, router: router)
  var l: [Float] = []
  var r: [Float] = []
  let bar = Int(rate * 2) / OfflineConductor.blockFrames  // the demo loop is 120 bpm
  var id: String?
  for b in 0..<blocks {
    let (bl, br) = try conductor.step {
      switch b {
      case 0: dj.perform(.play(deck: "A", on: true))
      case bar + bar / 2: dj.perform(.loopRecord(deck: "A", on: true))
      case 2 * bar + bar / 2: dj.perform(.loopRecord(deck: "A", on: false))
      default: break
      }
      if id == nil, let c = dj.clips.first {
        id = c.id
        dj.perform(.clipFx(id: c.id, fx: first))
      }
      if let id, b == 4 * bar { dj.perform(.clipFx(id: id, fx: second)) }
      if let id, b == 5 * bar + 7 { dj.perform(.clipFx(id: id, fx: LoopFX())) }
    }
    l += bl
    r += br
  }
  return (recorder.finish(), RenderedAudio(sampleRate: rate, left: l, right: r))
}

/// Before / after for a human: the demo loop (two bars, 120 bpm) dry, then through each preset,
/// as float WAVs in `DJ_FX_WAV_DIR` (nothing without it). Returns the paths written.
func writeLoopFxWavs() -> [String] {
  guard let dir = ProcessInfo.processInfo.environment["DJ_FX_WAV_DIR"], !dir.isEmpty else {
    return []
  }
  let url = URL(fileURLWithPath: dir, isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  let loop = DemoLoop.make(sampleRate: 48_000)
  let frames = loop.length * 2  // twice round
  var written: [String] = []
  for (name, fx) in [("dry", LoopFX())] + LoopFX.presets.dropFirst().map({ ($0.name, $0.fx) }) {
    let out = FxBankRig([loop], fx: [fx]).render(frames)
    let file = url.appendingPathComponent(
      "demo-loop-" + name.lowercased().replacingOccurrences(of: " ", with: "-") + ".wav")
    let audio = RenderedAudio(sampleRate: 48_000, left: out.left, right: out.right)
    if (try? WAV.encode(audio, float32: true).write(to: file)) != nil { written.append(file.path) }
  }
  return written
}

/// The next `frames` frames of `deck` (an engine that is never started), in 512-frame blocks.
func renderDeck(_ deck: Deck, _ frames: Int) -> (left: [Float], right: [Float]) {
  var outL: [Float] = []
  var outR: [Float] = []
  var l = [Float](repeating: 0, count: 512)
  var r = [Float](repeating: 0, count: 512)
  var done = 0
  while done < frames {
    let n = min(512, frames - done)
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        deck.renderBlock(frames: n, left: lp.baseAddress!, right: rp.baseAddress!)
      }
    }
    outL += l[0..<n]
    outR += r[0..<n]
    done += n
  }
  return (outL, outR)
}

/// How far `x` is from `reference`: the difference's RMS against the reference's, dB.
func residualDB(_ x: [Float], _ reference: [Float]) -> Double {
  let diff = zip(x, reference).map { $0 - $1 }
  return dB(max(rms(diff), 1e-12) / max(rms(reference), 1e-12))
}
