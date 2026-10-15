// ModelEngine: the forward model behind the Spectro (model) and Bands scopes.
// Port of beats' scope-model.js (kernels, FX response) and the model half of scope.js
// (`modelDeposit`, `specAdvance`, `resetHistory`), pinned at beats-bitwrap-io 095d030.
//
// WHAT IT IS
// ==========
// Nothing here listens to the output. Pre-tanh, the master is a filtered marked point process
// (events through the voices), and for hits that do not overlap coherently the energy in a
// band is the incoherent sum
//
//     E_b ≈ Σ_events  e · ‖H_k‖²_b · |H_fx|²_b            e = (vel/100)²  (× a length factor)
//
// so three tables are enough, one file each:
//   * KERNELS   ‖H_k‖²: one hit of the real voice rendered offline, FFT'd once, per lane/note.
//               ModelEngineKernels.swift (`ModelKernels`, `ModelKernelTable`, `ModelKernelCache`).
//   * FX        |H_fx|²: the live deck chain (DJ filter, EQ, faders) as a power gain per row.
//               ModelEngineFx.swift (`DeckFx`, `ModelFx`).
//   * EVENTS    the feed's fire log.  This file (`ModelEngine`).
//
// ROWS. Every kernel and every FX response has NR = 33 values: the 5 BANDS `sub low lomid himid
// high` (20-80, 80-250, 250-2000, 2000-6000, 6000-16000 Hz; the beats-py analysis edges), then
// NS = 28 log-spaced spectrogram bins from 30 Hz to 16 kHz (`ModelGrid`, in this file). The
// per-bar array has ROWS = 6 columns: the bands and E, their sum (scope.js `ROWS`, `ModelGrid.rows`).
//
// UNITS. Energy is in the units of the time signal's Σ x² (Parseval): a kernel's rows add up to
// the energy of the hit as rendered at 44.1 kHz, a deposit scales it by (vel/100)² and the FX
// power gain, and a bar sums its deposits. A mode that compares with the measured side (the
// analyser's power) must not expect equal levels: it removes per-band offsets (scope.js's
// residual does). Measured, on a techno loop at 120 BPM played by a 44.1 kHz deck, Σ x² over
// model E is 0.94 (0.91 ... 0.98 per bar); per band sub 1.01, low 0.92, lomid 0.86, himid 0.86,
// high 0.88 (the 6-16 kHz row is the whole of "high"; a hat's noise above 16 kHz is outside
// every row). The offset is not constant, though, and a mode must not assume it is:
//   * the SAMPLE RATE. Σ x² of a signal grows with the rate it is sampled at (the same noise
//     has twice the samples at 44.1 as at 22.05 kHz), the kernels are always 44.1 kHz. A deck
//     tap at rate R carries R/44100 of what the model says: 0.5 at 22.05 kHz (the test rig),
//     1.09 at 48 kHz. Normalise by R/44100 before comparing totals.
//   * hits that overlap add COHERENTLY (the model adds energies), so a denser loop reads over
//     the model: the same techno song measures 1.19 at 240 BPM against 0.94 at 120.
//   * the tanh of the soft master squeezes the loudest hits (second order).
//
// HOW A MODE USES IT
// ==================
//     let model = ModelEngine.model(for: feed, engine: hub.engine)   // one per feed, kept alive
//     // in the draw, after `hub.pump()` (ScopeCanvas does that):
//     model.consume(feed)          // new fires -> deposits; resets itself; finalises columns
//
// `consume(_:)` is idempotent per pump and cheap when nothing is new. It
//   * resets all accumulated state when `feed.generation` changed (a new track, a restart, a
//     lane-set change, (re)acquire), continuing the fire log from `feed.generationFireStart`;
//   * rebuilds the per-lane kernel tables when the feed's lanes changed (the kernels render on
//     a background queue, `status` says `model · rendering N kernels…`, `consume` picks the
//     finished job up). While that job runs `consume` WAITS: it leaves the fires in the feed's
//     log, and deposits the whole backlog once the tables are in, so a model opened on a song
//     that is already playing, with kernels not yet cached, loses nothing the log still holds;
//   * deposits every fire it has not seen (`deposit(...)`);
//   * finalises the spectrogram columns up to the step that is sounding (scope.js `frame()`).
// On a MASTER feed it also resets when the lead deck or its song changes (the bar axis is the
// lead's), and places the other deck's fires on the lead's step axis by time.
//
// WHO CALLS IT. The history is only as complete as the calls: the feed keeps the newest 4096
// fires (a techno loop fires about 41 a second at 300 BPM, 16 at 120: 100 s and 4 minutes of
// them). scope.js deposits
// on every fire while the scope is open, whatever view is showing, so
//   * `ScopeHub.pump()` calls `consume` for every subscribed feed that HAS a model
//     (`ModelEngine.existing(for:)`), whichever scope mode is on screen: once a model exists
//     it keeps accumulating while the feed is subscribed;
//   * a host that wants the history to cover the time before a model mode is first drawn calls
//     `ModelEngine.start(for:engine:)` when it subscribes (that creates the model and starts
//     the kernels, as scope.js does when the Scope tab opens).
// If the model still falls behind the log (`lostSince`), it cannot reconstruct what was lost, and
// a bar with a hole would read as a wrong level: it EMPTIES its history and rebuilds it from the
// oldest fire the log still holds, so the bars are contiguous, and counts the lost fires in
// `missedFires` (per generation). `modelFrom` is the first step of what it holds.
//
// WHAT TO READ (all main thread, `public private(set)`):
//   BANDS (mode 5)   `modelBars[bar * ModelGrid.rows + r]` Double, r = 0..4 the bands, 5 = E (the
//                    sum of the five); `maxBar` (-1 = empty), `modelFrom` (first step deposited,
//                    `Int.max` = none), `modelDb(bar:row:)`, `fires`, `status`.
//   SPECTRO (mode 2) `specCol[(step % specCap) * ns + j]` Float, j = 0 the LOWEST bin; valid for
//                    a step iff `specStep[step % specCap] == step`; `specCur` = the first step
//                    whose column is not final; `specAdvance(step:tickSec:)`, `status`,
//                    `hasTables` (false = "model (warming up)").
//   BOTH             `status` (scope.js kernelStatus), `kernelCount`, `kernelMs`, `lanes`,
//                    `laneTables`, `fx` (the response rows currently applied).
//
// FX. `fxPoint` says what the model is compared with. By default (`.deckOutput`, the beats chain
// of scope-model.js `fxResponse`) every feed's model is what the performer HEARS of its decks: each
// deck's DJ filter, EQ and gain (trim x volume x crossfader x master, squared), per deck, refreshed
// at most every 200 ms. A MASTER feed's samples are post-everything, so that is exactly what it
// is compared with. A DECK feed's samples are the deck tap, which is PRE-EQ and PRE-fader: with
// the default its measured half does not move with the deck's filter, EQ or fader while the model
// does, which the residual then shows (a decision taken on the product side: the model answers
// "what do I hear", not "what does the tap carry"). Set `fxPoint = .matchTap` on a deck feed for
// the other reading: the model gets the source gain only, so model and measured agree whatever
// the faders do. `fxPointLabel` says which a feed's model is ("deck output" / "pre-fader tap" /
// "master"): a mode should show it, so the reader knows what a fader or the filter will do.
//
// BAND ROWS UNDER A STRONG FILTER. The response of a row is the mean of |H|² at 4 probe
// frequencies (the JS rule, and the spec). For the 28 bins that is exact enough; for the wide
// bands it is not when a filter corner sits INSIDE the band and the band's energy is not spread
// evenly over it. Measured (44.1 kHz master feed, DJ filter at ~900 Hz, bass shelf and mid band
// cut, faders down): measured/model is 1.00 in `sub`, 0.92 in `low` and 1.02 in E, and 0.88 ...
// 1.01 in each spectrogram bin from 52 to 494 Hz, but 3.6 in `lomid` (250-2000 Hz): the kick
// and the bass sit at 250-550 Hz, where the filter does nothing, while the mean of |H|² over
// the band's four probes is 0.011 against 0.040 for those four bins (gain² included). A sweep
// through a band therefore shows a dark band in the Bands mode. `ModelEngineEnergyTests` pins this; weighting the probes
// by the kernel's bin energies would fix it and is NOT done (it is not what the spec describes).
//
// THREADS. Everything is main-thread (`@MainActor`). Kernels are rendered by `WaveRunner` offline on
// a private utility queue, one job per lane-set change; a newer lane set cancels the older job (its
// finished kernels stay in the cache, its result is never adopted). Nothing here touches the audio thread.
//
// TESTS. `ModelEngine.prepared(project:)` builds a ready model for a Project without an
// engine or audio, rendering its kernels synchronously (about a second in a debug build for a
// whole song); `setLanes(_:tables:)` installs hand-made kernel tables instead; `deposit(...)`
// and `specAdvance(...)` are public for hand-made scenarios; `setFx(...)` pins the response;
// `waitForKernels()` blocks until a background render is in. A model built with
// `init(engine: nil)` applies no FX (all rows 1, not even the source gain).
//
// DEVIATIONS from the JS (also in the report): see the end of this comment.
//   * Per DECK, not per channel, FX; the deck EQ shelves/peak are an addition; the source gain.
//   * Time: wall-clock `fxClock` for the 200 ms refresh (the JS uses performance.now() too);
//     everything else is in feed time (fire steps, anchors), not audio-context time.
//   * `assemble()` invalidates the spectrogram decays so a table that arrives late is used (the
//     JS keeps the 0.1 s fallback decay of a lane whose kernel was not there yet until the tempo
//     changes).
//   * Kernels come from the Swift synth, at 44.1 kHz, on a background queue; they are cached
//     in memory only (no disk store). The master curve is linear in the kernel and 0.8 in the FX.
//   * On a master feed the other deck's fires are placed by time on the lead's step axis, and a
//     new lead deck / song resets the history; the JS has one deck. (Fires replayed after a
//     long wait are placed through the feed's 128 newest anchors, extrapolated backwards at the
//     current tempo: exact unless the tempo moved in between.)
//   * The kernel cache holds 400 in memory (the JS persists only 400); drum lanes get one
//     kernel per drum voice, not one per note (see ModelEngineKernels.swift).
//   * A lane built from the engine's layout (no note list, see ScopeLaneSet) gets its kernel
//     notes from its note range instead of the kick / middle C default.

import Foundation
import Synchronization

/// The fixed grid of the model: band edges, spectrogram bins, the rows of both, probe
/// frequencies, and the sizes of the state arrays. scope-model.js top-level constants.
public enum ModelGrid {
  /// Band edges in Hz (beats-py analysis.py).
  public static let bands: [(lo: Double, hi: Double)] = [
    (20, 80), (80, 250), (250, 2000), (2000, 6000), (6000, 16000),
  ]
  public static let bandLabels = ["sub", "low", "lomid", "himid", "high"]
  /// Number of bands.
  public static let nb = 5
  /// Number of spectrogram bins, 30 Hz ... 16 kHz, log spaced.
  public static let ns = 28
  /// Rows per kernel: the bands, then the bins.
  public static let nr = nb + ns
  /// Per-bar columns of `modelBars`: the bands and E = their sum.
  public static let rows = nb + 1
  /// Spectrogram bin edges: `30·(16000/30)^(i/28)`, i = 0 ... 28.
  public static let specEdges: [Double] = (0...ns).map {
    30 * pow(16000.0 / 30, Double($0) / Double(ns))
  }
  /// (lo, hi) of every row: the 5 bands, then the 28 bins.
  public static let edges: [(lo: Double, hi: Double)] =
    bands.map { (lo: $0.lo, hi: $0.hi) }
    + (0..<ns).map { (lo: specEdges[$0], hi: specEdges[$0 + 1]) }
  /// Probe frequencies per row for the FX response.
  public static let probes = 4
  /// `lo·(hi/lo)^((p + 0.5)/4)` at index `row * probes + p`.
  public static let probeFrequencies: [Double] = edges.flatMap { e in
    (0..<probes).map { e.lo * pow(e.hi / e.lo, (Double($0) + 0.5) / Double(probes)) }
  }
  /// Bars `modelBars` holds (scope.js MAX_BARS).
  public static let maxBars = 1024
  /// Columns the spectrogram ring holds (scope.js SPEC_CAP).
  public static let specCap = 2048
}

/// Where the model's FX are taken from, for a DECK feed (a master feed always has the deck chain).
public enum ModelFxPoint: Sendable {
  /// Match the tap: a deck's samples are pre-EQ and pre-fader, so only the source gain applies.
  case matchTap
  /// The deck's output as the performer hears it: DJ filter, EQ, trim x volume x crossfader x
  /// master. The default.
  case deckOutput
}

@MainActor
public final class ModelEngine {
  /// Gain of the wave engine's soft master in its small-signal range: tanh(g·x) ≈ g·x. The
  /// kernels are rendered linear, so this is where the 0.8 goes (squared in the FX response).
  public static let sourceGain = WaveOptions().masterGain
  /// The FX response is re-read from the engine at most this often (seconds; scope.js 200 ms).
  public static let fxRefreshInterval = 0.2

  // MARK: configuration

  /// The engine whose decks' filters, EQ and faders the FX response reads. Nil: no FX (all 1).
  public let engine: DJEngine?
  public let cache: ModelKernelCache
  public var fxPoint: ModelFxPoint = .deckOutput
  /// What the FX are taken at, for a mode to show: `deck output` (a deck feed, `.deckOutput`, the
  /// default), `pre-fader tap` (a deck feed, `.matchTap`) or `master`.
  public var fxPointLabel: String {
    switch source {
    case .some(.deck): fxPoint == .matchTap ? "pre-fader tap" : "deck output"
    default: "master"
    }
  }
  /// Monotonic seconds, for the FX refresh; replaceable in tests.
  public var fxClock: () -> Double = { ModelEngine.monotonicSeconds() }

  private static func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  }

  // MARK: lanes and kernels

  /// The lanes the tables and state are sized for (the feed's `lanes`).
  public private(set) var lanes: [ScopeLane] = []
  /// One table per lane, nil until all its kernels are in the cache.
  public private(set) var laneTables: [ModelKernelTable?] = []
  /// scope.js `kernelStatus`: `model idle`, `model · rendering N kernels…`, `model · k/n parts`,
  /// `model · N kernels` (+ ` (123 ms)` after a render), `model unavailable …`.
  public private(set) var status = "model idle"
  /// Kernels the lanes need (counting a kernel shared by two lanes twice, as the JS does).
  public private(set) var kernelCount = 0
  /// How long the last background render took.
  public private(set) var kernelMs = 0
  /// Any lane has its table (else the spectrogram says "model (warming up)").
  public var hasTables: Bool { laneTables.contains { $0 != nil } }
  /// Every lane has its table.
  public var tablesReady: Bool { !lanes.isEmpty && laneTables.allSatisfy { $0 != nil } }

  // MARK: bands (per bar)

  /// `bar * rows + r`: r = 0 ... 4 the bands, 5 = E. Linear power, Double.
  public private(set) var modelBars = [Double](
    repeating: 0, count: ModelGrid.maxBars * ModelGrid.rows)
  /// The last bar with a deposit (-1: none).
  public private(set) var maxBar = -1
  /// The first step deposited since the last reset (`Int.max`: none yet).
  public private(set) var modelFrom = Int.max
  /// Fires consumed (all lanes, tables or not); never reset.
  public private(set) var fires = 0
  /// Fires of the current generation the model never saw, because they left the feed's log
  /// (4096) before `consume` ran. The history was rebuilt from the oldest one still held, so
  /// the bars are contiguous but start later than the track.
  public private(set) var missedFires = 0

  // MARK: spectrogram

  /// Per lane and bin, the energy rate still ringing: `lane * ns + j`, Float32 like the JS.
  public private(set) var laneState: [Float] = []
  public private(set) var laneDecay: [Float] = []
  public private(set) var laneMean: [Float] = []
  public private(set) var specTickSec = 0.0
  /// Finalised columns: `(step % specCap) * ns + j`, j = 0 the lowest bin.
  public private(set) var specCol = [Float](
    repeating: 0, count: ModelGrid.specCap * ModelGrid.ns)
  /// The step each column slot holds (-1: none).
  public private(set) var specStep = [Int32](repeating: -1, count: ModelGrid.specCap)
  /// Columns for steps below this are final (-1: not started).
  public private(set) var specCur = -1

  // MARK: FX

  /// The decks the FX rows are kept for (in lane order of first appearance).
  public private(set) var fxDecks: [String] = []
  /// `deckIndex * nr + row`: gain² x filters, per deck.
  public private(set) var fx: [Float] = [Float](repeating: 1, count: ModelGrid.nr)
  private var laneFxOffset: [Int] = []
  private var fxAt = -Double.infinity

  // MARK: private state

  private var source: ScopeSource?
  private var generation = 0
  private var fireCursor = 0
  private var leadKey: LeadKey?
  private var laneSpecs: [[ModelKernelSpec]] = []
  private var kbuf = [Float](repeating: 0, count: ModelGrid.nr)
  private var epoch = 0
  private var job: KernelJob?

  private struct LeadKey: Equatable {
    var deck: String?
    var serial: Int32
  }

  /// One background render: written by the render queue, polled by `consume`.
  private final class KernelJob: Sendable {
    let epoch: Int
    let cancelled = Atomic<Bool>(false)
    let finished = Atomic<Bool>(false)
    let milliseconds = Atomic<Int>(0)
    init(epoch: Int) { self.epoch = epoch }
  }

  private static let kernelQueue = DispatchQueue(label: "dj.scopes.model-kernels", qos: .utility)

  public init(engine: DJEngine?, cache: ModelKernelCache = .shared) {
    self.engine = engine
    self.cache = cache
  }

  // MARK: shared instance per feed

  private struct Entry {
    weak var feed: ScopeFeed?
    let model: ModelEngine
  }
  private static var registry: [ObjectIdentifier: Entry] = [:]

  /// The model of a feed, created on first ask and kept for the life of the feed: the Spectro and
  /// the Bands mode of one source share it, and switching between them keeps the history.
  public static func model(
    for feed: ScopeFeed, engine: DJEngine, cache: ModelKernelCache = .shared
  ) -> ModelEngine {
    registry = registry.filter { $0.value.feed != nil }
    let id = ObjectIdentifier(feed)
    if let e = registry[id], e.feed === feed { return e.model }
    let m = ModelEngine(engine: engine, cache: cache)
    registry[id] = Entry(feed: feed, model: m)
    return m
  }

  /// The model of a feed if one was made (`model(for:engine:)`), else nil. What `ScopeHub.pump()`
  /// asks, so it never creates one.
  public static func existing(for feed: ScopeFeed) -> ModelEngine? {
    guard let e = registry[ObjectIdentifier(feed)], e.feed === feed else { return nil }
    return e.model
  }

  /// scope.js opening the Scope tab (`ensureKernels`): make the feed's model and take in what the
  /// feed has so far, which starts rendering the kernels the cache lacks. A host calls this when
  /// it subscribes to a feed, so the history covers the time before a model mode is first drawn;
  /// from then on `ScopeHub.pump()` keeps it consuming.
  @discardableResult
  public static func start(
    for feed: ScopeFeed, engine: DJEngine, cache: ModelKernelCache = .shared
  ) -> ModelEngine {
    let m = model(for: feed, engine: engine, cache: cache)
    m.consume(feed)
    return m
  }

  // MARK: test hook

  /// A model ready to use for `project`, without audio: lanes from the project (`tempo` is what
  /// the note lengths are converted at), kernels rendered here and now. No engine, so no FX
  /// (all 1) until `setFx` says otherwise. Pass a private `cache` to keep a test isolated.
  public static func prepared(
    project: Project, tempo: Double = 120, deck: String = "A",
    cache: ModelKernelCache = .shared
  ) -> ModelEngine {
    let m = ModelEngine(engine: nil, cache: cache)
    m.setLanes(
      ScopeLaneSet.build(project: project, tempo: tempo, deck: deck).lanes, kernels: .immediate)
    return m
  }

  // MARK: lanes and kernels

  public enum KernelRender: Sendable {
    /// On the background queue; `consume` / `pollKernels` pick the result up.
    case background
    /// Here and now, blocking the caller (tests).
    case immediate
    /// Do not render: the tables are installed by hand (`setLanes(_:tables:)`) or not at all.
    case none
  }

  /// scope.js `buildLanes` + `ensureKernels`: size every state array for these lanes, forget the
  /// tables, and render what the cache lacks. Does not touch the history (`resetHistory`).
  public func setLanes(_ new: [ScopeLane], kernels mode: KernelRender = .background) {
    lanes = new
    laneTables = [ModelKernelTable?](repeating: nil, count: new.count)
    laneState = [Float](repeating: 0, count: new.count * ModelGrid.ns)
    laneDecay = [Float](repeating: 0, count: new.count)
    laneMean = [Float](repeating: 0, count: new.count)
    specTickSec = 0
    fxDecks = []
    laneFxOffset = []
    for lane in new {
      if !fxDecks.contains(lane.deck) { fxDecks.append(lane.deck) }
      laneFxOffset.append(fxDecks.firstIndex(of: lane.deck)! * ModelGrid.nr)
    }
    fx = [Float](repeating: 1, count: max(1, fxDecks.count) * ModelGrid.nr)
    fxAt = -.infinity
    laneSpecs = new.map { ModelKernels.laneKernelSpecs(for: $0) }
    if mode == .none {
      cancelJob()
      status = new.isEmpty ? "model idle" : "model · 0/\(new.count) parts"
      kernelCount = 0
      return
    }
    ensureKernels(mode)
  }

  /// Lanes with hand-made kernel tables (one per lane, nil = not ready): for scenarios that
  /// must not depend on the synth, such as the arithmetic tests of the modes built on this.
  public func setLanes(_ new: [ScopeLane], tables: [ModelKernelTable?]) {
    precondition(tables.count == new.count, "one table (or nil) per lane")
    setLanes(new, kernels: .none)
    laneTables = tables
    let ready = tables.filter { $0 != nil }.count
    kernelCount = tables.reduce(0) { $0 + ($1?.n ?? 0) }
    status =
      ready == new.count
      ? "model · \(kernelCount) kernels" : "model · \(ready)/\(new.count) parts"
    specTickSec = 0
  }

  private func cancelJob() {
    epoch += 1
    job?.cancelled.store(true, ordering: .relaxed)
    job = nil
  }

  private func ensureKernels(_ mode: KernelRender) {
    cancelJob()
    guard !lanes.isEmpty else {
      status = "model idle"
      kernelCount = 0
      return
    }
    if assemble() == lanes.count { return }
    let missing = laneSpecs.flatMap { $0 }.filter { !cache.contains($0.key) }
    status = "model · rendering \(missing.count) kernels…"
    switch mode {
    case .immediate:
      let t0 = Self.monotonicSeconds()
      ModelKernels.renderKernels(
        missing, into: cache, workers: min(4, ProcessInfo.processInfo.activeProcessorCount))
      kernelMs = Int(((Self.monotonicSeconds() - t0) * 1000).rounded())
      _ = assemble()
      status += " (\(kernelMs) ms)"
    case .none:
      break
    case .background:
      let job = KernelJob(epoch: epoch)
      self.job = job
      let cache = cache
      Self.kernelQueue.async { Self.run(job, missing, cache) }
    }
  }

  private nonisolated static func run(
    _ job: KernelJob, _ specs: [ModelKernelSpec], _ cache: ModelKernelCache
  ) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    ModelKernels.renderKernels(
      specs, into: cache, isCancelled: { job.cancelled.load(ordering: .relaxed) })
    job.milliseconds.store(
      Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000), ordering: .relaxed)
    job.finished.store(true, ordering: .releasing)
  }

  /// Build every lane's table from the cache; the number of lanes that have one.
  private func assemble() -> Int {
    var ready = 0
    for (i, specs) in laneSpecs.enumerated() {
      let t = ModelKernels.laneKernelTable(specs, drum: lanes[i].drum, cache: cache)
      laneTables[i] = t
      if t != nil { ready += 1 }
    }
    kernelCount = laneSpecs.reduce(0) { $0 + $1.count }
    status =
      ready == lanes.count
      ? "model · \(kernelCount) kernels" : "model · \(ready)/\(lanes.count) parts"
    // Tables are what the spectrogram decays come from: recompute them with the next advance.
    specTickSec = 0
    return ready
  }

  /// Pick up a finished background render (the tables, the status). True if it did.
  @discardableResult
  public func pollKernels() -> Bool {
    guard let job, job.finished.load(ordering: .acquiring) else { return false }
    self.job = nil
    guard job.epoch == epoch, !job.cancelled.load(ordering: .relaxed) else { return false }
    kernelMs = job.milliseconds.load(ordering: .relaxed)
    _ = assemble()
    status += " (\(kernelMs) ms)"
    return true
  }

  /// Block the calling thread until the background render, if any, is done and adopted (tests).
  public func waitForKernels(timeout: Double = 30) {
    let end = Self.monotonicSeconds() + timeout
    while job != nil && Self.monotonicSeconds() < end {
      pollKernels()
      Thread.sleep(forTimeInterval: 0.002)
    }
  }

  // MARK: FX

  /// Pin the response rows of `deck` (NR values), for tests and for a mode that computes its own.
  /// The next refresh from a live engine overwrites them.
  public func setFx(deck: String, rows: [Float]) {
    precondition(rows.count == ModelGrid.nr)
    guard let i = fxDecks.firstIndex(of: deck) else { return }
    for j in 0..<ModelGrid.nr { fx[i * ModelGrid.nr + j] = rows[j] }
    fxAt = fxClock()
  }

  /// The FX chain of a deck as the model sees it right now.
  func fxState(deck name: String) -> DeckFx? {
    guard let engine, let deck = engine.decks[name] else { return nil }
    let path: ModelFxPoint
    switch source {
    case .some(.deck): path = fxPoint
    default: path = .deckOutput
    }
    if path == .matchTap {
      // the tap is after the deck's master chain: its HP / LP is in what the tap hears
      var fx = DeckFx(gain: Self.sourceGain)
      (fx.chainHighPass, fx.chainLowPass) = DeckFx.chainPasses(deck: deck)
      return fx
    }
    return DeckFx(
      deck: deck,
      gain: Self.sourceGain * deck.trim * deck.volume * engine.crossfadeGain(name) * engine.master)
  }

  /// scope-model.js `fxResponse`: re-read every deck's chain from the engine.
  public func refreshFx() {
    guard let engine else { return }
    for (i, name) in fxDecks.enumerated() {
      guard let state = fxState(deck: name) else { continue }
      ModelFx.response(state, sampleRate: engine.sampleRate, into: &fx, at: i * ModelGrid.nr)
    }
    fxAt = fxClock()
  }

  private func refreshFxIfStale() {
    if fxClock() - fxAt > Self.fxRefreshInterval { refreshFx() }
  }

  // MARK: history

  /// scope.js `resetHistory` (the model's part): empty the bars and the spectrogram.
  public func resetHistory() {
    for i in modelBars.indices { modelBars[i] = 0 }
    maxBar = -1
    modelFrom = .max
    for i in specStep.indices { specStep[i] = -1 }
    specCur = -1
    for i in laneState.indices { laneState[i] = 0 }
  }

  // MARK: deposit

  /// scope.js `modelDeposit`: one fire of lane `lane` (an index into `lanes`) at song step
  /// `step`. `velocity` 1...127, `durMs` the note length, `tickSec` seconds per step. A lane
  /// without a table (its kernels are still rendering) is skipped, as in the JS.
  public func deposit(
    lane li: Int, note: Int, velocity: Int, durMs: Double, step: Int, tickSec: Double
  ) {
    guard lanes.indices.contains(li), let kt = laneTables[li] else { return }
    refreshFxIfStale()
    let nb = ModelGrid.nb
    let ns = ModelGrid.ns
    kt.kernelFor(note: note, into: &kbuf)
    let v = Double(velocity) / 100
    var e = v * v * balanceGain(lanes[li], note: note)
    if !kt.drum { e *= max(0.25, min(4, durMs / Double(kt.durMs))) }
    let off = laneFxOffset[li]
    let bar = step >> 4  // floor(step / 16)
    if bar >= 0 && bar < ModelGrid.maxBars {
      var sum = 0.0
      let o = bar * ModelGrid.rows
      for b in 0..<nb {
        let x = e * Double(kbuf[b]) * Double(fx[off + b])
        modelBars[o + b] += x
        sum += x
      }
      modelBars[o + nb] += sum
      if bar > maxBar { maxBar = bar }
      if step < modelFrom { modelFrom = step }
    }
    // Spectrogram state: energy rate e/τ, decaying with the kernel.
    specAdvance(step: step, tickSec: tickSec)
    let lo = li * ns
    let inv = 1 / kt.tau
    for j in 0..<ns {
      let add = e * Double(kbuf[nb + j]) * Double(fx[off + nb + j]) * inv
      laneState[lo + j] = Float(Double(laneState[lo + j]) + add)
    }
  }

  /// The energy gain of a note of `lane` from its deck's part trims (`DJMusicality.Fixes.balance`,
  /// which scale the lane's voice after the kernels were rendered at the voice's own level); 1
  /// without them (beats' scope-model.js has none).
  private func balanceGain(_ lane: ScopeLane, note: Int) -> Double {
    guard let trims = engine?.decks[lane.deck]?.wave.latest?.balance,
      let part = MixBalance.part(drumNote: lane.drum ? note : nil, group: lane.group),
      let db = trims[part]
    else { return 1 }
    return pow(10, db / 10)
  }

  /// scope.js `specAdvance`: finalise the spectrogram columns for the steps before `step`.
  /// Each column is `Σ_lanes state · τ/tickSec · (1 - d)` (the mean of e^{-t/τ} over one step),
  /// after which every lane's state decays by `d = exp(-tickSec/τ)`. A `step` more than 8 back,
  /// or more than `specCap` ahead, of the last finalised one starts over (state zeroed).
  public func specAdvance(step: Int, tickSec: Double) {
    let ns = ModelGrid.ns
    let cap = ModelGrid.specCap
    let count = lanes.count
    if specTickSec != tickSec {
      for l in 0..<count {
        let tau = laneTables[l]?.tau ?? 0.1
        let d = exp(-tickSec / tau)
        laneDecay[l] = Float(d)
        laneMean[l] = Float(tau / tickSec * (1 - d))  // mean of e^{-t/τ} over one step
      }
      specTickSec = tickSec
    }
    if specCur >= 0 && (step < specCur - 8 || step > specCur + cap) {
      for i in laneState.indices { laneState[i] = 0 }
      specCur = -1
    }
    if specCur < 0 {
      specCur = step
      return
    }
    while specCur < step {
      let c = specCur
      let slot = ((c % cap) + cap) % cap
      let o = slot * ns
      for j in 0..<ns { specCol[o + j] = 0 }
      for l in 0..<count {
        let m = Double(laneMean[l])
        let d = Double(laneDecay[l])
        let lo = l * ns
        for j in 0..<ns {
          let s = Double(laneState[lo + j])
          specCol[o + j] = Float(Double(specCol[o + j]) + s * m)
          laneState[lo + j] = Float(s * d)
        }
      }
      specStep[slot] = Int32(truncatingIfNeeded: c)
      specCur += 1
    }
  }

  /// scope.js `frame()`: finalise the columns up to (not including) the SOUNDING step, found
  /// from the anchor at or before `now`: `floor(anchorStep + (now - anchorTime)/tickSec) - 1`,
  /// if that is ahead of the last finalised step by fewer than 64. Idempotent.
  public func finaliseColumns(
    now: Double, anchorStep: Int, anchorTime: Double, tickSec: Double
  ) {
    guard specCur >= 0 else { return }
    let s = (Double(anchorStep) + (now - anchorTime) / tickSec).rounded(.down) - 1
    guard s.isFinite, abs(s) < 1e12 else { return }
    let step = Int(s)
    if step > specCur && step - specCur < 64 { specAdvance(step: step, tickSec: tickSec) }
  }

  // MARK: reading

  /// scope.js `modelDb`: `10·log10(modelBars)` of a bar and row (0 ... 5), or nil if empty.
  public func modelDb(bar: Int, row: Int) -> Double? {
    guard bar >= 0, bar < ModelGrid.maxBars, row >= 0, row < ModelGrid.rows else { return nil }
    let v = modelBars[bar * ModelGrid.rows + row]
    return v > 0 ? 10 * log10(v) : nil
  }

  /// The response row of lane `lane`'s deck currently applied (NR values).
  public func fxRow(forLane li: Int) -> ArraySlice<Float> {
    guard laneFxOffset.indices.contains(li) else { return [] }
    return fx[laneFxOffset[li]..<(laneFxOffset[li] + ModelGrid.nr)]
  }

  // MARK: consuming a feed

  /// Take in everything the feed has logged since the last call. See the header.
  public func consume(_ feed: ScopeFeed) {
    if generation != feed.generation || source != feed.source { adopt(feed) }
    pollKernels()
    if feed.source == .master {
      let key = LeadKey(deck: feed.leadDeck, serial: feed.trackSerial)
      if key != leadKey {
        leadKey = key
        resetHistory()
      }
    }
    // The kernels are still rendering: no lane could be deposited (or only some), and a fire
    // taken now would be gone. Leave them in the feed's log; the next call after the job is
    // adopted takes the backlog.
    if job != nil { return }
    let tickSec = feed.tickSec
    let log = feed.fireLog
    let lost = log.lostSince(fireCursor)
    if lost > 0 {
      // Fell more than the log behind: what is gone cannot be put back, and bars with a hole
      // would read as wrong levels. Start the history over from what the log still holds.
      missedFires += lost
      resetHistory()
      fireCursor = log.firstNumber
    }
    for n in log.numbers(since: fireCursor) {
      guard let f = log.fire(number: n), lanes.indices.contains(f.lane) else { continue }
      fires += 1
      deposit(
        lane: f.lane, note: f.note, velocity: f.velocity, durMs: f.durSec * 1000,
        step: stepOf(f, feed: feed), tickSec: tickSec)
    }
    fireCursor = log.total
    if let a = feed.anchorAt(feed.nowTime) {
      finaliseColumns(now: feed.nowTime, anchorStep: a.step, anchorTime: a.time, tickSec: tickSec)
    }
  }

  /// A new generation: forget the history, follow the feed's lanes, continue the fire log from
  /// where the new generation began.
  private func adopt(_ feed: ScopeFeed) {
    generation = feed.generation
    source = feed.source
    leadKey = LeadKey(deck: feed.leadDeck, serial: feed.trackSerial)
    resetHistory()
    missedFires = 0
    if feed.lanes != lanes {
      setLanes(feed.lanes)
    } else if !tablesReady && job == nil {
      ensureKernels(.background)
    }
    fireCursor = feed.generationFireStart
  }

  /// The song step a fire counts at: its own, except on a master feed for a deck that is not the
  /// lead, whose fires are placed on the lead's step axis by time (that is the axis of the bars
  /// and of the measured side).
  private func stepOf(_ f: ScopeFire, feed: ScopeFeed) -> Int {
    guard feed.source == .master, lanes[f.lane].deck != feed.leadDeck,
      let s = feed.stepAt(f.time), s.isFinite, abs(s) < 1e12
    else { return f.step }
    return Int(s.rounded(.down))
  }
}
