import Synchronization

// The marking mirror: a copy of every net's place tokens (and which nets are muted) that the
// audio thread publishes as the net clock runs, and the main thread reads without locks,
// without allocating on the audio side, and without ever seeing half of one state and half
// of another. The feed draws live tokens from it; it never calls `WaveGraph.marking()`
// (which allocates dictionaries) off a stopped graph.
//
// Layout. What the numbers mean is fixed per project and built on the main thread when the
// project is prepared (`MarkingLayout`, immutable): net order, and each net's place
// offsets in one flat array of tokens. It travels with the project (`WaveProject.marking`),
// so a snapshot always comes with the layout of the very project that produced it.
//
// Publishing. Each project owns a `MarkingMirror`: two buffers and a seqlock. The audio
// thread, the only writer, fills the buffer that is *not* the newest, bracketing the write
// with a per-buffer stamp (odd while writing), then flips `newest`. A reader copies the
// newest buffer and re-reads its stamp: if a writer got in during the copy the stamp moved
// and the reader retries. Nothing here allocates, locks, or retains. The audio thread only
// ever writes into the mirror of the project it is running; a project swap is just the
// audio thread switching to another mirror, so a reader can never pair one project's layout
// with another project's tokens.

/// What a display needs to know about one net of a project, fixed once the project is
/// prepared: which lane it belongs on, how to colour and place it. Everything an event's
/// `net` / `transition` indices (or a snapshot's net order) refer to.
public struct NetInfo: Sendable {
  public let id: String
  /// "music", or "control" (a control net steers other nets and never sounds).
  public let role: String
  /// The lane merge key: the riff group the net belongs to ("" for a net on its own).
  public let riffGroup: String
  public let riffVariant: String
  /// The track's group ("kick", "snare", "bass", "melody", ...) if it has one.
  public let group: String?
  public let instrument: String
  /// The track's MIDI channel; 10...15 are drums. (A binding may override it per transition:
  /// `FireEvent.channel` is the channel that actually played.)
  public let channel: Int
  public let isDrum: Bool
  /// A one-bar accent the performer fires (`hit1`...).
  public let isStinger: Bool
  /// Lowest and highest MIDI note over the net's transitions that have a voice; both -1 for
  /// a net that never sounds.
  public let noteLow: Int
  public let noteHigh: Int
  /// A fire's `transition` indexes these (and `transitionX` / `transitionY`).
  public let transitionIds: [String]
  /// The net's own ring layout, as composed (the compiled graph drops coordinates, so these
  /// come from the project that was prepared): positions in the order of `placeIds` (the
  /// layout's) and of `transitionIds`. All zero for a project that carries no coordinates.
  public let placeX: [Double]
  public let placeY: [Double]
  public let transitionX: [Double]
  public let transitionY: [Double]

  init(_ n: CompiledNet, isStinger: Bool, geometry: NetBundle?) {
    id = n.id
    role = n.bundle.role
    riffGroup = n.bundle.riffGroup
    riffVariant = n.bundle.riffVariant
    group = n.bundle.track.group
    instrument = n.bundle.track.instrument
    channel = n.bundle.track.channel
    isDrum = isDrumChannel(n.bundle.track.channel)
    self.isStinger = isStinger
    var low = Int.max
    var high = Int.min
    for t in 0..<n.nTrans where n.lane[t] >= 0 {
      low = min(low, n.note[t])
      high = max(high, n.note[t])
    }
    noteLow = low == Int.max ? -1 : low
    noteHigh = high == Int.min ? -1 : high
    transitionIds = n.transIds
    placeX = n.placeIds.map { geometry?.places[$0]?.x ?? 0 }
    placeY = n.placeIds.map { geometry?.places[$0]?.y ?? 0 }
    transitionX = n.transIds.map { geometry?.transitions[$0]?.x ?? 0 }
    transitionY = n.transIds.map { geometry?.transitions[$0]?.y ?? 0 }
  }
}

/// Where every net's places sit in the flat token array of one project, and what each net is.
/// Immutable; built on the main thread at prepare time. Sendable and cheap to hold on to.
public final class MarkingLayout: Sendable {
  /// The project this describes (`WaveProject.generation`).
  public let generation: Int32
  /// Which song this project plays (`WaveProject.trackSerial`): equal across a section
  /// launch or jump of the same song, different for a new track.
  public let trackSerial: Int32
  /// The tick this project was seeded at (`WaveProject.startTick`): 0 from the top.
  public let startTick: Int
  /// Net ids in `WaveGraph.nets` order (project order); an event's `net` indexes this.
  public let netIds: [String]
  /// What each net is, in the same order as `netIds`.
  public let nets: [NetInfo]
  /// The song's sections with their start ticks, as of this project (empty for a loop). The
  /// deck's own `sections` follow the project it has loaded, which can be ahead of the one
  /// that is sounding until the next bar.
  public let sections: [Deck.SectionInfo]
  /// Place ids of net `i`, in the order of its tokens.
  public let placeIds: [[String]]
  /// `placeOffsets[i]..<placeOffsets[i + 1]` are net `i`'s slots in the flat token array.
  public let placeOffsets: [Int]

  public var netCount: Int { netIds.count }
  /// Total places over all nets: the length of a snapshot's `tokens`.
  public var placeCount: Int { placeOffsets.last ?? 0 }

  init(generation: Int32, trackSerial: Int32, startTick: Int, graph: WaveGraph, geometry: Project) {
    self.generation = generation
    self.trackSerial = trackSerial
    self.startTick = startTick
    netIds = graph.nets.map(\.id)
    nets = graph.nets.map {
      NetInfo($0, isStinger: graph.isStingerNet[$0.index], geometry: geometry.nets[$0.id])
    }
    sections = Deck.SectionInfo.sections(of: geometry)
    placeIds = graph.nets.map(\.placeIds)
    var offsets = [0]
    for n in graph.nets { offsets.append(offsets.last! + n.nPlaces) }
    placeOffsets = offsets
  }

  /// Net `i`'s slots in a snapshot's `tokens`.
  public func places(ofNet i: Int) -> Range<Int> { placeOffsets[i]..<placeOffsets[i + 1] }
}

/// Which snapshot you got.
public struct MarkingHeader: Equatable, Sendable {
  /// The project it belongs to; its layout is the snapshot's own `layout`, or
  /// `WaveDeckSource.markingLayout(generation:)`.
  public var generation: Int32
  /// Counts this project's publishes: 1 is the initial state, then +1 for every change
  /// (a tick, a mute). Equal sequence = same snapshot.
  public var sequence: Int
  /// The graph's tick counter (`FireEvent.tick`'s numbering).
  public var tick: Int
  /// Deck frame at the end of the render block that first showed this marking (0 for the
  /// initial state seeded at prepare time).
  public var frame: Int
}

/// A reusable main-thread buffer for one snapshot. Fill it with `WaveDeckSource.readMarking`;
/// the arrays are sized on first use and whenever the project (so the layout) changes, and
/// reused otherwise.
public struct MarkingSnapshot: Sendable {
  public var header = MarkingHeader(generation: 0, sequence: 0, tick: 0, frame: 0)
  /// The layout `tokens` / `muted` are indexed by (the snapshot's own project).
  public var layout: MarkingLayout?
  /// Tokens of every place, net after net (see `MarkingLayout.places(ofNet:)`).
  public var tokens: [Double] = []
  /// 1 where the net is muted, one entry per net.
  public var muted: [UInt8] = []

  public init() {}

  public var generation: Int32 { header.generation }
  public var tick: Int { header.tick }

  /// Tokens of net `i`'s places, in `layout.placeIds[i]` order.
  public func tokens(ofNet i: Int) -> ArraySlice<Double> {
    guard let layout, i >= 0, i < layout.netCount else { return [] }
    return tokens[layout.places(ofNet: i)]
  }

  public func isMuted(net i: Int) -> Bool { i >= 0 && i < muted.count && muted[i] != 0 }

  /// Token count of one place by ids, nil if either is unknown. For display and tests; a
  /// per-frame draw should walk `tokens` by offset.
  public func tokens(net netId: String, place placeId: String) -> Double? {
    guard let layout, let n = layout.netIds.firstIndex(of: netId),
      let p = layout.placeIds[n].firstIndex(of: placeId)
    else { return nil }
    return tokens[layout.placeOffsets[n] + p]
  }
}

/// The published copy of one project's marking. See the header comment for the protocol.
///
/// Threading: `publish` is for the one thread that runs the project (the audio thread);
/// `read` for any thread, any number of them. Created (and seeded) on the preparing thread
/// before the project is shared.
public final class MarkingMirror: @unchecked Sendable {
  public let layout: MarkingLayout
  private let netCount: Int
  private let placeCount: Int
  // Two buffers each: tokens, muted flags, [tick, frame, sequence].
  private let tokens: UnsafeMutablePointer<Double>
  private let muted: UnsafeMutablePointer<UInt8>
  private let meta: UnsafeMutablePointer<Int>
  // Per-buffer seqlock stamps: even = stable, odd = being written.
  private let stamp0 = Atomic<Int>(0)
  private let stamp1 = Atomic<Int>(0)
  /// Index of the newest complete buffer, -1 before anything is published.
  private let newest = Atomic<Int>(-1)
  private let publishes = Atomic<Int>(0)
  /// Test seam: runs in the middle of a reader's copy, to model a reader that gets preempted
  /// there while the writer laps it. Nil in production.
  var midCopyHook: (() -> Void)?
  private let retryCount = Atomic<Int>(0)
  /// How many times a reader's copy was invalidated by the writer and redone.
  var retries: Int { retryCount.load(ordering: .relaxed) }

  init(
    generation: Int32, trackSerial: Int32, startTick: Int, graph: WaveGraph, geometry: Project
  ) {
    layout = MarkingLayout(
      generation: generation, trackSerial: trackSerial, startTick: startTick, graph: graph,
      geometry: geometry)
    netCount = layout.netCount
    placeCount = layout.placeCount
    tokens = .allocate(capacity: 2 * max(placeCount, 1))
    tokens.initialize(repeating: 0, count: 2 * max(placeCount, 1))
    muted = .allocate(capacity: 2 * max(netCount, 1))
    muted.initialize(repeating: 0, count: 2 * max(netCount, 1))
    meta = .allocate(capacity: 6)
    meta.initialize(repeating: 0, count: 6)
    publish(graph, endFrame: 0)  // seed: the initial state is readable before the first render
  }

  deinit {
    tokens.deallocate()
    muted.deallocate()
    meta.deallocate()
  }

  /// Writer. Publish `graph`'s marking, mutes and tick as the state at the end of the render
  /// block that ends at `endFrame`, if it differs from what is already published. Returns
  /// whether it published. Allocation-free.
  @discardableResult
  public func publish(_ graph: WaveGraph, endFrame: Int) -> Bool {
    let cur = newest.load(ordering: .relaxed)  // only this thread writes it
    if cur >= 0 && unchanged(graph, against: cur) { return false }
    let w = cur == 0 ? 1 : 0
    let seq = publishes.load(ordering: .relaxed) + 1
    if w == 0 { stamp0.add(1, ordering: .relaxed) } else { stamp1.add(1, ordering: .relaxed) }
    atomicMemoryFence(ordering: .releasing)  // "being written" is visible before the data changes
    let tw = tokens + w * placeCount
    var o = 0
    for n in graph.nets {
      for p in 0..<n.nPlaces { tw[o + p] = n.state[p] }
      o += n.nPlaces
    }
    let mw = muted + w * netCount
    for i in 0..<netCount { mw[i] = graph.muted[i] }
    meta[w * 3] = graph.tick
    meta[w * 3 + 1] = endFrame
    meta[w * 3 + 2] = seq
    atomicMemoryFence(ordering: .releasing)  // the data is complete before the stamp says so
    if w == 0 { stamp0.add(1, ordering: .releasing) } else { stamp1.add(1, ordering: .releasing) }
    newest.store(w, ordering: .releasing)
    publishes.store(seq, ordering: .relaxed)
    return true
  }

  private func unchanged(_ graph: WaveGraph, against b: Int) -> Bool {
    if meta[b * 3] != graph.tick { return false }
    let mb = muted + b * netCount
    for i in 0..<netCount where mb[i] != graph.muted[i] { return false }
    let tb = tokens + b * placeCount
    var o = 0
    for n in graph.nets {
      for p in 0..<n.nPlaces where tb[o + p] != n.state[p] { return false }
      o += n.nPlaces
    }
    return true
  }

  /// Reader. Copy the newest snapshot into `tokens` (`layout.placeCount` entries) and `muted`
  /// (`layout.netCount` entries). Returns nil if the buffers are too small, or if a writer
  /// kept lapping the copy (not seen in practice: it retries). Never blocks, never allocates.
  public func read(
    tokens out: UnsafeMutableBufferPointer<Double>,
    muted outMuted: UnsafeMutableBufferPointer<UInt8>
  ) -> MarkingHeader? {
    guard out.count >= placeCount, outMuted.count >= netCount else { return nil }
    for _ in 0..<16 {
      let b = newest.load(ordering: .acquiring)
      if b < 0 { return nil }
      let s1 = b == 0 ? stamp0.load(ordering: .acquiring) : stamp1.load(ordering: .acquiring)
      if s1 & 1 != 0 { continue }
      if placeCount > 0 {
        let half = placeCount / 2
        out.baseAddress!.update(from: tokens + b * placeCount, count: half)
        midCopyHook?()
        (out.baseAddress! + half).update(
          from: tokens + b * placeCount + half, count: placeCount - half)
      }
      if netCount > 0 { outMuted.baseAddress!.update(from: muted + b * netCount, count: netCount) }
      let tick = meta[b * 3]
      let frame = meta[b * 3 + 1]
      let seq = meta[b * 3 + 2]
      atomicMemoryFence(ordering: .acquiring)  // the copy is done before we look at the stamp again
      let s2 = b == 0 ? stamp0.load(ordering: .relaxed) : stamp1.load(ordering: .relaxed)
      if s1 == s2 {
        return MarkingHeader(generation: layout.generation, sequence: seq, tick: tick, frame: frame)
      }
      retryCount.add(1, ordering: .relaxed)
    }
    return nil
  }

  /// Reader. `read(tokens:muted:)` into a reusable snapshot (arrays resized only if the layout
  /// differs from what the snapshot last held).
  public func read(into snap: inout MarkingSnapshot) -> Bool {
    if snap.tokens.count != placeCount { snap.tokens = [Double](repeating: 0, count: placeCount) }
    if snap.muted.count != netCount { snap.muted = [UInt8](repeating: 0, count: netCount) }
    let h = snap.tokens.withUnsafeMutableBufferPointer { t in
      snap.muted.withUnsafeMutableBufferPointer { m in read(tokens: t, muted: m) }
    }
    guard let h else { return false }
    snap.header = h
    snap.layout = layout
    return true
  }
}
