import Foundation

// Rebuilding state from a journal: a fresh offline engine stood where the checkpoint says, then
// every event applied at its frame by the same `OfflineConductor` steps `SessionPlayer` takes,
// and the stores rebuilt by the stores' own edit functions. Deterministic: two replays of one
// file are the same state and the same audio.
//
// A replay starts from the nearest checkpoint at or before where it is asked to stop (a mid-file
// one, `Journal.checkpoint`, puts the decks at their playheads), so seeking late into a long set
// doesn't render it all. That gives the same *state* as a replay from line 0, not the same
// audio: a mid checkpoint restarts loop clips from their beginnings, puts a sample deck back to
// within a block of where it was, and starts the decks' effect tails, reverbs and the controller
// router's own state (pickup, shift) fresh. `fromStart` replays from line 0 for audio that is
// byte-identical to the live run.
//
// A rewind (`AppModel.rewindJournal`) appends, never rewrites: its stores (`storesReplace`), a
// `rewind <seq>` mark, and a checkpoint with playheads, the state it stood the app at. Nothing
// before that checkpoint carries over, so a replay past it starts there (even `fromStart`), and
// `exportSession` refuses a slice with a rewind in it.

public enum JournalError: Error, Equatable, CustomStringConvertible {
  /// The file doesn't start with a checkpoint (empty, or not a journal).
  case noCheckpoint
  /// `export-session` was given a slice with nothing in it.
  case emptySlice
  /// `export-session` was given a slice with a rewind in it (the rewind mark's seq).
  case spansRewind(Int)
  public var description: String {
    switch self {
    case .noCheckpoint: "the journal does not start with a checkpoint"
    case .emptySlice: "no events in that slice"
    case .spansRewind(let seq): "the slice spans a rewind (seq \(seq)): export either side of it"
    }
  }
}

/// What a replay rebuilt.
public struct JournalReplayResult: Sendable {
  /// The state at the end (`JournalState(engine:stores:)` of the rebuilt engine).
  public let state: JournalState
  /// The stores as rebuilt.
  public var stores: JournalStoreState { state.stores }
  /// The checkpoint the replay started from (0: line 0; else a mid-file one).
  public let startSeq: Int
  /// The last entry applied (the start checkpoint's if none).
  public let lastSeq: Int
  /// Engine frames from line 0 to where the replay stopped (a replay from a mid checkpoint
  /// counts the frames before it too, though it didn't render them).
  public let frames: Int
  /// The audio, when asked for: from the start checkpoint on (`startSeq`; pass `fromStart` for
  /// the whole file).
  public let audio: RenderedAudio?
  /// What could not be rebuilt (a clip or sample whose audio is gone).
  public let warnings: [String]
}

extension Journal {
  /// Replay `contents` into a fresh offline engine: the checkpoint, then the events in order at
  /// their frames, up to sequence number `toSeq` (all with nil), rendering at least to `endFrame`
  /// frames after line 0 (`atSeconds` × rate on the command line). It starts from the last
  /// checkpoint inside those bounds (see the top of this file), or line 0 with `fromStart`.
  /// `samples` resolves a sample's content id (the `sampleFile` events' paths are tried too);
  /// `clips` finds a loop clip's audio by id (the loop library). `render` keeps the audio;
  /// `playheads` keeps where each deck ended up in the result's state (`DeckCheckpoint.position`,
  /// what a rewind stands the live decks at). A rewind's checkpoint is as far back as it goes.
  public static func replay(
    _ contents: Contents, toSeq: Int? = nil, endFrame: Int? = nil, render: Bool = false,
    fromStart: Bool = false, playheads: Bool = false,
    samples: @escaping (String) -> SampleBuffer? = { _ in nil },
    clips: @escaping (String) -> LoopClip? = { _ in nil }
  ) throws -> JournalReplayResult {
    guard let head = contents.checkpoint, let first = contents.entries.first else {
      throw JournalError.noCheckpoint
    }
    let origin = first.frame
    func inBounds(_ e: JournalEntry) -> Bool {
      (toSeq.map { e.seq <= $0 } ?? true) && (endFrame.map { e.frame - origin <= $0 } ?? true)
    }
    // the start: the last checkpoint in bounds (line 0 always is: it is where the file begins);
    // a rewind's checkpoint counts from its mark on (the two are one step)
    let rewinds = Set(contents.rewindCheckpointIndices)
    func startable(_ i: Int) -> Bool {
      inBounds(contents.entries[i]) || (rewinds.contains(i) && inBounds(contents.entries[i - 1]))
    }
    let checkpoints = contents.checkpointIndices.filter(startable)
    var startIndex = checkpoints.last { rewinds.contains($0) } ?? 0
    if !fromStart { startIndex = checkpoints.last ?? 0 }
    let start = contents.entries[startIndex]
    guard case .checkpoint(var state) = start.event else { throw JournalError.noCheckpoint }
    if !state.hasStores {
      // a mid checkpoint has no stores: line 0's, then the store events before it
      var s = head.stores
      for e in contents.entries.prefix(startIndex).dropFirst() { s.apply(e.event) }
      state.stores = s
      state.hasStores = true
    }
    let base = start.frame
    let offset = base - origin
    let events = contents.entries[(startIndex + 1)...].filter(inBounds)
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
    let endHere = endFrame.map { max(0, $0 - offset) }
    let end = max(endHere ?? 0, lastFrame)
    var left: [Float] = []
    var right: [Float] = []
    var next = events.startIndex
    var lastSeq = start.seq
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
    if render, let endHere, left.count > endHere {
      left.removeLast(left.count - endHere)
      right.removeLast(right.count - endHere)
    }
    return JournalReplayResult(
      state: JournalState(engine: dj, stores: stores, playheads: playheads), startSeq: start.seq,
      lastSeq: lastSeq,
      frames: dj.frame + offset,
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
      // an import's audio comes by content id: the library, `samples`, or a `sampleFile` path
      if case .clipImport(let id, let title, _, _, _) = a, dj.clip(id) == nil,
        dj.sampleResolver?(id) == nil
      {
        warnings.append("imported clip \(title.isEmpty ? id : title) has no audio")
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
    if let r = slice.first(where: \.event.isRewindMark) { throw JournalError.spansRewind(r.seq) }
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
      master: at.master, events: events, autoMix: at.autoMix.start)
  }
}

extension Journal {
  /// The mark a rewind to `seq` writes (`AppModel.rewindJournal`).
  public static func rewindMark(_ seq: Int) -> String { "rewind \(seq)" }
}

extension JournalEvent {
  /// A rewind's mark (`Journal.rewindMark`).
  public var isRewindMark: Bool {
    if case .mark(let t) = self { t.hasPrefix("rewind ") } else { false }
  }
}

extension Journal.Contents {
  /// The checkpoints rewinds wrote (indices in `entries`): each one right after its mark.
  public var rewindCheckpointIndices: [Int] {
    checkpointIndices.filter { $0 > 0 && entries[$0 - 1].event.isRewindMark }
  }
}

extension DeckAction {
  /// The row clips an action names.
  var clipIDs: [String] {
    switch self {
    case .clip(_, let id), .clipLoop(let id, _), .clipGain(let id, _), .clipCrop(let id, _, _),
      .clipRetune(let id, _), .clipRemove(let id), .clipRename(let id, _), .clipColor(let id, _),
      .clipMute(let id, _),
      .clipSolo(let id, _), .clipKeyLock(let id, _), .clipFx(let id, _),
      .clipQuantize(let id, _), .clipFade(let id, _), .clipFollow(let id, _):
      return [id]
    case .clipMove(let id, let before): return [id] + (before.map { [$0] } ?? [])
    case .clipSequence(let steps, let replacing):
      return steps.map(\.clipID) + (replacing.map { [$0] } ?? [])
    case .sceneLaunch(_, let clips): return clips?.map(\.clipID) ?? []
    default: return []
    }
  }
}
