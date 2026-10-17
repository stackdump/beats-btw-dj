import Synchronization

/// Messages from the main thread to the loop bank's audio side.
enum LoopBankCommand: BitwiseCopyable {
  /// Start voice `voice` at deck frame `frame` (its turntable already loaded, looped and
  /// placed), its level rising from 0 over `fade` frames (0: at once). A frame already past
  /// starts it at once. On a voice already sounding it cancels a pending stop, and brings a
  /// fade-out back up (over `fade`, or the gain ramp).
  case start(voice: Int, frame: Int, fade: Int)
  /// Stop voice `voice` at deck frame `frame` (at once if past): with a `fade` it falls to 0
  /// over that many frames from there, sounding until it gets there.
  case stop(voice: Int, frame: Int, fade: Int)
  /// The voice's level (its gain × mute × solo): ramped to over `LoopBank.rampFrames`.
  case gain(voice: Int, Float)
  /// Voice `voice`'s level from deck frame `frame` (a scene's level for a clip already
  /// sounding, changed on the launch boundary), ramped to like `gain`. A plain `gain` cancels it.
  case gainAt(voice: Int, Float, frame: Int)
}

/// The loop channel's source: several clips looping at once, each on its own voice (a
/// `Turntable` that only renders while its voice is on), summed. Starts and stops land on an
/// exact deck frame inside a block, so a clip comes in on the downbeat it was scheduled for.
///
/// Each voice's output is scaled per sample by its level × its envelope. The level follows the
/// main thread's gain over a short ramp (no zipper clicks from the slider, mute or solo); the
/// envelope is the start / stop fade, 0…1. A muted voice keeps rendering, so it keeps its place
/// in the loop.
///
/// Threading: `render` is the audio thread's (called from the loop channel's `DeckRenderer`).
/// `send`, the turntables' `send`/`load`, and the read-only mirrors are the main thread's.
final class LoopBank: @unchecked Sendable {
  static let voiceCount = 16
  let voices: [Turntable]
  /// Frames a level change takes: ~5 ms.
  let rampFrames: Int
  private let commands = SPSCRing<LoopBankCommand>(capacity: 256)
  /// Audio → main: which voices are sounding, one bit each.
  private let activeBits = Atomic<UInt64>(0)

  // Audio-thread state, one entry per voice.
  private var active: [Bool]
  private var startAt: [Int]
  private var startFade: [Int]
  private var stopAt: [Int]
  private var stopFade: [Int]
  /// The level: where it is, where it is going, by how much per sample, and for how many more
  /// samples (it lands on the target exactly when that runs out).
  private var level: [Float]
  private var levelTarget: [Float]
  private var levelStep: [Float]
  private var levelLeft: [Int]
  /// A level change waiting for its frame (`gainAt`): the level, and the frame (-1: none).
  private var pendingGains: [Float]
  private var gainFrames: [Int]
  /// The fade envelope, 0…1, its step per sample (> 0 fading in, < 0 fading out) and the
  /// samples to go.
  private var envelope: [Float]
  private var envelopeStep: [Float]
  private var envelopeLeft: [Int]
  private let scratchL: UnsafeMutablePointer<Float>
  private let scratchR: UnsafeMutablePointer<Float>
  private static let chunk = 4096

  init(sampleRate: Double) {
    voices = (0..<Self.voiceCount).map { _ in Turntable(sampleRate: sampleRate) }
    rampFrames = max(1, Int(sampleRate * 0.005))
    let n = Self.voiceCount
    active = Array(repeating: false, count: n)
    startAt = Array(repeating: -1, count: n)
    startFade = Array(repeating: 0, count: n)
    stopAt = Array(repeating: -1, count: n)
    stopFade = Array(repeating: 0, count: n)
    level = Array(repeating: 1, count: n)
    levelTarget = Array(repeating: 1, count: n)
    levelStep = Array(repeating: 0, count: n)
    levelLeft = Array(repeating: 0, count: n)
    pendingGains = Array(repeating: 1, count: n)
    gainFrames = Array(repeating: -1, count: n)
    envelope = Array(repeating: 1, count: n)
    envelopeStep = Array(repeating: 0, count: n)
    envelopeLeft = Array(repeating: 0, count: n)
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

  /// Is voice `v` sounding (as of the last block)? A voice fading out still is.
  func isActive(_ v: Int) -> Bool { activeBits.load(ordering: .relaxed) & (1 << UInt64(v)) != 0 }

  var anyActive: Bool { activeBits.load(ordering: .relaxed) != 0 }

  // MARK: audio thread

  /// Render `frames` samples starting at deck frame `startFrame`, replacing `left`/`right`.
  func render(
    frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?,
    startFrame s: Int
  ) {
    while let c = commands.pop() { apply(c) }
    left.update(repeating: 0, count: n)
    right?.update(repeating: 0, count: n)
    var bits: UInt64 = 0
    for v in 0..<Self.voiceCount {
      var from = 0
      // a voice that is not sounding takes a level change due in this block at once
      if !active[v], gainFrames[v] >= 0, gainFrames[v] < s + n { applyPendingGain(v) }
      if !active[v] {
        guard startAt[v] >= 0, startAt[v] < s + n else { continue }
        from = max(0, startAt[v] - s)
        startAt[v] = -1
        active[v] = true
        let f = startFade[v]
        envelope[v] = f > 0 ? 0 : 1
        envelopeStep[v] = f > 0 ? 1 / Float(f) : 0
        envelopeLeft[v] = f
      }
      var to = n
      var stops = false
      if stopAt[v] >= 0, stopAt[v] < s + n {
        let at = max(from, stopAt[v] - s)
        stopAt[v] = -1
        if stopFade[v] > 0 {
          // sound on to the stop, then fall from wherever the envelope is to 0 over the fade
          stops = mixAcrossGain(v, from: from, to: at, start: s, left: left, right: right)
          ramp(v, to: 0, over: stopFade[v])
          from = stops ? n : at
        } else {
          to = at
          stops = true
        }
      }
      if from < to, mixAcrossGain(v, from: from, to: to, start: s, left: left, right: right) {
        stops = true
      }
      if stops {
        active[v] = false
        envelopeStep[v] = 0
        envelopeLeft[v] = 0
      } else {
        bits |= 1 << UInt64(v)
      }
    }
    activeBits.store(bits, ordering: .relaxed)
  }

  private func apply(_ c: LoopBankCommand) {
    switch c {
    case .start(let v, let f, let fade):
      stopAt[v] = -1
      if !active[v] {
        startAt[v] = f
        startFade[v] = fade
      } else if envelopeStep[v] < 0 || envelope[v] < 1 {
        // on its way out: back up
        ramp(v, to: 1, over: max(fade, rampFrames))
      }
    case .stop(let v, let f, let fade):
      startAt[v] = -1
      if active[v] {
        stopAt[v] = f
        stopFade[v] = fade
      }
    case .gain(let v, let g):
      gainFrames[v] = -1
      setLevel(v, g)
    case .gainAt(let v, let g, let f):
      pendingGains[v] = g
      gainFrames[v] = f
    }
  }

  /// Head voice `v`'s level for `g`: over the ramp while it sounds, at once while it is silent
  /// (nothing to ramp from) or already there.
  private func setLevel(_ v: Int, _ g: Float) {
    levelTarget[v] = g
    if active[v] && g != level[v] {
      levelStep[v] = (g - level[v]) / Float(rampFrames)
      levelLeft[v] = rampFrames
    } else {
      level[v] = g
      levelStep[v] = 0
      levelLeft[v] = 0
    }
  }

  private func applyPendingGain(_ v: Int) {
    setLevel(v, pendingGains[v])
    gainFrames[v] = -1
  }

  /// `mix`, with a `gainAt` due inside `from..<to` (block starting at deck frame `s`) taking
  /// effect on its frame: the part before it at the old level, the ramp from there.
  private func mixAcrossGain(
    _ v: Int, from: Int, to: Int, start s: Int, left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>?
  ) -> Bool {
    let g = gainFrames[v]
    guard g >= 0, g - s < to else { return mix(v, from: from, to: to, left: left, right: right) }
    let k = min(max(from, g - s), to)
    if mix(v, from: from, to: k, left: left, right: right) { return true }
    applyPendingGain(v)
    return mix(v, from: k, to: to, left: left, right: right)
  }

  /// Move voice `v`'s envelope from where it is to `target` (0 or 1) over `frames` samples.
  private func ramp(_ v: Int, to target: Float, over frames: Int) {
    let f = max(1, frames)
    envelopeStep[v] = (target - envelope[v]) / Float(f)
    envelopeLeft[v] = f
    if envelopeStep[v] == 0 { envelopeStep[v] = target > 0 ? .ulpOfOne : -.ulpOfOne }
  }

  /// Add voice `v`'s frames `from..<to` to the output at its level × envelope, moving both on
  /// per sample. Returns true if a fade-out reached 0 on the way (the rest is not added).
  private func mix(
    _ v: Int, from: Int, to: Int, left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>?
  ) -> Bool {
    var lv = level[v]
    let ls = levelStep[v]
    var ln = levelLeft[v]
    let lt = levelTarget[v]
    var e = envelope[v]
    var es = envelopeStep[v]
    var en = envelopeLeft[v]
    var ended = false
    var i = from
    while i < to && !ended {
      let k = min(Self.chunk, to - i)
      voices[v].render(frames: k, left: scratchL, right: scratchR)
      for j in 0..<k {
        let g = lv * e
        left[i + j] += scratchL[j] * g
        if let right { right[i + j] += scratchR[j] * g }
        if ln > 0 {
          ln -= 1
          lv = ln == 0 ? lt : lv + ls
        }
        if en > 0 {
          en -= 1
          e += es
          if en == 0 {
            // landed: exactly on 1, or on 0 and out
            e = es > 0 ? 1 : 0
            ended = es < 0
            es = 0
            if ended { break }
          }
        }
      }
      i += k
    }
    level[v] = lv

    levelLeft[v] = ln
    envelope[v] = e
    envelopeStep[v] = es
    envelopeLeft[v] = en
    return ended
  }
}
