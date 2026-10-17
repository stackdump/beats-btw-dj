import Foundation

/// Captures a performance: the engine's starting state, then every input with the frame it
/// arrived on. Attach with `SessionRecorder.start(on:)`; hardware MIDI is recorded by the
/// `ControllerRouter`, everything else by `DJEngine.perform`.
public final class SessionRecorder {
  private let engine: DJEngine
  private let startFrame: Int
  private let initial: (decks: [String: DeckSourceDescriptor], params: [String: DeckParams])
  private let crossfader: Double
  private let master: Double
  private let lock = NSLock()
  private var events: [SessionEvent] = []

  /// Begin recording. The engine must be at rest: every deck stopped at its beginning with
  /// no cues or loops, holding audio or a composed track a replay can name.
  @discardableResult
  public static func start(on engine: DJEngine) throws -> SessionRecorder {
    let r = try SessionRecorder(engine)
    engine.recorder = r
    return r
  }

  init(_ engine: DJEngine) throws {
    self.engine = engine
    startFrame = engine.frame
    var decks: [String: DeckSourceDescriptor] = [:]
    var params: [String: DeckParams] = [:]
    for (name, d) in engine.decks {
      decks[name] = try d.sourceDescriptor()
      params[name] = d.currentParams
    }
    initial = (decks, params)
    crossfader = engine.crossfader
    master = engine.master
  }

  func record(midi port: String, _ bytes: [UInt8]) {
    append(.midi(port: port, bytes: bytes))
  }

  func record(_ action: DeckAction) { append(.action(action)) }

  private func append(_ kind: SessionEventKind) {
    let f = engine.frame - startFrame
    lock.withLock { events.append(SessionEvent(frame: f, kind: kind)) }
  }

  /// Stop recording and return the session.
  public func finish() -> Session {
    if engine.recorder === self { engine.recorder = nil }
    return Session(
      sampleRate: engine.sampleRate, frames: engine.frame - startFrame, decks: initial.decks,
      params: initial.params, crossfader: crossfader, master: master,
      events: lock.withLock { events })
  }
}

extension Deck {
  /// What this deck holds, as a session can name it.
  func sourceDescriptor() throws -> DeckSourceDescriptor {
    if playing || wave.isPlaying { throw SessionError.notAtRest(deck: name) }
    switch mode {
    case .net:
      let source: DeckSourceDescriptor
      if let spec = currentSpec {
        source = .net(spec)
      } else if let payload = currentRawNets {
        source = .rawNets(payload: payload)
      } else {
        throw SessionError.unrecordable(deck: name)
      }
      if wave.tick != 0 || !hotCues.isEmpty { throw SessionError.notAtRest(deck: name) }
      return source
    case .sample:
      guard let buffer = loaded else { return .none }
      if turntable.position != 0 || !hotCues.isEmpty || looping || cuePoint != 0 {
        throw SessionError.notAtRest(deck: name)
      }
      return .sample(
        id: isDemo ? DeckSourceDescriptor.demoID : buffer.contentID, title: title, grid: beatGrid)
    }
  }

  var currentParams: DeckParams {
    var p = DeckParams()
    p.volume = volume
    p.gain = gain
    p.filter = filter
    p.eqLow = eqLow
    p.eqMid = eqMid
    p.eqHigh = eqHigh
    p.pitch = pitch
    p.quantize = quantize == .off ? "off" : (quantize == .beat ? "beat" : "bar")
    p.autoAdvance = autoAdvance
    p.reverbWet = reverb.wet
    p.reverbSize = reverb.size
    p.reverbTone = reverb.tone
    return p
  }

  func apply(_ p: DeckParams) {
    volume = p.volume
    gain = p.gain
    filter = p.filter
    eqLow = p.eqLow
    eqMid = p.eqMid
    eqHigh = p.eqHigh
    pitch = p.pitch
    quantize = p.quantize == "beat" ? .beat : (p.quantize == "bar" ? .bar : .off)
    autoAdvance = p.autoAdvance
    reverb.wet = p.reverbWet
    reverb.size = p.reverbSize
    reverb.tone = p.reverbTone
  }
}

extension DJEngine {
  /// Apply an input and record it (when a recorder is attached). This is the one path for
  /// anything a UI does to a deck; hardware goes through the `ControllerRouter`.
  ///
  /// `prepared` / `buffer` let a live caller hand over audio or a composed track it already
  /// has instead of having `perform` build it again.
  public func perform(
    _ action: DeckAction, prepared: PreparedTrack? = nil, buffer: SampleBuffer? = nil
  ) {
    var recorded = action
    // A sample loaded from a file is named by its content id, known only now.
    if case .load(let deck, .sample(_, let title, _)) = action, let buffer {
      let id = buffer.contentID
      sampleLibrary[id] = buffer
      recorded = .load(deck: deck, source: .sample(id: id, title: title, grid: nil))
    }
    if let gridded = applyAction(action, prepared: prepared, buffer: buffer),
      case .load(let deck, .sample(let id, let title, _)) = recorded
    {
      recorded = .load(deck: deck, source: .sample(id: id, title: title, grid: gridded))
    }
    recorder?.record(recorded)
  }

  /// Run an action. Returns the beat grid of a freshly loaded sample, for the record.
  @discardableResult
  func applyAction(
    _ action: DeckAction, prepared: PreparedTrack? = nil, buffer: SampleBuffer? = nil
  )
    -> BeatGrid?
  {
    func deck(_ n: String) -> Deck? { self[n] }
    switch action {
    case .play(let n, let on): deck(n)?.setPlaying(on)
    case .cue(let n): deck(n)?.cue()
    case .hotCue(let n, let slot): deck(n)?.hotCue(slot)
    case .clearCue(let n, let slot): deck(n)?.clearCue(slot)
    case .loop(let n, let op):
      switch op {
      case "in": deck(n)?.loopIn()
      case "out": deck(n)?.loopOut()
      case "halve": deck(n)?.loopHalve()
      case "double": deck(n)?.loopDouble()
      default: break
      }
    case .param(let n, let name, let v):
      owners["\(n).\(name)"] = "ui"
      guard let d = deck(n) else { break }
      switch name {
      case "volume": d.volume = v
      case "filter": d.filter = v
      case "gain": d.gain = v
      case "eqLow": d.eqLow = v
      case "eqMid": d.eqMid = v
      case "eqHigh": d.eqHigh = v
      case "pitch": d.pitch = v
      case "mute": d.mute = v > 0.5
      case "reverbWet": d.reverb.wet = v
      case "reverbSize": d.reverb.size = v
      case "reverbTone": d.reverb.tone = v
      default: break
      }
    case .crossfader(let v):
      owners["crossfader"] = "ui"
      crossfader = v
    case .master(let v):
      owners["master"] = "ui"
      master = v
    case .load(let n, let source):
      guard let d = deck(n) else { break }
      switch source {
      case .none: break
      case .net, .rawNets:
        if let track = prepared
          ?? PreparedTrack(source: source, sampleRate: sampleRate, opts: d.waveOptions)
        {
          d.loadNet(track)
        }
      case .sample(let id, let title, let grid):
        if id == DeckSourceDescriptor.demoID {
          d.loadDemo()
        } else if let b = buffer ?? sampleResolver?(id) {
          d.load(b, title: title)
          // A recorded grid stands in for the (asynchronous) tempo analysis; live, with
          // none recorded, the analysis runs and its result is recorded when it lands.
          if let grid {
            d.setBeatGrid(grid)
          } else if !deterministic {
            d.analyze(b)
          }
          return d.beatGrid
        }
      }
    case .queueNext(let n, let spec): deck(n)?.queueNext(spec)
    case .nextTrack(let n): deck(n)?.skipToNextTrack()
    case .autoAdvance(let n, let on): deck(n)?.autoAdvance = on
    case .section(let n, let i): deck(n)?.launchSection(i)
    case .role(let n, let role, let on): deck(n)?.setRole(role, on: on)
    case .macro(let n, let id): deck(n)?.fireMacro(id: id)
    case .panic(let n): deck(n)?.panic()
    case .stinger(let n, let k): deck(n)?.stinger(k)
    case .sync(let n, let align):
      if let d = deck(n),
        let other = decks.values.sorted(by: { $0.name < $1.name }).first(where: { $0 !== d })
      {
        d.sync(to: other, align: align == "bar" ? .bar : (align == "tempo" ? .tempoOnly : .beat))
      }
    case .quantize(let n, let mode):
      deck(n)?.quantize = mode == "beat" ? .beat : (mode == "bar" ? .bar : .off)
    case .follow(let n, let leader): deck(n)?.follow(leader.flatMap { decks[$0] })
    case .grid(let n, let bpm, let offset):
      deck(n)?.setBeatGrid(BeatGrid(bpm: bpm, offset: offset, confidence: 1))
    case .loopRecord(let n, let on): loopRecord(n, on: on)
    case .clip(let n, let id): playClip(id, on: n)
    case .clipLoop(let id, let on): setLooping(id, on)
    case .clipGain(let id, let v): setClipGain(id, v)
    case .clipCrop(let id, let from, let to): cropClip(id, from: from, to: to)
    case .clipSequence(let steps, let replacing): makeSequence(steps, replacing: replacing)
    case .clipRemove(let id): removeClip(id)
    case .clipRestore(let id, let at): restoreClip(id, at: at)
    case .clipForget(let id): forgetRemovedClip(id)
    case .clipRename(let id, let title): renameClip(id, title)
    case .clipColor(let id, let color): setClipColor(id, color)
    }
    return nil
  }
}
