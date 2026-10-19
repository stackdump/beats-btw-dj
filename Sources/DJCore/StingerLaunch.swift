import Foundation

// Firing a curated stinger (StingerCuration.swift) on a net deck: a one-shot on the Hit's
// stinger net, a macro through the macro path, a loop on the loop row in the deck's time.

private struct StingerEngineRef: @unchecked Sendable {
  weak var engine: DJEngine?
}

extension Deck {
  /// What Hit 1–4 fire on this deck's track (four fallbacks when nothing is curated; empty for a
  /// sample deck).
  public var stingers: [StingerAssignment] {
    guard mode == .net else { return [] }
    let curated = netProject?.stingers ?? []
    return (0..<StingerCuration.slotCount).map { n in
      curated.first { $0.slot == n } ?? .fallback(n)
    }
  }

  /// The Hits resolved again for the deck's track from its genre, palette, seed, key and tempo
  /// (a palette change), onto `project`. A track with no genre (a raw-`nets` share) keeps none.
  func curateStingers(_ project: inout Project) {
    guard let genre = currentSpec?.genre else {
      project.curateStingers([], seed: voicingSeed)
      return
    }
    project.curateStingers(
      project.resolvedStingers(genre: genre, seed: voicingSeed, installed: .here),
      seed: voicingSeed)
  }

  /// Stinger `n` (0…3, Hit 1…4) as curated: a one-shot unmutes its stinger net (`hit1`…) for
  /// its bars, a macro fires, a loop launches on the loop row (`onStingerLoop`). A Hit that
  /// cannot fire what it was given (a loop whose audio is gone) plays its stinger net.
  public func stinger(_ n: Int, bars: Int = 1) {
    guard mode == .net, (0..<StingerCuration.slotCount).contains(n) else { return }
    let a = stingers[n]
    switch a.kind {
    case .oneShot:
      wave.fireStinger(a.netID, ticks: (a.bars ?? bars) * 16)
      return
    case .macro:
      if let id = a.macro, fireMacro(id: id, duration: a.bars) { return }
    case .loop:
      if onStingerLoop?(a) == true { return }
    case .fallback:
      break
    }
    wave.fireStinger(a.netID, ticks: bars * 16)
  }
}

extension DJEngine {
  /// Launch a stinger's loop on the loop row, from its top, on the next launch boundary of
  /// `deck`'s time, for one pass. A stock loop is decoded once (off the main thread; inline when
  /// deterministic) and kept in `stingerClips`, never put on the row. False when it can't play
  /// (no loop channel, no such clip, unreadable audio): the deck then plays its stinger net.
  func fireStingerLoop(_ a: StingerAssignment, on deck: Deck) -> Bool {
    guard let loop = a.loop, loopChannel.bank != nil else { return false }
    if let id = loop.clipID {
      guard clip(id) != nil else { return false }
      launchStingerClip(id, on: deck)
      return true
    }
    guard let path = loop.path else { return false }
    let id = "stinger-\(deck.name)-\(String(VoiceCatalog.stableHash(path), radix: 16))"
    if stingerClips[id] != nil {
      launchStingerClip(id, on: deck)
      return true
    }
    let sr = sampleRate
    let source = deck.name
    let make: @Sendable () -> LoopClip? = {
      guard let buffer = try? Deck.decode(URL(fileURLWithPath: path), sampleRate: sr),
        buffer.length > 0
      else { return nil }
      let bpm = Double(loop.beats) * 60 * sr / Double(buffer.length)
      return LoopClip(
        id: id, title: loop.name, source: source, beats: loop.beats, bpm: bpm, startBeat: 0,
        buffer: buffer, waveform: WaveformOverview(buffer: buffer, columns: 200),
        provenance: .object(
          JSONObject([("stinger", .string(a.candidate ?? "")), ("localOnly", .bool(true))])))
    }
    if deterministic {
      guard let c = make() else { return false }
      stingerClips[id] = c
      launchStingerClip(id, on: deck)
      return true
    }
    let ref = StingerEngineRef(engine: self)
    let deckName = deck.name
    Task.detached(priority: .userInitiated) {
      let c = make()
      await MainActor.run {
        guard let engine = ref.engine, let c, let d = engine.decks[deckName] else { return }
        engine.stingerClips[c.id] = c
        engine.launchStingerClip(c.id, on: d)
      }
    }
    return true
  }

  /// Start a stinger clip from its top and have it go out after one pass. One already sounding
  /// (or on its way in or out) is left as it is.
  func launchStingerClip(_ id: String, on deck: Deck) {
    guard let clip = clip(id), !loopVoices.contains(where: { $0.clipID == id }) else { return }
    startLoop(id, fromTop: true, prefer: deck)
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id }),
      let start = loopVoices[v].startFrame
    else { return }
    let pass = Double(clip.beats) * 60 / max(loopVoices[v].targetBPM, 1) * sampleRate
    stingerStops[id] = start + Int(pass.rounded())
  }

  /// Schedule each launched stinger loop's stop once its voice is in (a stop sent before then
  /// would cancel the start), and forget the ones that are out.
  func serviceStingerStops(_ bank: LoopBank) {
    for (id, frame) in stingerStops {
      guard let v = loopVoices.firstIndex(where: { $0.clipID == id }) else {
        stingerStops[id] = nil
        continue
      }
      guard bank.isActive(v), loopVoices[v].stopFrame == nil else { continue }
      stopLoop(id, now: false, at: frame)
      stingerStops[id] = nil
    }
  }
}
