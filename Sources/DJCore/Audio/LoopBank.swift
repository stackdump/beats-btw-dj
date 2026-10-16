import Synchronization

/// Messages from the main thread to the loop bank's audio side.
enum LoopBankCommand: BitwiseCopyable {
  /// Start voice `voice` at deck frame `frame` (its turntable already loaded, looped and
  /// placed). A frame already past starts it at once.
  case start(voice: Int, frame: Int)
  /// Stop voice `voice` at deck frame `frame` (at once if past).
  case stop(voice: Int, frame: Int)
  case gain(voice: Int, Float)
}

/// The loop channel's source: several clips looping at once, each on its own voice (a
/// `Turntable` that only renders while its voice is on), summed. Starts and stops land on an
/// exact deck frame inside a block, so a clip comes in on the downbeat it was scheduled for.
///
/// Threading: `render` is the audio thread's (called from the loop channel's `DeckRenderer`).
/// `send`, the turntables' `send`/`load`, and the read-only mirrors are the main thread's.
final class LoopBank: @unchecked Sendable {
  static let voiceCount = 16
  let voices: [Turntable]
  private let commands = SPSCRing<LoopBankCommand>(capacity: 256)
  /// Audio → main: which voices are sounding, one bit each.
  private let activeBits = Atomic<UInt64>(0)

  // Audio-thread state.
  private var active: [Bool]
  private var startAt: [Int]
  private var stopAt: [Int]
  private var gains: [Float]
  private let scratchL: UnsafeMutablePointer<Float>
  private let scratchR: UnsafeMutablePointer<Float>
  private static let chunk = 4096

  init(sampleRate: Double) {
    voices = (0..<Self.voiceCount).map { _ in Turntable(sampleRate: sampleRate) }
    active = Array(repeating: false, count: Self.voiceCount)
    startAt = Array(repeating: -1, count: Self.voiceCount)
    stopAt = Array(repeating: -1, count: Self.voiceCount)
    gains = Array(repeating: 1, count: Self.voiceCount)
    scratchL = .allocate(capacity: Self.chunk)
    scratchR = .allocate(capacity: Self.chunk)
    scratchL.initialize(repeating: 0, count: Self.chunk)
    scratchR.initialize(repeating: 0, count: Self.chunk)
  }

  deinit {
    scratchL.deallocate()
    scratchR.deallocate()
  }

  // MARK: main thread

  func send(_ c: LoopBankCommand) { commands.push(c) }

  /// Is voice `v` sounding (as of the last block)?
  func isActive(_ v: Int) -> Bool { activeBits.load(ordering: .relaxed) & (1 << UInt64(v)) != 0 }

  var anyActive: Bool { activeBits.load(ordering: .relaxed) != 0 }

  // MARK: audio thread

  /// Render `frames` samples starting at deck frame `startFrame`, replacing `left`/`right`.
  func render(
    frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?,
    startFrame s: Int
  ) {
    while let c = commands.pop() {
      switch c {
      case .start(let v, let f):
        // on an active voice this only cancels a pending stop
        stopAt[v] = -1
        if !active[v] { startAt[v] = f }
      case .stop(let v, let f):
        startAt[v] = -1
        if active[v] { stopAt[v] = f }
      case .gain(let v, let g): gains[v] = g
      }
    }
    left.update(repeating: 0, count: n)
    right?.update(repeating: 0, count: n)
    var bits: UInt64 = 0
    for v in 0..<Self.voiceCount {
      var from = 0
      if !active[v] {
        guard startAt[v] >= 0, startAt[v] < s + n else { continue }
        from = max(0, startAt[v] - s)
        startAt[v] = -1
        active[v] = true
      }
      var to = n
      var stops = false
      if stopAt[v] >= 0, stopAt[v] < s + n {
        to = max(from, stopAt[v] - s)
        stops = true
      }
      mix(v, from: from, to: to, left: left, right: right)
      if stops {
        active[v] = false
        stopAt[v] = -1
      } else {
        bits |= 1 << UInt64(v)
      }
    }
    activeBits.store(bits, ordering: .relaxed)
  }

  private func mix(
    _ v: Int, from: Int, to: Int, left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>?
  ) {
    let g = gains[v]
    var i = from
    while i < to {
      let k = min(Self.chunk, to - i)
      voices[v].render(frames: k, left: scratchL, right: scratchR)
      for j in 0..<k { left[i + j] += scratchL[j] * g }
      if let right { for j in 0..<k { right[i + j] += scratchR[j] * g } }
      i += k
    }
  }
}
