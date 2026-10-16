import Foundation

// LOOP record: hold a deck's LOOP and its sound is taken a bar at a time; let go and the bars
// become a clip in the row under the mixer, looping on the loop channel ("L"). A clip moves onto
// deck A or B like any sample, and back.
//
// Bar edges. Pressing snaps back to the downbeat of the bar already playing (the history is in
// the deck's `CaptureTap`); releasing records on to the next downbeat, unless the release came
// within a sixteenth of one, which is taken as "on the one" and ends the take there. A net deck's
// downbeats are its tick anchors (exact frames); a sample deck's come from its beat grid.
//
// Everything here is main-thread state, moved on by `serviceLoopTakes()` (the controller hub's
// housekeeping tick and the session player's).

/// One step of a sequence: a clip, played `repeats` times.
public struct SequenceStep: Sendable, Equatable {
  public var clipID: String
  public var repeats: Int
  public init(clipID: String, repeats: Int = 1) {
    self.clipID = clipID
    self.repeats = repeats
  }
}

/// A finished take: whole bars of one deck, on the row under the mixer. A sequence is one too:
/// its steps rendered back to back into one piece of audio, with the steps kept so it can be
/// edited.
public struct LoopClip: Sendable, Identifiable, Equatable {
  /// Content id of the audio (`SampleBuffer.contentID`); also its key in `sampleLibrary`.
  public let id: String
  public let title: String
  /// The deck it was taken from.
  public let source: String
  /// Its length in beats: whole bars from LOOP record, any number of beats once cropped.
  public let beats: Int
  /// Whole bars in it (rounded down; `beats` is the length).
  public var bars: Int { beats / 4 }
  /// The tempo the bars were played at (the deck's, after its tempo fader).
  public let bpm: Double
  /// The source deck's beat at the clip's first sample: a downbeat (a multiple of 4).
  public let startBeat: Double
  public let buffer: SampleBuffer
  public let waveform: WaveformOverview
  /// A sequence's recipe (nil for a take or a crop).
  public internal(set) var steps: [SequenceStep]?
  /// Where it came from (`LoopProvenance`): the deck, its track and settings when LOOP went
  /// down; for a crop or a sequence, what it was made from.
  public internal(set) var provenance: JSONValue?

  public var grid: BeatGrid { BeatGrid(bpm: bpm, offset: 0, confidence: 1) }

  public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

  init(
    id: String, title: String, source: String, beats: Int, bpm: Double, startBeat: Double,
    buffer: SampleBuffer, waveform: WaveformOverview, steps: [SequenceStep]? = nil,
    provenance: JSONValue? = nil
  ) {
    self.steps = steps
    self.provenance = provenance
    self.id = id
    self.title = title
    self.source = source
    self.beats = beats
    self.bpm = bpm
    self.startBeat = startBeat
    self.buffer = buffer
    self.waveform = waveform
  }

  init(
    id: String, title: String, source: String, bars: Int, bpm: Double, startBeat: Double,
    buffer: SampleBuffer, waveform: WaveformOverview, provenance: JSONValue? = nil
  ) {
    self.init(
      id: id, title: title, source: source, beats: bars * 4, bpm: bpm, startBeat: startBeat,
      buffer: buffer, waveform: waveform, provenance: provenance)
  }

  /// "2 bars", "6 beats".
  public var lengthLabel: String {
    beats % 4 == 0
      ? "\(bars) bar\(bars == 1 ? "" : "s")" : "\(beats) beat\(beats == 1 ? "" : "s")"
  }
}

/// A take in progress on one deck.
final class LoopTake {
  let deck: String
  /// Deck frame of the take's first downbeat.
  let start: Int
  /// The deck's beat there (a multiple of 4).
  let startBeat: Double
  /// Frames per bar at the tempo when it was pressed (a sample deck's bar length; a net deck's
  /// estimate, for the release tolerance and the fallback).
  let barFrames: Double
  /// Net decks: the next anchor sequence number to look at, and the downbeats seen since the
  /// start (the last few).
  var anchorCursor: Int
  var downs: [(frame: Int, beat: Double)] = []
  /// Set on release.
  var released: Int?
  /// Set once the end downbeat is known.
  var end: Int?
  var bars = 0
  /// The next deck frame to copy out of the capture tap.
  var cursor: Int
  var left: [Float] = []
  var right: [Float] = []
  /// The deck as LOOP went down (`LoopProvenance.capture`), and the sample it was playing.
  var provenance = JSONObject()
  var sample: SampleBuffer?

  init(deck: String, start: Int, startBeat: Double, barFrames: Double, anchorCursor: Int) {
    self.deck = deck
    self.start = start
    self.startBeat = startBeat
    self.barFrames = barFrames
    self.anchorCursor = anchorCursor
    cursor = start
  }
}

extension DJEngine {
  /// The deck names LOOP record works on (not the loop channel).
  public var recordableDecks: [String] { decks.keys.sorted() }

  /// Is LOOP held (or its last bar still finishing) on `deck`?
  public func isRecordingLoop(_ deck: String) -> Bool { loopTakes[deck] != nil }

  /// The take on `deck`, as the UI shows it: bars so far and whether it was let go.
  public func loopTakeProgress(_ deck: String) -> (bars: Int, released: Bool)? {
    guard let t = loopTakes[deck], let d = decks[deck] else { return nil }
    let now = t.released ?? d.renderedFrames
    let bars =
      t.end != nil ? t.bars : max(1, Int((Double(now - t.start) / t.barFrames).rounded(.up)))
    return (bars, t.released != nil)
  }

  /// LOOP pressed (`on`) or let go on `deck`. Pressing does nothing on a deck that is not
  /// playing or has no beat grid, or while a take on it is still finishing. Returns whether the
  /// press started (or the release ended) a take.
  @discardableResult
  public func loopRecord(_ deck: String, on: Bool) -> Bool {
    guard let d = decks[deck] else { return false }
    if !on {
      guard let t = loopTakes[deck], t.released == nil else { return false }
      t.released = d.renderedFrames
      serviceLoopTakes()
      return true
    }
    guard loopTakes[deck] == nil, d.playing, let s = d.beatState, s.bpm > 0 else { return false }
    let now = d.renderedFrames
    let barFrames = 4 * 60 / s.bpm * sampleRate
    var start = now - Int((s.barPhase * barFrames).rounded())
    var startBeat = Double(s.bar * 4)
    var cursor = 0
    if d.mode == .net {
      let ring = d.wave.anchors
      cursor = max(0, ring.written - 64)
      if let down = Self.downbeats(ring, from: &cursor).last(where: { $0.frame <= now }) {
        start = down.frame
        startBeat = down.beat
      }
    }
    let take = LoopTake(
      deck: deck, start: start, startBeat: startBeat, barFrames: barFrames, anchorCursor: cursor)
    take.provenance = LoopProvenance.capture(
      d, startBeat: startBeat, build: BuildInfo.current.build)
    take.sample = d.mode == .sample && !d.isDemo ? d.loaded : nil
    loopTakes[deck] = take
    return true
  }

  /// Move every take on: copy what the decks captured, find the end of released ones, and turn
  /// finished ones into clips. Main thread; call it often (the hub does, ~100×/s).
  public func serviceLoopTakes() {
    for (name, t) in loopTakes.sorted(by: { $0.key < $1.key }) {
      guard let d = decks[name] else {
        loopTakes[name] = nil
        continue
      }
      if t.end == nil, d.mode == .net {
        let new = Self.downbeats(d.wave.anchors, from: &t.anchorCursor).filter {
          $0.frame > t.start
        }
        t.downs = Array((t.downs + new).suffix(8))
      }
      if t.end == nil, let r = t.released { findEnd(t, deck: d, released: r) }
      t.cursor = d.capture.copy(
        from: t.cursor, to: t.end ?? Int.max, left: &t.left, right: &t.right)
      if let end = t.end, t.cursor >= end {
        loopTakes[name] = nil
        finish(t, from: d)
      }
    }
    serviceLoops()
  }

  private func findEnd(_ t: LoopTake, deck d: Deck, released r: Int) {
    let tolerance = t.barFrames / 16
    if d.mode == .net, d.playing {
      if let on = t.downs.last(where: { $0.frame <= r }), Double(r - on.frame) <= tolerance {
        t.end = on.frame
        t.bars = max(1, Int(((on.beat - t.startBeat) / 4).rounded()))
        return
      }
      if let next = t.downs.first(where: { $0.frame > r }) {
        t.end = next.frame
        t.bars = max(1, Int(((next.beat - t.startBeat) / 4).rounded()))
      }
      return  // the next downbeat has not been played yet
    }
    // A sample deck, or a net deck that stopped: whole bars at the pressed tempo.
    let elapsed = Double(r - t.start)
    t.bars = max(1, Int(((elapsed - tolerance) / t.barFrames).rounded(.up)))
    t.end = t.start + Int((Double(t.bars) * t.barFrames).rounded())
  }

  private func finish(_ t: LoopTake, from d: Deck) {
    guard let end = t.end else { return }
    let n = end - t.start
    guard n > 0, t.left.count >= n, t.right.count >= n else { return }
    let buffer = SampleBuffer(
      left: Array(t.left[0..<n]), right: Array(t.right[0..<n]), sampleRate: sampleRate)
    let id = buffer.contentID
    let bpm = Double(t.bars) * 4 * 60 * sampleRate / Double(n)
    loopCount += 1
    let clip = LoopClip(
      id: id, title: "\(t.deck) loop \(loopCount)", source: t.deck, bars: t.bars, bpm: bpm,
      startBeat: t.startBeat, buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 400),
      provenance: LoopProvenance.finish(t.provenance, bars: t.bars, bpm: bpm, sample: t.sample))
    sampleLibrary[id] = buffer
    clips.append(clip)
    startLoop(id, atOnce: true)
  }

  /// Downbeats among the anchors from `cursor` on (moving it past them): (frame, beat).
  static func downbeats(_ ring: LatestRing<TickAnchor>, from cursor: inout Int) -> [(
    frame: Int, beat: Double
  )] {
    var anchors: [TickAnchor] = []
    ring.drain(from: &cursor, into: &anchors)
    return anchors.compactMap { a in
      // anchor.tick is the counter after the tick: the step is tick - 1, beat = step / 4
      guard !a.flags.contains(.swap), a.tick >= 1, (a.tick - 1) % 16 == 0 else { return nil }
      return (Int(a.frame), Double(a.tick - 1) / 4)
    }
  }

  // MARK: clips

  public func clip(_ id: String) -> LoopClip? { clips.first { $0.id == id } }

  /// Take a clip off the row (the audio stays in `sampleLibrary`: a recorded session may name it).
  public func removeClip(_ id: String) {
    stopLoop(id, now: true)
    clips.removeAll { $0.id == id }
    for d in decks.values where d.clipID == id { d.setPlaying(false) }
  }

  /// Put clip `id` on `deck`. On "L" it joins the loops playing under the mixer (from the next
  /// downbeat, `setLooping`). On A or B it loads there as a looping sample with its grid, in
  /// time with the other deck, keeping that deck's transport; it is moved, not copied, so it
  /// stops looping under the mixer and on the other deck.
  public func playClip(_ id: String, on deck: String) {
    guard let clip = clip(id) else { return }
    if deck == loopChannel.name { return setLooping(id, true) }
    guard let target = decks[deck] else { return }
    stopLoop(id, now: true)
    for d in decks.values where d !== target && d.clipID == id && d.playing { d.setPlaying(false) }
    let wasPlaying = target.playing
    let ref = decks.values.sorted { $0.name < $1.name }.first {
      $0 !== target && $0.playing && $0.clipID != id && $0.beatState != nil
    }
    target.loadClip(clip, against: ref)
    if wasPlaying { target.launch() } else { target.setPlaying(false) }
  }

  /// Crop clip `id` to its beats `from..<to`. The cropped clip takes its place on the row (and
  /// its level); if it was looping under the mixer, the cropped one carries on in phase. A deck
  /// already playing the original keeps it. Returns the new clip's id (nil if nothing changed).
  @discardableResult
  public func cropClip(_ id: String, from: Int, to: Int) -> String? {
    guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
    let c = clips[i]
    guard 0 <= from, from < to, to <= c.beats, from > 0 || to < c.beats else { return nil }
    let perBeat = Double(c.buffer.length) / Double(c.beats)
    let a = Int((Double(from) * perBeat).rounded())
    let b = Int((Double(to) * perBeat).rounded())
    let src = c.buffer
    let buffer = SampleBuffer(
      left: Array(UnsafeBufferPointer(start: src.left + a, count: b - a)),
      right: Array(UnsafeBufferPointer(start: src.right + a, count: b - a)),
      sampleRate: src.sampleRate)
    let cropped = LoopClip(
      id: buffer.contentID, title: c.title, source: c.source, beats: to - from, bpm: c.bpm,
      startBeat: c.startBeat + Double(from), buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 400),
      provenance: LoopProvenance.crop(c, from: from, to: to))
    replace(at: i, with: cropped)
    // sequences that used the original use the crop from now on (when they are next rendered)
    for k in clips.indices {
      clips[k].steps = clips[k].steps?.map {
        $0.clipID == id ? SequenceStep(clipID: cropped.id, repeats: $0.repeats) : $0
      }
    }
    return cropped.id
  }

  /// Put `new` where the clip at `i` is: its level carries over, and if it was looping under
  /// the mixer the new one carries on in phase.
  private func replace(at i: Int, with new: LoopClip) {
    let id = clips[i].id
    let wasLooping = loopState(id) == .on || loopState(id) == .starting
    stopLoop(id, now: true)
    sampleLibrary[new.id] = new.buffer
    if let g = clipGains[id] { clipGains[new.id] = g }
    if clip(new.id) == nil { clips[i] = new } else { clips.remove(at: i) }
    if wasLooping { startLoop(new.id, atOnce: true) }
  }

  /// Join clips into a sequence: each step's clip `repeats` times, back to back, at the first
  /// clip's tempo (others are resampled to it). With `replacing`, the sequence takes that clip's
  /// place (editing a sequence); otherwise it goes on the end of the row. Steps whose clip is
  /// gone are left out. Returns the sequence's id (nil if no step has a clip).
  @discardableResult
  public func makeSequence(_ steps: [SequenceStep], replacing: String? = nil) -> String? {
    let used = steps.compactMap { s in clip(s.clipID).map { (s, $0) } }.filter { $0.0.repeats > 0 }
    guard let first = used.first?.1 else { return nil }
    let bpm = first.bpm
    var l: [Float] = []
    var r: [Float] = []
    var beats = 0
    for (step, c) in used {
      // a clip at another tempo lasts c.bpm / bpm as long at this one
      let (cl, cr) = Self.stretch(c.buffer, by: bpm / c.bpm)
      for _ in 0..<step.repeats {
        l += cl
        r += cr
        beats += c.beats
      }
    }
    let buffer = SampleBuffer(left: l, right: r, sampleRate: sampleRate)
    let names = used.map { s, c in
      (c.title.split(separator: " ").last.map(String.init) ?? c.title)
        + (s.repeats > 1 ? "×\(s.repeats)" : "")
    }
    let seq = LoopClip(
      id: Self.sequenceID(buffer), title: "seq " + names.joined(separator: "→"),
      source: first.source,
      beats: beats, bpm: bpm, startBeat: first.startBeat, buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 400), steps: used.map { $0.0 },
      provenance: LoopProvenance.sequence(used))
    if let replacing, let i = clips.firstIndex(where: { $0.id == replacing }) {
      replace(at: i, with: seq)
    } else if clip(seq.id) == nil {
      sampleLibrary[seq.id] = buffer
      clips.append(seq)
    }
    return seq.id
  }

  /// A sequence's id: its audio's content id, marked, so a one-step sequence is not its clip.
  static func sequenceID(_ b: SampleBuffer) -> String { "seq-" + b.contentID }

  /// A clip's audio read `factor` source samples per output sample (linear interpolation): at
  /// 0.5 it lasts twice as long. 1 is a plain copy.
  static func stretch(_ b: SampleBuffer, by factor: Double) -> ([Float], [Float]) {
    let l = Array(UnsafeBufferPointer(start: b.left, count: b.length))
    let r = Array(UnsafeBufferPointer(start: b.right, count: b.length))
    guard abs(factor - 1) > 1e-9 else { return (l, r) }
    let n = max(1, Int((Double(b.length) / factor).rounded()))
    func resample(_ x: [Float]) -> [Float] {
      (0..<n).map { i in
        let p = Double(i) * factor
        let i0 = min(Int(p), x.count - 1)
        let i1 = min(i0 + 1, x.count - 1)
        let f = Float(p - Double(i0))
        return x[i0] + (x[i1] - x[i0]) * f
      }
    }
    return (resample(l), resample(r))
  }

  // MARK: the loops under the mixer

  /// Where a clip is under the mixer.
  public enum LoopState: Sendable, Equatable {
    /// Not looping.
    case off
    /// Comes in at the next downbeat.
    case starting
    case on
    /// Goes out at the next downbeat.
    case stopping
  }

  public func loopState(_ id: String) -> LoopState {
    guard let bank = loopChannel.bank, let v = loopVoices.firstIndex(where: { $0.clipID == id })
    else { return .off }
    let on = bank.isActive(v)
    if loopVoices[v].stopFrame != nil { return on ? .stopping : .off }
    return on ? .on : .starting
  }

  /// How far through its loop clip `id` is under the mixer (0…1), while it sounds there.
  public func loopPlayhead(_ id: String) -> Double? {
    guard let bank = loopChannel.bank, let v = loopVoices.firstIndex(where: { $0.clipID == id }),
      bank.isActive(v)
    else { return nil }
    let tt = bank.voices[v]
    let len = Double(tt.length)
    guard len > 0 else { return nil }
    var p = tt.position.truncatingRemainder(dividingBy: len)
    if p < 0 { p += len }
    return p / len
  }

  /// The clips looping (or about to) under the mixer.
  public var loopingClips: [String] {
    loopVoices.compactMap { $0.stopFrame == nil ? $0.clipID : nil }
  }

  /// A clip's level under the mixer, 0…1 (1 by default).
  public func clipGain(_ id: String) -> Double { clipGains[id] ?? 1 }

  public func setClipGain(_ id: String, _ g: Double) {
    clipGains[id] = g
    if let v = loopVoices.firstIndex(where: { $0.clipID == id }) {
      loopChannel.bank?.send(.gain(voice: v, Float(g)))
    }
  }

  /// Start or stop clip `id` looping under the mixer, on the next downbeat. Starting a clip that
  /// is on its way out keeps it in.
  public func setLooping(_ id: String, _ on: Bool) {
    if on { startLoop(id) } else { stopLoop(id, now: false) }
  }

  /// Every loop out, on the next downbeat.
  public func stopAllLoops() {
    for id in loopingClips { stopLoop(id, now: false) }
  }

  /// `atOnce`: start now, in phase, instead of waiting for the next downbeat (a fresh take,
  /// which ends on a downbeat that has just gone by).
  func startLoop(_ id: String, atOnce: Bool = false) {
    guard let clip = clip(id), let bank = loopChannel.bank else { return }
    if let v = loopVoices.firstIndex(where: { $0.clipID == id }) {
      guard loopVoices[v].stopFrame != nil else { return }  // already in
      loopVoices[v].stopFrame = nil
      bank.send(.start(voice: v, frame: 0))  // cancels the stop
      return
    }
    guard let v = loopVoices.firstIndex(where: { $0.clipID == nil }) else { return }
    let clock = loopClock(for: clip)
    let earliest = loopChannel.renderedFrames + Self.loopLead
    let at = atOnce ? earliest : clock.nextDownbeat(after: earliest)
    let beats = Double(clip.beats)
    var b = (clock.beat(at) - (clock.ref?.name == clip.source ? clip.startBeat : 0))
      .truncatingRemainder(dividingBy: beats)
    if b < 0 { b += beats }
    let length = Double(clip.buffer.length)
    let ratio = clock.bpm.map { $0 / clip.bpm } ?? 1
    let tt = bank.voices[v]
    tt.load(clip.buffer)
    tt.send(.loop(start: 0, end: length))
    tt.send(.pitch(ratio: ratio - 1))
    tt.send(.seek(sample: b * length / beats))
    tt.send(.start)
    bank.send(.gain(voice: v, Float(clipGain(id))))
    bank.send(.start(voice: v, frame: at))
    loopVoices[v] = LoopVoice(clipID: id, ref: clock.ref?.name, ratio: ratio)
  }

  func stopLoop(_ id: String, now: Bool) {
    guard let bank = loopChannel.bank, let v = loopVoices.firstIndex(where: { $0.clipID == id })
    else { return }
    if !bank.isActive(v) && loopVoices[v].stopFrame == nil {
      // not in yet: never let it start
      bank.send(.stop(voice: v, frame: 0))
      loopVoices[v].stopFrame = 0
      return
    }
    let earliest = loopChannel.renderedFrames + (now ? 0 : Self.loopLead)
    let at = now ? earliest : loopClock(for: clip(id)).nextDownbeat(after: earliest)
    bank.send(.stop(voice: v, frame: at))
    loopVoices[v].stopFrame = at
  }

  /// Housekeeping (from `serviceLoopTakes`): free voices whose loop is out, and keep each loop
  /// at its reference deck's tempo.
  func serviceLoops() {
    guard let bank = loopChannel.bank else { return }
    let now = loopChannel.renderedFrames
    for v in loopVoices.indices {
      guard let id = loopVoices[v].clipID else { continue }
      if let stop = loopVoices[v].stopFrame {
        if now >= stop && !bank.isActive(v) { loopVoices[v] = LoopVoice() }
        continue
      }
      // moved back from a deck: the deck hands over when the loop comes in, on the downbeat
      if bank.isActive(v) {
        for d in decks.values where d.clipID == id && d.playing { d.setPlaying(false) }
      }
      guard let clip = clip(id), let ref = loopVoices[v].ref.flatMap({ decks[$0] }), ref.playing,
        let bpm = ref.effectiveBPM
      else { continue }
      let ratio = bpm / clip.bpm
      if abs(ratio - loopVoices[v].ratio) > 1e-6 {
        loopVoices[v].ratio = ratio
        bank.voices[v].send(.pitch(ratio: ratio - 1))
      }
    }
  }

  /// How far ahead of the render head a start or stop is scheduled at the least (the command
  /// must reach the audio thread first): ~43 ms at 48 kHz.
  static let loopLead = 2048

  /// What a loop lines up with: the deck it was taken from if that plays, else another playing
  /// deck, else a loop already going under the mixer, else nothing (it starts on its own).
  func loopClock(for clip: LoopClip?) -> LoopClock {
    let sr = sampleRate
    let candidates =
      ([clip.flatMap { decks[$0.source] }] + decks.values.sorted { $0.name < $1.name })
      .compactMap { $0 }
    if let ref = candidates.first(where: {
      $0.playing && $0.clipID != clip?.id && $0.beatState != nil
    }),
      let s = ref.beatState
    {
      let framesPerBeat = 60 / s.bpm * sr
      var origin = (frame: ref.renderedFrames, beat: s.beat)
      if ref.mode == .net {
        // the newest tick anchor is exact; beatState is a block's estimate
        var cursor = max(0, ref.wave.anchors.written - 4)
        var anchors: [TickAnchor] = []
        ref.wave.anchors.drain(from: &cursor, into: &anchors)
        if let a = anchors.last(where: { $0.tick >= 1 }) {
          origin = (Int(a.frame), Double(a.tick - 1) / 4)
        }
      }
      return LoopClock(ref: ref, origin: origin, framesPerBeat: framesPerBeat, bpm: s.bpm)
    }
    if let bank = loopChannel.bank,
      let v = loopVoices.indices.first(where: {
        bank.isActive($0) && loopVoices[$0].stopFrame == nil && loopVoices[$0].clipID != clip?.id
      }),
      let other = loopVoices[v].clipID.flatMap({ self.clip($0) })
    {
      let tt = bank.voices[v]
      let rate = max(1e-3, tt.currentRate)
      let samplesPerBeat = Double(other.buffer.length) / Double(other.beats)
      var pos = tt.position.truncatingRemainder(dividingBy: Double(other.buffer.length))
      if pos < 0 { pos += Double(other.buffer.length) }
      return LoopClock(
        ref: nil, origin: (loopChannel.renderedFrames, pos / samplesPerBeat),
        framesPerBeat: samplesPerBeat / rate, bpm: other.bpm * rate)
    }
    return LoopClock(
      ref: nil, origin: (loopChannel.renderedFrames, 0), framesPerBeat: 0, bpm: nil)
  }
}

/// A beat clock for lining loops up: the beat at any deck frame, and the next downbeat.
struct LoopClock {
  let ref: Deck?
  let origin: (frame: Int, beat: Double)
  /// 0: no clock (anything starts when asked, at its own tempo).
  let framesPerBeat: Double
  let bpm: Double?

  func beat(_ frame: Int) -> Double {
    framesPerBeat > 0 ? origin.beat + Double(frame - origin.frame) / framesPerBeat : 0
  }

  /// The first downbeat (a beat that is a multiple of 4) at or after `frame`.
  func nextDownbeat(after frame: Int) -> Int {
    guard framesPerBeat > 0 else { return frame }
    let b = beat(frame)
    var toGo = (4 - b.truncatingRemainder(dividingBy: 4)).truncatingRemainder(dividingBy: 4)
    if toGo < 0 { toGo += 4 }
    return frame + Int((toGo * framesPerBeat).rounded(.up))
  }
}

/// One voice of the loop bank, as the main thread sees it.
struct LoopVoice {
  var clipID: String?
  /// The deck whose tempo it follows.
  var ref: String?
  var ratio = 1.0
  /// Set once it is told to stop (it goes out at this frame).
  var stopFrame: Int?
}

extension Deck {
  /// Load a clip as a looping sample with its grid, its tempo matched to `ref` and its playhead
  /// at the point of the loop that lines up with `ref`'s bar.
  func loadClip(_ clip: LoopClip, against ref: Deck?) {
    load(clip.buffer, title: clip.title)
    clipID = clip.id
    setBeatGrid(clip.grid)
    let length = Double(clip.buffer.length)
    setLoop(0, length)
    var offset = 0.0
    if let ref, let r = ref.beatState, let target = ref.effectiveBPM {
      pitch = (Self.tempoMatch(base: clip.bpm, target: target).ratio - 1) / Self.pitchRange
      let beats = Double(clip.beats)
      var b = (r.beat - clip.startBeat).truncatingRemainder(dividingBy: beats)
      if b < 0 { b += beats }
      offset = b * length / beats
    } else {
      pitch = 0
    }
    if offset > 0 { turntable.send(.seek(sample: offset)) }
  }
}
