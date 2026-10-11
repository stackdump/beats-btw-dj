@preconcurrency import AVFoundation
import Foundation
import Synchronization

@testable import DJCore

// Measurements on the real thing, for the FX response tests. No `Testing` import: Foundation
// and Testing do not mix on a Command-Line-Tools-only toolchain (see AllocationCounter.swift).

/// The AVAudioUnitEQ filter types the deck uses (the test files cannot name AVFoundation types).
enum EQShape: Sendable {
  case lowPass, highPass, lowShelf, highShelf, parametric

  var avType: AVAudioUnitEQFilterType {
    switch self {
    case .lowPass: .lowPass
    case .highPass: .highPass
    case .lowShelf: .lowShelf
    case .highShelf: .highShelf
    case .parametric: .parametric
    }
  }
}

/// |H(f)|² of one `AVAudioUnitEQ` band, measured: an impulse through a single band in an offline
/// engine, then the DFT of the 32768-sample response at each of `freqs`.
func measureEQBand(
  type shape: EQShape, frequency: Float, bandwidth: Float, gainDb: Float,
  sampleRate: Double, at freqs: [Double]
) -> [Double] {
  let engine = AVAudioEngine()
  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
  try! engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
  let eq = AVAudioUnitEQ(numberOfBands: 1)
  let band = eq.bands[0]
  band.filterType = shape.avType
  band.frequency = frequency
  band.bandwidth = bandwidth
  band.gain = gainDb
  band.bypass = false
  nonisolated(unsafe) var sent = false
  let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
    for b in UnsafeMutableAudioBufferListPointer(abl) {
      let p = b.mData!.assumingMemoryBound(to: Float.self)
      for i in 0..<Int(frames) { p[i] = 0 }
      if !sent { p[0] = 1 }
    }
    sent = true
    return noErr
  }
  engine.attach(source)
  engine.attach(eq)
  engine.connect(source, to: eq, format: format)
  engine.connect(eq, to: engine.mainMixerNode, format: format)
  try! engine.start()
  let n = 32768
  var response = [Float](repeating: 0, count: n)
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
  var done = 0
  while done < n {
    let chunk = min(4096, n - done)
    _ = try! engine.renderOffline(AVAudioFrameCount(chunk), to: buffer)
    let p = buffer.floatChannelData![0]
    for i in 0..<chunk { response[done + i] = p[i] }
    done += chunk
  }
  engine.stop()
  return freqs.map { f in
    var re = 0.0
    var im = 0.0
    let w = 2 * Double.pi * f / sampleRate
    for i in 0..<n {
      let x = Double(response[i])
      re += x * cos(w * Double(i))
      im -= x * sin(w * Double(i))
    }
    return re * re + im * im
  }
}

/// Output power over input power of a 0.5-amplitude sine of `freq` played by deck A of a
/// 22.05 kHz offline engine, after `setup` has put the deck and the mixer in some state. The
/// left channel of the engine's output, the last 40 % of 0.6 s.
func deckPowerGain(freq: Double, setup: (DJEngine, Deck) -> Void) throws -> Double {
  let sr = 22_050.0
  let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
  let deck = dj["A"]!
  let n = Int(sr * 0.6)
  let sine = (0..<n).map { Float(0.5 * sin(2 * Double.pi * freq * Double($0) / sr)) }
  deck.load(SampleBuffer(left: sine, sampleRate: sr), title: "sine")
  setup(dj, deck)
  deck.setPlaying(true)
  try dj.start()
  defer { dj.stop() }
  let buffer = makeEngineRenderBuffer(dj, frames: 2048)
  var out: [Float] = []
  while out.count < n {
    _ = try dj.engine.renderOffline(2048, to: buffer)
    let p = buffer.floatChannelData![0]
    out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(buffer.frameLength)))
  }
  let tail = out[(n * 6 / 10)..<n]
  let power = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
  return power / (0.5 * 0.5 / 2)
}

/// Seconds since an arbitrary start, for timing the render budget.
func wallSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Four threads inserting and reading one cache at once (the render queue and the main thread).
/// Every key belongs to one thread and every value says which key it was written for, in all of
/// its 33 rows; returns how many reads saw something else (a torn or misplaced kernel).
func hammer(_ cache: ModelKernelCache) -> Int {
  let bad = Mutex(0)
  DispatchQueue.concurrentPerform(iterations: 4) { t in
    for i in 0..<500 {
      let slot = i % 90
      let key = "t\(t)-\(slot)"
      let tag = Float(t * 1000 + slot)
      cache.insert(ModelKernel(r: [Float](repeating: tag, count: 33), tau: 0.05), for: key)
      // another thread may have evicted it by now; if it is there it must be whole and its own
      if let k = cache.kernel(for: key), k.r.count != 33 || k.r.contains(where: { $0 != tag }) {
        bad.withLock { $0 += 1 }
      }
      _ = cache.count
      _ = cache.keys
    }
  }
  return bad.withLock { $0 }
}

/// Run `condition` every few milliseconds until it holds or `seconds` of wall time pass.
@MainActor
func pollUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
  let end = wallSeconds() + seconds
  while wallSeconds() < end {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.005)
  }
  return condition()
}
