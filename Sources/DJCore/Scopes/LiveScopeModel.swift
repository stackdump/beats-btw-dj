// LiveScopeModel: everything numeric and stateful behind the Scope / Live view (SPEC mode 1,
// scope.js `readWaveform`, `drawLive`, `timeAxis`, `drawGrid` at beats 095d030).
//
// No SwiftUI here. The pieces, each testable on its own:
//
//   LiveScopeGain      auto-gain: instant attack, 7 s release, and the spring that moves the
//                      DISPLAYED scale (the 095d030 law: k = 120, c = 9, semi-implicit Euler)
//   LiveScopeBlockRing 8192 blocks of (end time, min, max, mean square), 256 samples each
//   LiveScopeBlocks    the ring plus the cursor that cuts new blocks out of the feed's history
//   LiveScopeColumns   the per-pixel-column reduction of the ring over the 64-step window
//   LiveScopeScene     (LiveScopeScene.swift) every rect, line and label of a frame, in JS order
//   LiveScopeModel     the main-thread object a view holds: feed -> blocks -> gain -> scene
//   LiveScopeStore     one model per feed, kept while the host swaps views, sources and panels
//
// Time. The right edge of the axis is `feed.nowTime` (engine frames / sample rate, free-running;
// not the wall clock). Blocks are stamped with the engine time of their LAST sample, as the JS
// stamps them (`tNow - (FFT_SIZE - (a + BLOCK)) / sr`). The spring and the release use the REAL
// time between drawn frames (`wall`, injected), clamped to 50 ms: the JS mixed `performance.now()`
// with audio time in one variable (`s.lastT`); that bug is not copied.

import Foundation

// MARK: - auto-gain

/// The scope's auto-gain. `peak` follows the signal (attack at once, release `exp(-dt/7)`, floor
/// 0.05); `disp` is the scale the waveform is drawn at and chases `peak` on an underdamped
/// spring, so a gain change bounces instead of snapping. The drawn waveform is never clipped:
/// after a step in level it overshoots by exp(-pi*z/sqrt(1-z^2)), z = c / (2 sqrt k) = 0.411,
/// about 24 %.
public struct LiveScopeGain: Equatable, Sendable {
  /// Spring stiffness (unit mass).
  public static let springK = 120.0
  /// Spring damping.
  public static let springC = 9.0
  /// Time constant of the peak's release, seconds.
  public static let releaseSeconds = 7.0
  /// Lower bound of both `peak` and `disp`.
  public static let floor = 0.05
  /// Longest frame step the spring and the release take, seconds.
  public static let maxDt = 0.05
  /// `peak` and `disp` before any signal.
  public static let initial = 0.1

  /// The level the display is fitted to.
  public var peak: Double
  /// The scale the display currently uses (follows `peak` on the spring).
  public var disp: Double
  /// Velocity of `disp`.
  public var vel: Double

  public init() {
    peak = Self.initial
    disp = Self.initial
    vel = 0
  }

  public init(peak: Double, disp: Double, vel: Double = 0) {
    self.peak = peak
    self.disp = disp
    self.vel = vel
  }

  /// A block's peak: `if (pk > s.peak) s.peak = pk`.
  public mutating func attack(_ pk: Double) {
    if pk > peak { peak = pk }
  }

  /// One drawn frame: release the peak, then move `disp` one semi-implicit Euler step (velocity
  /// first). `dt` is the real time since the previous drawn frame, clamped to 0...0.05.
  public mutating func step(dt rawDt: Double) {
    let dt = rawDt.isNaN ? 0 : min(Self.maxDt, max(0, rawDt))
    peak = max(Self.floor, peak * exp(-dt / Self.releaseSeconds))
    let a = Self.springK * (peak - disp) - Self.springC * vel
    vel += a * dt
    disp = max(Self.floor, disp + vel * dt)
  }

  /// Pixels per unit of signal for a waveform half-band of `hTop`: `(hTop / 2 - 3) / disp`.
  public func scale(hTop: Double) -> Double { (hTop / 2 - 3) / disp }
}

// MARK: - blocks

/// One 256-sample block of the waveform ring (`wfT`, `wfMin`, `wfMax`, `wfSq`).
public struct LiveScopeBlock: Equatable, Sendable {
  /// Audio seconds of the block's last sample (`(first frame + 256) / sampleRate`).
  public var t: Double
  public var min: Float
  public var max: Float
  /// Mean of the squared samples.
  public var meanSq: Float

  public init(t: Double, min: Float, max: Float, meanSq: Float) {
    self.t = t
    self.min = min
    self.max = max
    self.meanSq = meanSq
  }
}

/// The newest 8192 blocks (scope.js `WF_CAP`).
public struct LiveScopeBlockRing: Sendable {
  public static let capacity = 8192

  // Allocated by the first push (a view makes a model on every body evaluation of its host; an
  // empty ring costs nothing).
  private var ts: [Double] = []
  private var mins: [Float] = []
  private var maxs: [Float] = []
  private var sqs: [Float] = []
  private var head = 0  // next write slot
  /// Blocks held (<= capacity).
  public private(set) var count = 0

  public init() {}

  public var isEmpty: Bool { count == 0 }

  public mutating func push(_ b: LiveScopeBlock) {
    if ts.isEmpty {
      ts = [Double](repeating: 0, count: Self.capacity)
      mins = [Float](repeating: 0, count: Self.capacity)
      maxs = [Float](repeating: 0, count: Self.capacity)
      sqs = [Float](repeating: 0, count: Self.capacity)
    }
    ts[head] = b.t
    mins[head] = b.min
    maxs[head] = b.max
    sqs[head] = b.meanSq
    head = (head + 1) % Self.capacity
    if count < Self.capacity { count += 1 }
  }

  /// The `k`-th newest block, `k = 1` being the newest (the JS walks `k = 1 ... wfCount`).
  public func block(newest k: Int) -> LiveScopeBlock {
    let i = (head - k + Self.capacity) % Self.capacity
    return LiveScopeBlock(t: ts[i], min: mins[i], max: maxs[i], meanSq: sqs[i])
  }

  public mutating func removeAll() {
    head = 0
    count = 0
  }
}

/// The ring and the cursor that cuts new blocks out of a feed's sample history.
public struct LiveScopeBlocks: Sendable {
  /// scope.js `BLOCK`.
  public static let blockSize = 256

  public private(set) var ring = LiveScopeBlockRing()
  /// Engine frame of the first sample that is not yet part of a block.
  public private(set) var cursor = 0

  public init() {}

  /// Empty the ring and continue from `frame`.
  public mutating func reset(at frame: Int) {
    ring.removeAll()
    cursor = frame
  }

  /// A cursor ahead of the history (it was reset backwards) can only be caught up by starting
  /// over at the history's edge.
  public mutating func clamp(toEnd frame: Int) {
    if cursor > frame { reset(at: frame) }
  }

  /// min, max and mean square of one block, as `readWaveform` reduces it: min starts at 1 and max
  /// at -1, the sum of squares runs in double precision and is stored as a float.
  public static func reduce(_ s: UnsafeBufferPointer<Float>) -> (
    min: Float, max: Float, meanSq: Float
  ) {
    var mn: Float = 1
    var mx: Float = -1
    var sq = 0.0
    for x in s {
      if x < mn { mn = x }
      if x > mx { mx = x }
      sq += Double(x) * Double(x)
    }
    return (mn, mx, Float(sq / Double(s.count)))
  }

  /// Cut every whole block out of `span` (samples that begin at engine frame `span.startFrame`,
  /// e.g. `feed.newSamples(since: cursor)`) into the ring and move the cursor past them; the rest
  /// stays for the next look. Returns the largest block peak `max(-min, max)` among the new
  /// blocks, nil if there were none. If the span does not start at the cursor (the history no
  /// longer reached back to it) the blocks start where the span does.
  @discardableResult
  public mutating func ingest(_ span: ScopeSamples, sampleRate: Double) -> Double? {
    let size = Self.blockSize
    let nb = span.samples.count / size
    guard nb > 0 else { return nil }
    var best = -Double.infinity
    span.samples.withUnsafeBufferPointer { buf in
      for b in 0..<nb {
        let r = Self.reduce(UnsafeBufferPointer(rebasing: buf[(b * size)..<((b + 1) * size)]))
        let end = span.startFrame + (b + 1) * size
        ring.push(
          LiveScopeBlock(t: Double(end) / sampleRate, min: r.min, max: r.max, meanSq: r.meanSq))
        best = Swift.max(best, Double(Swift.max(-r.min, r.max)))
      }
    }
    cursor = span.startFrame + nb * size
    return best
  }
}

// MARK: - columns

/// drawLive's per-pixel-column reduction: for every pixel column of the window the smallest
/// minimum, the largest maximum, the sum of the mean squares and the number of blocks.
public struct LiveScopeColumns: Sendable {
  /// Columns in use (`W | 0`).
  public private(set) var count = 0
  public private(set) var lo: [Float] = []
  public private(set) var hi: [Float] = []
  public private(set) var sq: [Float] = []
  public private(set) var blocks: [UInt16] = []

  public init() {}

  /// Walk the ring newest -> oldest until a block is older than the window's left edge; a block
  /// lands in column `floor(xOf(t))` if that is in `0 ..< W`.
  public mutating func reduce(_ ring: LiveScopeBlockRing, axis: ScopeTimeAxis, width: Double) {
    let n = width.isFinite && width > 0 ? Int(Swift.min(width, 65536)) : 0
    if lo.count < n {
      lo = [Float](repeating: 1, count: n)
      hi = [Float](repeating: -1, count: n)
      sq = [Float](repeating: 0, count: n)
      blocks = [UInt16](repeating: 0, count: n)
    }
    for i in 0..<n {
      lo[i] = 1
      hi[i] = -1
      sq[i] = 0
      blocks[i] = 0
    }
    count = n
    var k = 1
    while k <= ring.count {
      let b = ring.block(newest: k)
      k += 1
      if b.t < axis.t0 { break }
      let xf = axis.xOf(b.t).rounded(.down)
      guard xf >= 0, xf < Double(n) else { continue }
      let x = Int(xf)
      if b.min < lo[x] { lo[x] = b.min }
      if b.max > hi[x] { hi[x] = b.max }
      sq[x] += b.meanSq
      blocks[x] += 1
    }
  }
}

// MARK: - the model a view holds

/// State of one Scope / Live view over one feed. Get it from `LiveScopeStore` (so that it outlives
/// the view: the host builds a new view for every switch of scope kind, source or panel), then
/// every drawn frame call `update(feed:wall:)` and `scene(feed:width:height:)`.
@MainActor
public final class LiveScopeModel {
  public private(set) var gain = LiveScopeGain()
  public private(set) var blocks = LiveScopeBlocks()
  public private(set) var columns = LiveScopeColumns()
  /// Has `update` run? The first one starts the block cursor at what the feed already holds.
  public private(set) var started = false
  /// Wall-clock seconds of the previous update (nil before the first).
  public private(set) var lastFrameTime: Double?

  public init() {}

  /// One drawn frame, part 1: cut the samples that arrived since the last look into blocks
  /// (attack on their peaks), then take one step of release and spring with the real time since
  /// the previous update. `wall` is any monotonic clock in seconds (injected so tests are
  /// deterministic); the first update has no previous frame and steps by 0.
  public func update(feed: ScopeFeed, wall: Double) {
    // `feed.generation` is deliberately not watched. A generation bump (new track, restart,
    // re-acquire, lane-set change) invalidates what is indexed by lane (the fire log, which the
    // feed clears itself, and the lanes, anchors and sections, which this model reads afresh
    // every frame). The block ring is measured audio keyed by engine time: it stays true across
    // a track change, as the JS never clears it, and wiping it would blank the master waveform
    // of a deck that plays on whenever the other deck loads a track. A history that jumps
    // (re-acquire) leaves a gap in time, which `ingest` and `clamp` handle.
    var firstLook = false
    if !started {
      started = true
      firstLook = true
      // a new model over a feed that already listens: show what the feed still holds
      blocks.reset(at: feed.history.startFrame)
    }
    blocks.clamp(toEnd: feed.history.endFrame)
    if let pk = blocks.ingest(feed.newSamples(since: blocks.cursor), sampleRate: feed.sampleRate) {
      gain.attack(pk)
      if firstLook {
        // The spring starts at 0.1 and chases the first loud peak, a 7x oversize first frame (the
        // law's response to a step from silence). Here the audio was already playing before this
        // model existed: start fitted to it, so only a real change of level makes the bounce.
        gain.disp = gain.peak
        gain.vel = 0
      }
    }
    let dt = lastFrameTime.map { wall - $0 } ?? 0
    lastFrameTime = wall
    // drawLive returns before the gain step when the axis is unusable.
    if feed.timeAxis(x0: 0, w: 1).ok { gain.step(dt: dt) }
  }

  /// One drawn frame, part 2: everything to draw, from the state `update` left.
  public func scene(feed: ScopeFeed, width: Double, height: Double) -> LiveScopeScene {
    let axis = feed.timeAxis(x0: 0, w: width)
    columns.reduce(blocks.ring, axis: axis, width: width)
    return LiveScopeScene.make(
      width: width, height: height, axis: axis, columns: columns, gain: gain, lanes: feed.lanes,
      fires: feed.fireLog, sections: feed.sections, hasBlocks: !blocks.ring.isEmpty,
      running: feed.clock.playing)
  }
}

// MARK: - one model per feed

/// The models of the Scope / Live views, one per feed. In the JS the gain (`peak`, `disp`, `vel`)
/// and the waveform ring live in `el._scope` for the whole page; here a view is built anew for
/// every switch of scope kind or source (and its state with it), which would restart the spring
/// at 0.1 (an oversize flash) and throw away the four bars of waveform each time. A model kept
/// here survives that: its ring keeps filling whenever its view is on screen, and a gap while
/// another kind was shown simply stays a gap (blocks are stamped with engine time).
///
/// Keyed by the feed's identity and checked against a weak reference to it, so that an entry of a
/// feed that is gone is never handed to a new feed that happens to reuse its address.
@MainActor
public final class LiveScopeStore {
  public static let shared = LiveScopeStore()

  private struct Entry {
    weak var feed: ScopeFeed?
    let model: LiveScopeModel
  }

  private var entries: [ObjectIdentifier: Entry] = [:]

  public init() {}

  /// Models held for feeds that still exist.
  public var count: Int { entries.values.filter { $0.feed != nil }.count }

  /// The model of `feed`: the same object every time, made on the first ask.
  public func model(for feed: ScopeFeed) -> LiveScopeModel {
    let id = ObjectIdentifier(feed)
    if let e = entries[id], e.feed === feed { return e.model }
    entries = entries.filter { $0.value.feed != nil }  // forget the feeds that are gone
    let m = LiveScopeModel()
    entries[id] = Entry(feed: feed, model: m)
    return m
  }
}
