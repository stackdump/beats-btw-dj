// RasterController: the state behind the raster view (scope.js `s.raster`, `s.projectGen`,
// `s.rasterPending`).
//
//   let raster = RasterController()
//   raster.update(feed: feed)       // every frame; cheap unless the song changed
//   raster.phase / raster.scene     // what to draw
//   raster.statusText               // the line for the panel header
//
// The raster belongs to a song, not to the playback: `update` starts a compute when the lead
// deck or its `trackSerial` changes (a new track, a deck that flipped between sample and net, a
// master whose lead changed), and does nothing on a restart, a section jump or any other bump of
// `feed.generation`, which leave the song as it was. The compute runs on a background task over
// the feed's `leadProject`; a result that arrives after the song has changed again is dropped,
// and the older compute is told to stop. While a compute runs there is no raster, as in the JS
// (`s.raster = null` on a project load), and the status line says how far it has got.
//
// Finished rasters are kept by song (`RasterSceneCache`, the last three): a master whose lead
// goes A, B, A shows A's raster again at once instead of ticking the song a second time.
//
// Lanes (rows), their colours and the section markers come from the feed's lane set of the lead
// deck at the moment the compute starts, and are kept with the result: a raster is always drawn
// with the lanes it was computed for. On a master feed the rows are the lead deck's lanes only
// (the other deck's are not part of this arrangement).
//
// The tempo the compute gets (it turns a binding's legacy millisecond length into steps) is the
// feed's tempo when it starts; like the JS it is not recomputed when the tempo moves.

import Foundation

/// One finished raster with the lanes and sections it is drawn with.
public struct RasterScene: Equatable, Sendable {
  public var result: RasterResult
  public var lanes: [ScopeLane]
  public var sections: [ScopeSection]
  /// Changes whenever the scene does (a view keys its cached drawing on it).
  public var id: Int

  public init(result: RasterResult, lanes: [ScopeLane], sections: [ScopeSection], id: Int) {
    self.result = result
    self.lanes = lanes
    self.sections = sections
    self.id = id
  }
}

@MainActor
public final class RasterController {
  public enum Phase: Equatable, Sendable {
    /// No net deck behind the source.
    case noNet
    /// A net deck, but its song is not known yet (no anchor or loaded project seen).
    case waiting
    case computing
    case ready
    /// The song's project is not available, or the compute failed; the scene is the JS failure
    /// raster (`raster unavailable`).
    case failed
  }

  public private(set) var phase = Phase.noNet
  /// The raster to draw: set in `.ready` and `.failed`.
  public private(set) var scene: RasterScene?
  /// Computes started so far.
  public private(set) var computeCount = 0
  /// Results thrown away because the song had changed.
  public private(set) var staleCount = 0
  /// Updates answered from the cache of finished rasters.
  public private(set) var cacheHits = 0

  private typealias Key = RasterSongKey

  private var key: Key?
  private var cache = RasterSceneCache()
  private var jobSerial = 0
  private var sceneSerial = 0
  private var work: Task<RasterResult, Never>?
  private var waiter: Task<Void, Never>?
  private var progress: RasterProgress?
  private var noNetText = "no net on this deck"
  /// The status line, built when the scene (or the percentage) changes, not once per frame.
  private var finishedStatus: String?
  private var computingStatus: (percent: Int, text: String)?

  public init() {}

  /// Follow `feed`: start a compute if the song on its lead deck is not the one already shown.
  public func update(feed: ScopeFeed) {
    guard feed.hasNet, let deck = feed.leadDeck else {
      noNetText = feed.source == .master ? "no net deck" : "no net on this deck"
      if phase != .noNet || key != nil {
        abortWork()
        key = nil
        scene = nil
        phase = .noNet
      }
      return
    }
    let k = Key(deck: deck, serial: feed.trackSerial)
    if k == key { return }
    abortWork()
    key = k
    scene = nil
    if k.serial == 0 {
      phase = .waiting
      return
    }
    if let kept = cache.scene(for: k) {
      cacheHits += 1
      show(kept, phase: kept.result.failed ? .failed : .ready)
      return
    }
    guard let project = feed.leadProject else {
      show(
        RasterScene(
          result: .failure("the project is no longer on the deck"), lanes: feed.laneSet.lanes,
          sections: feed.sections, id: nextSceneID()), phase: .failed)
      return
    }
    let input = RasterInput(
      project: project, structure: project.structure, tempo: feed.clock.tempo,
      laneOf: feed.laneSet.laneOf)
    begin(input, lanes: feed.laneSet.lanes, sections: feed.sections, song: k)
  }

  /// Stop following (the view went away): a running compute is told to stop and its result is
  /// dropped, and the finished rasters are forgotten. The next `update` starts afresh.
  public func cancel() {
    abortWork()
    key = nil
    cache.removeAll()
  }

  private func abortWork() {
    work?.cancel()
    work = nil
    waiter = nil
    progress = nil
    jobSerial += 1
  }

  /// Wait until the compute that is running (if any) has finished and been published. For tests
  /// and for callers that need the raster before they go on.
  public func settled() async {
    while phase == .computing, let w = waiter { await w.value }
  }

  /// Start computing `input` as the current job (for a caller that has a project but no feed;
  /// `update` is the same with the song's key, so that the result is kept).
  public func start(_ input: RasterInput, lanes: [ScopeLane], sections: [ScopeSection]) {
    begin(input, lanes: lanes, sections: sections, song: nil)
  }

  private func begin(
    _ input: RasterInput, lanes: [ScopeLane], sections: [ScopeSection], song: Key?
  ) {
    abortWork()
    computeCount += 1
    let job = jobSerial
    scene = nil
    phase = .computing
    let progress = RasterProgress()
    self.progress = progress
    computingStatus = nil
    let task = Task.detached(priority: .utility) {
      RasterModel.compute(input, progress: progress, isCancelled: { Task.isCancelled })
    }
    work = task
    waiter = Task { [weak self] in
      let result = await task.value
      self?.finish(job: job, result: result, lanes: lanes, sections: sections, song: song)
    }
  }

  private func finish(
    job: Int, result: RasterResult, lanes: [ScopeLane], sections: [ScopeSection], song: Key?
  ) {
    guard job == jobSerial, !result.cancelled else {
      staleCount += 1
      return
    }
    work = nil
    waiter = nil
    let finished = RasterScene(
      result: result, lanes: lanes, sections: sections, id: nextSceneID())
    if let song, !result.failed { cache.insert(finished, for: song) }
    show(finished, phase: result.failed ? .failed : .ready)
  }

  private func show(_ s: RasterScene, phase p: Phase) {
    scene = s
    phase = p
    finishedStatus = RasterLayout.statusText(s.result)
  }

  private func nextSceneID() -> Int {
    sceneSerial += 1
    return sceneSerial
  }

  // MARK: what to say

  /// A message for the empty canvas (no raster to draw), drawn at (8, 8) like the JS
  /// `computing the arrangement…`.
  public var canvasMessage: String? {
    switch phase {
    case .noNet: noNetText
    case .waiting, .computing: "computing the arrangement…"
    case .ready, .failed: nil
    }
  }

  /// The panel's status line (scope.js `updateStatus`), or nil to leave the host's own. While a
  /// compute runs it carries the percentage; the string is rebuilt only when that changes.
  public var statusText: String? {
    switch phase {
    case .noNet, .waiting: nil
    case .computing: computingText()
    case .ready, .failed: scene == nil ? nil : finishedStatus
    }
  }

  private func computingText() -> String {
    let percent = progress?.percent ?? 0
    if let c = computingStatus, c.percent == percent { return c.text }
    let text = Self.computingStatusText(percent: percent)
    computingStatus = (percent, text)
    return text
  }

  /// The header line while the compute is `percent` done (0 = no tick counted yet).
  static func computingStatusText(percent: Int) -> String {
    percent > 0
      ? "raster · computing the arrangement… \(percent) %" : "raster · computing the arrangement…"
  }
}
