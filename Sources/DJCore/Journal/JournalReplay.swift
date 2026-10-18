import Foundation

// Rebuilding state from a journal: a fresh offline engine stood where the checkpoint says, then
// every event applied at its frame by the same `OfflineConductor` steps `SessionPlayer` takes,
// and the stores rebuilt by the stores' own edit functions. Deterministic: two replays of one
// file are the same state and the same audio.

public enum JournalError: Error, Equatable, CustomStringConvertible {
  /// The file doesn't start with a checkpoint (empty, or not a journal).
  case noCheckpoint
  /// `export-session` was given a slice with nothing in it.
  case emptySlice
  public var description: String {
    switch self {
    case .noCheckpoint: "the journal does not start with a checkpoint"
    case .emptySlice: "no events in that slice"
    }
  }
}

/// What a replay rebuilt.
public struct JournalReplayResult {
  /// The state at the end (`JournalState(engine:stores:)` of the rebuilt engine).
  public let state: JournalState
  /// The stores as rebuilt.
  public var stores: JournalStoreState { state.stores }
  /// The last entry applied (the checkpoint's 0 if none).
  public let lastSeq: Int
  /// Engine frames rendered, from the checkpoint.
  public let frames: Int
  /// The audio, when asked for.
  public let audio: RenderedAudio?
  /// What could not be rebuilt (a clip or sample whose audio is gone).
  public let warnings: [String]
}

extension Journal {
  /// Replay `contents` into a fresh offline engine: the checkpoint, then the events in order at
  /// their frames, up to sequence number `toSeq` (all with nil), rendering at least to `endFrame`
  /// frames after the checkpoint (`atSeconds` × rate on the command line). `samples` resolves a
  /// sample's content id (the `sampleFile` events' paths are tried too); `clips` finds a loop
  /// clip's audio by id (the loop library). `render` keeps the audio.
  public static func replay(
    _ contents: Contents, toSeq: Int? = nil, endFrame: Int? = nil, render: Bool = false,
    samples: @escaping (String) -> SampleBuffer? = { _ in nil },
    clips: @escaping (String) -> LoopClip? = { _ in nil }
  ) throws -> JournalReplayResult {
    guard let state = contents.checkpoint, let first = contents.entries.first else {
      throw JournalError.noCheckpoint
    }
    let base = first.frame
    let events = contents.entries.dropFirst().filter { e in
      (toSeq.map { e.seq <= $0 } ?? true) && (endFrame.map { e.frame - base <= $0 } ?? true)
    }
    let dj = try DJEngine(
      decks: state.decks.keys.sorted(), offline: true, sampleRate: state.sampleRate)
    dj.deterministic = true
    var paths: [String: String] = [:]
    for e in contents.entries {
      if case .sampleFile(let id, let path) = e.event { paths[id] = path }
    }
    let sr = state.sampleRate
    dj.sampleResolver = { [unowned dj] id in
      if let b = dj.sampleLibrary[id] ?? samples(id) { return b }
      guard let path = paths[id],
        let b = try? Deck.decode(URL(fileURLWithPath: path), sampleRate: sr)
      else { return nil }
      dj.sampleLibrary[id] = b
      return b
    }
    var warnings: [String] = []
    for id in state.sampleIDs where dj.sampleResolver?(id) == nil {
      warnings.append("sample \(id) not found")
    }
    var stores = state.stores
    warnings += state.restore(into: dj, clip: clips)
    try dj.start()
    defer { dj.stop() }

    let router = ControllerRouter(engine: dj)
    var attached = Set<String>()
    let conductor = OfflineConductor(engine: dj, router: router)
    let lastFrame = events.last.map { $0.frame - base } ?? 0
    let end = max(endFrame ?? 0, lastFrame)
    var left: [Float] = []
    var right: [Float] = []
    var next = events.startIndex
    var lastSeq = first.seq
    // At least one block, so the last event's effects are rendered.
    repeat {
      let (l, r) = try conductor.step {
        while next < events.endIndex, events[next].frame - base <= dj.frame {
          let e = events[next]
          apply(
            e.event, dj: dj, router: router, attached: &attached, stores: &stores,
            clips: clips, warnings: &warnings, now: conductor.now)
          lastSeq = e.seq
          next += 1
        }
      }
      if l.isEmpty { break }
      if render {
        left += l
        right += r
      }
    } while next < events.endIndex || dj.frame < end
    if render, let endFrame, left.count > endFrame {
      left.removeLast(left.count - endFrame)
      right.removeLast(right.count - endFrame)
    }
    return JournalReplayResult(
      state: JournalState(engine: dj, stores: stores), lastSeq: lastSeq, frames: dj.frame,
      audio: render ? RenderedAudio(sampleRate: sr, left: left, right: right) : nil,
      warnings: warnings)
  }

  private static func apply(
    _ event: JournalEvent, dj: DJEngine, router: ControllerRouter, attached: inout Set<String>,
    stores: inout JournalStoreState, clips: (String) -> LoopClip?, warnings: inout [String],
    now: TimeInterval
  ) {
    if stores.apply(event) { return }
    switch event {
    case .action(let a):
      // A clip this replay didn't make (a live take that rendered differently) comes from the
      // library, so the moves on it still land.
      for id in a.clipIDs
      where dj.clip(id) == nil && !dj.removedClips.contains(where: { $0.clip.id == id }) {
        if let c = clips(id) { dj.restoreClips([c]) }
      }
      dj.applyAction(a)
    case .midi(let port, let bytes):
      if !attached.contains(port) {
        router.attach(port: port)
        attached.insert(port)
      }
      router.route(port: port, bytes: bytes, now: now)
    case .libraryRestore(let id, let index):
      if let c = clips(id) {
        dj.rememberRemovedClip(c, at: index)
      } else {
        warnings.append("library clip \(id) has no audio")
      }
    case .checkpoint, .sampleFile, .mark: break
    default: break
    }
  }

  /// The slice `from…to` (sequence numbers, inclusive) as a normal `Session`: the state at
  /// `from` (replayed) is its start — the decks' sources and knobs; a deck that was playing gets
  /// a `play` at frame 0 — then the slice's actions and MIDI, rebased. A session starts every
  /// deck at its beginning with an empty loop row, so playheads and clips already on the row at
  /// `from` are not in it. `tail`: seconds kept after the last event.
  public static func exportSession(
    _ contents: Contents, from: Int, to: Int, tail: Double = 2,
    samples: @escaping (String) -> SampleBuffer? = { _ in nil },
    clips: @escaping (String) -> LoopClip? = { _ in nil }
  ) throws -> Session {
    guard let first = contents.entries.first, contents.checkpoint != nil else {
      throw JournalError.noCheckpoint
    }
    let slice = contents.entries.filter { $0.seq >= max(from, 1) && $0.seq <= to }
    guard let start = slice.first, let last = slice.last else { throw JournalError.emptySlice }
    let at = try replay(
      contents, toSeq: start.seq - 1, endFrame: start.frame - first.frame, samples: samples,
      clips: clips
    ).state
    var events: [SessionEvent] = []
    for a in at.loopSettings where !DJEngine.defaultLoopSettings.contains(a) {
      events.append(SessionEvent(frame: 0, kind: .action(a)))
    }
    for k in at.locked {
      events.append(SessionEvent(frame: 0, kind: .action(.lock(key: k, on: true))))
    }
    for name in at.decks.keys.sorted() where at.decks[name]!.playing {
      events.append(SessionEvent(frame: 0, kind: .action(.play(deck: name, on: true))))
    }
    for e in slice {
      let f = e.frame - start.frame
      switch e.event {
      case .action(let a): events.append(SessionEvent(frame: f, kind: .action(a)))
      case .midi(let p, let b):
        events.append(SessionEvent(frame: f, kind: .midi(port: p, bytes: b)))
      default: break
      }
    }
    let params = at.decks.mapValues(\.params)
    return Session(
      sampleRate: at.sampleRate,
      frames: last.frame - start.frame + Int(tail * at.sampleRate),
      decks: at.decks.mapValues(\.source), params: params, crossfader: at.crossfader,
      master: at.master, events: events)
  }
}

extension DeckAction {
  /// The row clips an action names.
  var clipIDs: [String] {
    switch self {
    case .clip(_, let id), .clipLoop(let id, _), .clipGain(let id, _), .clipCrop(let id, _, _),
      .clipRemove(let id), .clipRename(let id, _), .clipColor(let id, _), .clipMute(let id, _),
      .clipSolo(let id, _), .clipKeyLock(let id, _), .clipFx(let id, _),
      .clipQuantize(let id, _), .clipFade(let id, _):
      return [id]
    case .clipMove(let id, let before): return [id] + (before.map { [$0] } ?? [])
    case .clipSequence(let steps, let replacing):
      return steps.map(\.clipID) + (replacing.map { [$0] } ?? [])
    case .sceneLaunch(_, let clips): return clips?.map(\.clipID) ?? []
    default: return []
    }
  }
}
