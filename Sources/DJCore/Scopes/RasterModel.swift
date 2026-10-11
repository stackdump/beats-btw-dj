// Raster (SPEC mode 6): the whole arrangement ticked offline. A port of scope.js `computeRaster`.
//
// The score of a track as a marked point process: every net of the project is compiled and
// ticked from the top on its own, without audio, and each audible fired transition is recorded as
// (step, lane, note, velocity, length in steps). The executor is the engine's own `WaveGraph`
// (the Swift port of beats' wave-engine/net.js `compileProject` / `tick`); nothing of net
// execution is re-implemented here. `RasterModel.compute` is pure and deterministic and runs off
// the main thread (`RasterController` schedules it and ignores a result whose project has since
// been replaced).
//
// Arranged track (the project has a `structure`): `steps` is the sum of the sections' steps (else
// 256), at most 1024 bars. Loop project (no structure): one cycle of the nets: ticked until, on a
// bar line, every net's marking AND the mute table are back where they started, at most 64
// bars. If they never are, `steps` stays 64 bars and `cycle` is 0 ("loop (no repeat)").
//
// Cost: `WaveGraph.advance` looks at every transition of every net on every tick, and a composed
// arrangement carries nets with a transition per arrangement step (the fills, the feel curve), so
// the compute grows with the square of the length (the JS executor does the same). Measured in a
// release build: composed techno of 416 / 896 / 1408 steps (2990 / 6252 / 11757 transitions)
// takes 12 / 27 / 60 ms; nine nets with a transition per step take 46 ms at 1024 steps, 373 ms at
// 4096 and 4.6 s at 16384 (the cap). A debug build is tens of times slower. `compute` therefore
// reports its progress (`RasterProgress`, shown in the status line) and can be cancelled.
//
// Deviations from the JS, on purpose:
//  * the event arrays grow instead of being allocated at the 262144 capacity up front; the cap is
//    the same and events beyond it are counted in `dropped` (the JS drops them silently);
//  * `compute` can be cancelled (`isCancelled`, polled every 64 ticks): the result is then flagged
//    `cancelled` and must be ignored;
//  * the loop comparison does not look at `mutedNotes` / `mutedGroups`, exactly like the JS
//    `atStart`, which only compares `g.muted`;
//  * the sum of the sections' steps saturates instead of trapping on a hostile project;
//  * there is no `fallbackSteps`: the JS `el._totalSteps` is the very same sum of the sections'
//    steps (canvas.js sets it from `sections.reduce`), so its fallback only ever applies to a
//    stale value from an earlier track. A sum of nothing falls to 256 as in the JS.

import Foundation
import Synchronization

/// The events of one arrangement, as parallel arrays (JS `r`).
public struct RasterResult: Equatable, Sendable {
  /// Length of the raster in steps (JS `r.steps`): the arrangement, or the loop's cycle.
  public var steps: Int
  /// Step each event fired on (`tick - 1` numbering: the first tick is step 0).
  public var step: [Int32] = []
  /// Index into the lanes the compute was given.
  public var lane: [UInt8] = []
  /// MIDI note, `& 127`.
  public var note: [UInt8] = []
  /// Velocity, 1...127 (0 meant 100).
  public var vel: [UInt8] = []
  /// Length in steps.
  public var dur: [Float] = []
  /// Wall time of the compute in milliseconds (compile included).
  public var ms = 0
  /// A loop project (no structure).
  public var loop = false
  /// Loop projects: the cycle found, in steps (a multiple of 16); 0 when the marking never came
  /// home within 64 bars.
  public var cycle = 0
  /// Events with a lane that did not fit in the event capacity.
  public var dropped = 0
  /// `compute` was told to stop; the rest of the fields describe a partial run.
  public var cancelled = false
  public var failed = false
  public var error = ""

  public init(steps: Int) { self.steps = steps }

  /// Events recorded (JS `r.n`).
  public var count: Int { step.count }

  /// scope.js `computeRaster` failure: `{ steps: 16, n: 0, ms: 0, failed: true, error }`.
  public static func failure(_ message: String) -> RasterResult {
    var r = RasterResult(steps: 16)
    r.failed = true
    r.error = String(message.prefix(80))
    return r
  }

  /// Everything but `ms` is equal (two computes of the same input take different times).
  public func sameContent(as other: RasterResult) -> Bool {
    var a = self
    a.ms = other.ms
    return a == other
  }
}

/// What a compute needs, in one value that can cross to a background task. `Project` is a value
/// type made of value types, but is not declared `Sendable`; this is the one place that says so.
public struct RasterInput: @unchecked Sendable {
  public var project: Project
  public var structure: [Section]
  public var tempo: Double
  public var laneOf: [String: Int]

  public init(project: Project, structure: [Section], tempo: Double, laneOf: [String: Int]) {
    self.project = project
    self.structure = structure
    self.tempo = tempo
    self.laneOf = laneOf
  }
}

/// How far a running compute has got, readable from any thread (the compute writes it every 64
/// ticks; the panel's status line reads it). `total` is the horizon the compute works to: the
/// arrangement's length, or for a loop the 64 bars it looks in (a loop usually stops far sooner).
public final class RasterProgress: Sendable {
  private let doneTicks = Atomic<Int>(0)
  private let totalTicks = Atomic<Int>(0)

  public init() {}

  func begin(total: Int) {
    doneTicks.store(0, ordering: .relaxed)
    totalTicks.store(total, ordering: .relaxed)
  }

  func report(done: Int) { doneTicks.store(done, ordering: .relaxed) }

  /// 0...1.
  public var fraction: Double {
    let total = totalTicks.load(ordering: .relaxed)
    guard total > 0 else { return 0 }
    return max(0, min(1, Double(doneTicks.load(ordering: .relaxed)) / Double(total)))
  }

  /// Whole percent, 0...100 (rounded down: 100 only once the compute is through). Integer
  /// arithmetic, so 64 of 640 ticks is exactly 10.
  public var percent: Int {
    let total = totalTicks.load(ordering: .relaxed)
    guard total > 0 else { return 0 }
    return max(0, min(100, doneTicks.load(ordering: .relaxed) * 100 / total))
  }
}

public enum RasterModel {
  /// scope.js `MAX_BARS`: an arrangement is at most this many bars.
  public static let maxBars = 1024
  /// scope.js `LOOP_MAX_BARS`: a loop is looked for in this many bars.
  public static let loopMaxBars = 64
  /// scope.js `cap`.
  public static let eventCapacity = 262_144
  public static let stepsPerBar = 16

  public static func compute(
    _ input: RasterInput, progress: RasterProgress? = nil, isCancelled: () -> Bool = { false }
  ) -> RasterResult {
    compute(
      project: input.project, structure: input.structure, tempo: input.tempo,
      laneOf: input.laneOf, progress: progress, isCancelled: isCancelled)
  }

  /// Tick `project` from the top and record its events.
  ///
  /// - `structure`: the project's sections (`project.structure`); empty means a loop.
  /// - `tempo`: BPM that turns a binding's millisecond length into steps (JS `tickSecOf`; a bad
  ///   value means 120).
  /// - `laneOf`: net id -> lane index (`ScopeLaneSet.laneOf`); nets not in it record nothing.
  /// - `capacity`: event capacity (tests lower it).
  /// - `progress`: told how many ticks are done, every 64 ticks.
  public static func compute(
    project: Project, structure: [Section], tempo: Double, laneOf: [String: Int],
    capacity: Int = eventCapacity, progress: RasterProgress? = nil,
    isCancelled: () -> Bool = { false }
  ) -> RasterResult {
    let t0 = ContinuousClock.now
    let g = WaveGraph(project: project)
    // The reversible history is for the live clock; nothing here ever steps back.
    g.recording = false

    let loop = structure.isEmpty
    var total = loop ? loopMaxBars * stepsPerBar : saturatingSum(structure.map(\.steps))
    if !(total > 0) { total = 16 * stepsPerBar }
    total = min(total, maxBars * stepsPerBar)
    progress?.begin(total: total)

    var laneOfNet = [Int](repeating: -1, count: g.nets.count)
    for n in g.nets {
      if let l = laneOf[n.id], l >= 0, l <= Int(UInt8.max) { laneOfNet[n.index] = l }
    }
    let muted0 = g.muted  // copied now: the comparison below must see the starting table
    let tickMs = ScopeClock.tickSec(forTempo: tempo) * 1000

    var r = RasterResult(steps: total)
    r.loop = loop
    let reserve = max(0, min(capacity, 4096))
    r.step.reserveCapacity(reserve)
    r.lane.reserveCapacity(reserve)
    r.note.reserveCapacity(reserve)
    r.vel.reserveCapacity(reserve)
    r.dur.reserveCapacity(reserve)
    var dropped = 0

    var cur = 0
    while cur < total {
      if cur & 63 == 0 {
        progress?.report(done: cur)
        if isCancelled() {
          r.cancelled = true
          break
        }
      }
      g.advance { n, t in
        let l = laneOfNet[n.index]
        if l < 0 { return }
        if r.step.count >= capacity {
          dropped += 1
          return
        }
        r.step.append(Int32(truncatingIfNeeded: cur))
        r.lane.append(UInt8(l))
        r.note.append(UInt8(n.note[t] & 127))
        r.vel.append(UInt8(max(1, min(127, n.vel[t] == 0 ? 100 : n.vel[t]))))
        let steps = n.durSteps[t]
        let ms = n.durMs[t] == 0 ? 100 : n.durMs[t]
        r.dur.append(Float(steps > 0 ? steps : max(0.5, ms / tickMs)))
      }
      if g.stopRequested { break }
      // Loop: stop at the first bar line where the marking is back home.
      if loop && (cur + 1) % stepsPerBar == 0 && isAtStart(g, muted0: muted0) {
        r.cycle = cur + 1
        break
      }
      cur += 1
    }
    if loop && r.cycle > 0 { r.steps = r.cycle }
    if !r.cancelled { progress?.report(done: total) }
    r.dropped = dropped
    let elapsed = ContinuousClock.now - t0
    let c = elapsed.components
    r.ms = Int(jsRound(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15))
    return r
  }

  /// The sum of `steps`, held at `Int.max` / `Int.min` instead of trapping (a project file can
  /// carry any number; the JS sums floats and cannot overflow).
  static func saturatingSum(_ steps: [Int]) -> Int {
    var sum = 0
    for s in steps {
      let (value, overflow) = sum.addingReportingOverflow(s)
      sum = overflow ? (s > 0 ? Int.max : Int.min) : value
    }
    return sum
  }

  /// scope.js `atStart`: every net's place tokens equal its initial marking, and the mute table
  /// equals `muted0`. Indexed loops over the graph's own arrays: no copy, no allocation (measured
  /// by `RasterAtStartNoAllocRealTimeTests`).
  static func isAtStart(_ g: WaveGraph, muted0: [UInt8]) -> Bool {
    for ni in 0..<g.nets.count {
      let n = g.nets[ni]
      for p in 0..<n.nPlaces where n.state[p] != n.initial[p] { return false }
    }
    for i in 0..<muted0.count where g.muted[i] != muted0[i] { return false }
    return true
  }
}
