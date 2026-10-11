import Testing

@testable import DJCore

// The stage model against real offline engines (shared by the stage test files).

/// An offline rig with a stage model over it. The model's random source is seeded.
@MainActor
final class StageHarness {
  let rig: ScopeRig
  let model: StageModel
  let width = 1000.0
  let height = 800.0
  private(set) var now = 100.0
  /// Every frame's context, oldest first.
  private(set) var frames: [StageContext] = []

  /// One render block: 1102 frames, 49.98 ms (a step at 300 BPM is 50 ms).
  static let block = 1102
  static let blockSeconds = Double(block) / ScopeRig.rate

  init(
    net: [String] = ["A"], samples: [String] = [], source: ScopeSource = .deck("A"),
    structure: String = "standard", seed: Double = 42, play: Bool = true, attach: Bool = true
  ) throws {
    rig = try ScopeRig(
      net: net, samples: samples, genre: "techno", seed: seed, structure: structure, tempo: 300,
      play: play, block: Self.block)
    var rng = StageSeededRandom(seed: 11)
    model = StageModel(hub: rig.hub, random: { rng.next() })
    model.settings.source = source
    if attach { model.attach() }
  }

  /// `blocks` frames of the model, each one render block of audio.
  func step(_ blocks: Int = 1) {
    for _ in 0..<max(1, blocks) {
      rig.render(frames: Self.block)
      now += Self.blockSeconds
      model.advance(now: now, dt: Self.blockSeconds, width: width, height: height)
      frames.append(model.context)
    }
  }

  func run(_ seconds: Double) { step(Int((seconds / Self.blockSeconds).rounded())) }

  var ctx: StageContext { model.context }
  var deck: Deck { rig.dj["A"]! }

  func stop() {
    model.detach()
    rig.stop()
  }
}

@MainActor
final class SpyLayer: StageLayerModel {
  var advances = 0
  var resets = 0
  var last: StageContext?

  func advance(_ context: StageContext) {
    advances += 1
    last = context
  }

  func reset() { resets += 1 }
}
