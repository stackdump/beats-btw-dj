@preconcurrency import AVFoundation
import Foundation

@testable import DJCore

// Measurement helpers for the model's feed tests. No `Testing` import: Foundation and Testing do
// not mix on a Command-Line-Tools-only toolchain (see AllocationCounter.swift).

/// Energy of the samples a feed's history takes in between `update()` calls: the time domain
/// Σ x² the model's E is meant to predict (Parseval).
@MainActor
final class EnergyMeter {
  private let feed: ScopeFeed
  private var cursor: Int
  private(set) var total = 0.0
  init(_ feed: ScopeFeed) {
    self.feed = feed
    cursor = feed.history.endFrame
  }
  func update() {
    let s = feed.newSamples(since: cursor)
    cursor = s.endFrame
    for x in s.samples { total += Double(x) * Double(x) }
  }
}

/// Every sample a feed's history takes in, kept with its engine frame, so that the energy of any
/// stretch of the run can be taken per model row afterwards (the measured side of the model).
@MainActor
final class SampleRecorder {
  private let feed: ScopeFeed
  private var cursor: Int
  /// Engine frame of `samples[0]`.
  let startFrame: Int
  private(set) var samples: [Float] = []

  init(_ feed: ScopeFeed) {
    self.feed = feed
    cursor = feed.history.endFrame
    startFrame = cursor
  }

  func update() {
    let s = feed.newSamples(since: cursor)
    precondition(s.missed == 0 && (samples.isEmpty || s.startFrame == cursor), "contiguous")
    samples.append(contentsOf: s.samples)
    cursor = s.endFrame
  }

  /// The energy per model row (33 values: 5 bands, 28 bins) of the frames `from ..< to`, the sum
  /// of the kernel analysis over consecutive 32768-sample windows (Parseval within each).
  func rows(from: Int, to: Int, sampleRate: Double) -> [Double] {
    let a = max(0, from - startFrame)
    let b = min(samples.count, to - startFrame)
    var out = [Double](repeating: 0, count: ModelGrid.nr)
    guard b > a else { return out }
    let slice = Array(samples[a..<b])
    var k = 0
    while k < slice.count {
      let r = ModelKernels.analyseHit(slice, start: k, sampleRate: sampleRate).r
      for j in 0..<ModelGrid.nr { out[j] += Double(r[j]) }
      k += ModelKernels.fftN
    }
    return out
  }

  /// Σ x² of the frames `from ..< to`.
  func energy(from: Int, to: Int) -> Double {
    let a = max(0, from - startFrame)
    let b = min(samples.count, to - startFrame)
    guard b > a else { return 0 }
    var e = 0.0
    for i in a..<b { e += Double(samples[i]) * Double(samples[i]) }
    return e
  }
}

/// An offline engine with net decks playing composed songs, at a sample rate of the test's choice
/// (`ScopeRig` is fixed at 22.05 kHz). Same recipe as `ScopeRig`: the decks play from the start,
/// a feed must be acquired BEFORE rendering.
@MainActor
final class ModelRig {
  let dj: DJEngine
  let hub: ScopeHub
  let rate: Double
  private let buffer: AVAudioPCMBuffer
  private let block = 512

  init(
    net: [String] = ["A"], genre: String = "techno", seed: Double = 42, tempo: Double = 120,
    rate: Double = 44_100
  ) throws {
    self.rate = rate
    let names = net.sorted()
    dj = try DJEngine(decks: names, offline: true, sampleRate: rate)
    buffer = makeEngineRenderBuffer(dj, frames: block)
    for (i, name) in names.enumerated() {
      let d = dj[name]!
      d.loadNet(scopeProject(genre, seed: seed + Double(i)))
      d.wave.setTempo(tempo)
      d.setPlaying(true)
    }
    hub = ScopeHub(engine: dj)
    try dj.start()
  }

  func stop() { dj.stop() }

  func render(seconds: Double) {
    pullEngine(
      dj, buffer, cycles: max(1, Int((seconds * rate / Double(block)).rounded(.up))), frames: block)
  }
}
