// Main-thread history buffers of a scope feed: the fire log (scope.js event ring, `EV_CAP`) and
// the mono sample history (the analyser's window and the waveform's source). Pure value types:
// no engine, no threads, tested on their own.

/// One audible hit, as the scopes keep it (the columns of scope.js's event ring).
public struct ScopeFire: Equatable, Sendable {
  /// Audio seconds: `frame / sampleRate`.
  public var time: Double
  /// Engine frame at which the hit sounds.
  public var frame: Int
  /// Index into the feed's `lanes` (on a master feed: the concatenation of both decks' lanes).
  public var lane: Int
  /// Net and transition indices into the layout of `generation`.
  public var net: Int
  public var transition: Int
  /// MIDI note 0...127 (`note & 127`).
  public var note: Int
  /// 1...127: the bound velocity, 0 meaning 100, clamped like scope.js.
  public var velocity: Int
  /// How long the note sounds, in seconds.
  public var durSec: Double
  /// The channel that played it.
  public var channel: Int
  /// Song step: `tick - 1`.
  public var step: Int
  /// The engine generation (project) it came from.
  public var generation: Int32
  public var flags: FireFlags

  public init(
    time: Double, frame: Int, lane: Int, net: Int, transition: Int, note: Int, velocity: Int,
    durSec: Double, channel: Int, step: Int, generation: Int32, flags: FireFlags = []
  ) {
    self.time = time
    self.frame = frame
    self.lane = lane
    self.net = net
    self.transition = transition
    self.note = note
    self.velocity = velocity
    self.durSec = durSec
    self.channel = channel
    self.step = step
    self.generation = generation
    self.flags = flags
  }
}

/// A ring of the last 4096 fires with a monotonically increasing count, so that a consumer can
/// iterate "since my last look": remember `total`, and next frame walk `numbers(since:)`.
///
/// Fire number `n` is the n-th fire ever logged (0-based). The log keeps the newest
/// `capacity` of them; a consumer that fell further behind than that skips the rest. A consumer
/// whose remembered number is AHEAD of `total` (it was looking at some other log) is treated as
/// caught up, not trapped on: `numbers(since:)` is then empty.
public struct ScopeFireLog: Sendable {
  /// scope.js `EV_CAP`.
  public static let capacity = 4096

  private var storage: [ScopeFire] = []
  /// The number the next fire gets == fires ever logged. scope's `fireCount`.
  public private(set) var total = 0
  private var floor = 0  // numbers below this were cleared

  public init() { storage.reserveCapacity(Self.capacity) }

  /// The oldest fire number still held.
  public var firstNumber: Int { max(floor, total - Self.capacity) }
  /// How many fires are held.
  public var count: Int { total - firstNumber }
  public var isEmpty: Bool { count == 0 }

  public mutating func append(_ f: ScopeFire) {
    if storage.count < Self.capacity {
      storage.append(f)
    } else {
      storage[total % Self.capacity] = f
    }
    total += 1
  }

  /// Forget everything held (a new track's lanes mean something else). `total` keeps counting, so
  /// a consumer's remembered number stays valid and simply finds nothing new.
  public mutating func removeAll() {
    floor = total
  }

  /// Fire number `n`, nil if it was overwritten, cleared, or has not happened.
  public func fire(number n: Int) -> ScopeFire? {
    guard n >= firstNumber, n < total else { return nil }
    return storage[n % Self.capacity]
  }

  /// The numbers of the fires logged since the consumer last looked at `total == n`, oldest
  /// first. Anything already overwritten is skipped (`lostSince` says how much). An `n` beyond
  /// `total` gives an empty range.
  public func numbers(since n: Int) -> Range<Int> {
    min(max(n, firstNumber), total)..<total
  }

  /// How many fires between `n` and now were overwritten or cleared before the consumer could
  /// look.
  public func lostSince(_ n: Int) -> Int { max(0, firstNumber - n) }

  /// Newest first, as scope.js's drawing loop walks it. `body` returns false to stop.
  public func forEachNewestFirst(_ body: (ScopeFire) -> Bool) {
    var n = total - 1
    while n >= firstNumber {
      if !body(storage[n % Self.capacity]) { return }
      n -= 1
    }
  }
}

/// A span of mono samples with its place on the engine's frame axis.
public struct ScopeSamples: Equatable, Sendable {
  /// Engine frame of `samples[0]`.
  public var startFrame: Int
  public var samples: [Float]
  /// Frames between the frame asked for and `startFrame` that the history no longer holds.
  public var missed: Int

  public init(startFrame: Int, samples: [Float], missed: Int = 0) {
    self.startFrame = startFrame
    self.samples = samples
    self.missed = missed
  }

  public var endFrame: Int { startFrame + samples.count }
}

/// The newest mono samples of a stream, addressed by absolute engine frame. The data comes from
/// a `ScopeTap` (drained once per UI frame); this keeps the last `capacity` of them.
///
/// Contiguous by construction: if the tap lost samples (the consumer fell more than a ring
/// behind) or inserted silence for a gap, the hole is filled with zeros, so
/// `sample at frame f` is always `storage[f]`. `lostFrames` counts the zero-filled frames that
/// stand in for lost samples.
public struct ScopeSampleHistory: Sendable {
  /// 32768 samples: two 4096-sample analyser windows and slack, ~0.7 s at 48 kHz. (scope.js's
  /// 8192-entry ring holds 256-sample blocks; a mode builds those from `newSamples(since:)`.)
  public static let defaultCapacity = 1 << 15

  public let capacity: Int
  private var ring: [Float]
  /// Engine frame after the newest sample (0 before any).
  public private(set) var endFrame = 0
  /// Samples held (≤ capacity).
  public private(set) var count = 0
  /// Frames filled with zeros because the tap lost them.
  public private(set) var lostFrames = 0

  public init(capacity: Int = ScopeSampleHistory.defaultCapacity) {
    self.capacity = max(1, capacity)
    ring = [Float](repeating: 0, count: self.capacity)
  }

  /// Engine frame of the oldest held sample.
  public var startFrame: Int { endFrame - count }
  public var isEmpty: Bool { count == 0 }

  /// Start over, empty, with the right edge at `frame`.
  public mutating func reset(at frame: Int) {
    endFrame = frame
    count = 0
    lostFrames = 0
  }

  @inline(__always) private func slot(_ f: Int) -> Int {
    let m = f % capacity
    return m < 0 ? m + capacity : m
  }

  /// Append samples at the right edge.
  public mutating func append(_ s: UnsafeBufferPointer<Float>) {
    let n = s.count
    guard n > 0 else { return }
    let keep = min(n, capacity)
    let skipped = n - keep
    for i in 0..<keep { ring[slot(endFrame + skipped + i)] = s[skipped + i] }
    endFrame += n
    count = min(capacity, count + n)
  }

  public mutating func append(_ s: [Float]) { s.withUnsafeBufferPointer { append($0) } }

  /// Append `n` zeros at the right edge for samples the tap lost.
  public mutating func appendLost(_ n: Int) {
    guard n > 0 else { return }
    lostFrames += n
    let keep = min(n, capacity)
    for i in 0..<keep { ring[slot(endFrame + (n - keep) + i)] = 0 }
    endFrame += n
    count = min(capacity, count + n)
  }

  /// Everything newer than `frame` (the consumer's right edge from last time). If the history no
  /// longer reaches back to `frame`, starts at the oldest held sample and says how many frames
  /// were missed. A `frame` at or after the right edge gives an empty span at the edge.
  public func newSamples(since frame: Int) -> ScopeSamples {
    let from = max(frame, startFrame)
    if from >= endFrame { return ScopeSamples(startFrame: endFrame, samples: []) }
    var out = [Float](repeating: 0, count: endFrame - from)
    for i in 0..<out.count { out[i] = ring[slot(from + i)] }
    return ScopeSamples(startFrame: from, samples: out, missed: max(0, startFrame - frame))
  }

  /// The `count` samples that end just before frame `endingAt` (default: the right edge), oldest
  /// first. Where the history does not reach (before its oldest sample, or past its right edge)
  /// the window is zero-padded, like an under-filled analyser buffer.
  public func window(count n: Int, endingAt end: Int? = nil) -> [Float] {
    var out = [Float](repeating: 0, count: max(0, n))
    out.withUnsafeMutableBufferPointer { copyWindow(into: $0, endingAt: end) }
    return out
  }

  /// `window` into a caller's buffer (no allocation): fills all of `out`.
  public func copyWindow(into out: UnsafeMutableBufferPointer<Float>, endingAt end: Int? = nil) {
    let e = end ?? endFrame
    let s = e - out.count
    for i in 0..<out.count {
      let f = s + i
      out[i] = f >= startFrame && f < endFrame ? ring[slot(f)] : 0
    }
  }
}
