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
// A tap (let go within `loopTapFrames`, a quarter of a second of deck time, of the press) is a
// fixed-length take when the press named a length: from the same downbeat, exactly that many
// bars, ending by itself. A hold is as above.
//
// After the fact: `grabLastBars` takes the last whole bars a deck has already played straight
// out of its capture history, ending on the downbeat just gone.
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
  /// Content id of the audio as it was made (`SampleBuffer.contentID`); also its key in
  /// `sampleLibrary`. A clip the library brings back at another sample rate keeps it, though its
  /// resampled audio would hash differently.
  public let id: String
  /// Its name on the row ("A loop 3" until renamed, `DJEngine.renameClip`).
  public internal(set) var title: String
  /// Its colour on the row, one of `LoopClip.palette` (nil: none picked).
  public internal(set) var color: String?
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
    provenance: JSONValue? = nil, color: String? = nil
  ) {
    self.steps = steps
    self.provenance = provenance
    self.color = color
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

  /// The colours a clip can be given, by name (the views pick the shades).
  public static let palette = [
    "red", "orange", "yellow", "green", "teal", "blue", "violet", "pink",
  ]

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
  /// Deck frame of the press itself (a tap is measured from it).
  let pressed: Int
  /// Bars a tap records (from the press); nil: a tap is a short hold.
  let fixedBars: Int?
  /// Let go within `loopTapFrames` of the press, with `fixedBars` set: ends after them.
  var tapped = false
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

  init(
    deck: String, start: Int, startBeat: Double, barFrames: Double, anchorCursor: Int,
    pressed: Int, fixedBars: Int? = nil
  ) {
    self.deck = deck
    self.start = start
    self.startBeat = startBeat
    self.pressed = pressed
    self.fixedBars = fixedBars
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
      t.end != nil
      ? t.bars
      : t.tapped
        ? t.fixedBars ?? 1 : max(1, Int((Double(now - t.start) / t.barFrames).rounded(.up)))
    return (bars, t.released != nil)
  }

  /// How soon after the press a release counts as a tap: 250 ms of deck frames.
  public var loopTapFrames: Int { Int((0.25 * sampleRate).rounded()) }

  /// LOOP pressed (`on`) or let go on `deck`. Pressing does nothing on a deck that is not
  /// playing or has no beat grid, or while a take on it is still finishing. With `bars` on the
  /// press, a release within `loopTapFrames` makes it a take of exactly that many bars (1…64)
  /// from the downbeat the press snapped to; a later release ends it as a hold does. Returns
  /// whether the press started (or the release ended) a take.
  @discardableResult
  public func loopRecord(_ deck: String, on: Bool, bars: Int? = nil) -> Bool {
    guard let d = decks[deck] else { return false }
    if !on {
      guard let t = loopTakes[deck], t.released == nil else { return false }
      let r = d.renderedFrames
      t.released = r
      t.tapped = t.fixedBars != nil && r - t.pressed <= loopTapFrames
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
      deck: deck, start: start, startBeat: startBeat, barFrames: barFrames, anchorCursor: cursor,
      pressed: now, fixedBars: bars.map { min(max($0, 1), 64) })
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
    if t.tapped, let n = t.fixedBars { return findFixedEnd(t, deck: d, bars: n) }
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

  /// A tapped take's end: `n` bars on from its first downbeat. A net deck waits for that
  /// downbeat's anchor; a sample deck (or a net deck that stopped) counts bars at the pressed
  /// tempo.
  private func findFixedEnd(_ t: LoopTake, deck d: Deck, bars n: Int) {
    if d.mode == .net, d.playing {
      let target = t.startBeat + Double(4 * n)
      if let down = t.downs.first(where: { $0.beat > target - 0.5 }) {
        t.end = down.frame
        t.bars = n
      }
      return  // that downbeat has not been played yet
    }
    t.bars = n
    t.end = t.start + Int((Double(n) * t.barFrames).rounded())
  }

  private func finish(_ t: LoopTake, from d: Deck) {
    guard let end = t.end else { return }
    let n = end - t.start
    guard n > 0, t.left.count >= n, t.right.count >= n else { return }
    addTake(
      deck: t.deck, bars: t.bars, startBeat: t.startBeat, left: Array(t.left[0..<n]),
      right: Array(t.right[0..<n]), provenance: t.provenance, sample: t.sample)
  }

  /// A finished take's audio onto the row, looping under the mixer at once, in phase (it ends
  /// on a downbeat that has just gone by). Returns its id.
  @discardableResult
  private func addTake(
    deck: String, bars: Int, startBeat: Double, left: [Float], right: [Float],
    provenance: JSONObject, sample: SampleBuffer?
  ) -> String {
    let buffer = SampleBuffer(left: left, right: right, sampleRate: sampleRate)
    let id = buffer.contentID
    let bpm = Double(bars) * 4 * 60 * sampleRate / Double(buffer.length)
    loopCount += 1
    let clip = LoopClip(
      id: id, title: "\(deck) loop \(loopCount)", source: deck, bars: bars, bpm: bpm,
      startBeat: startBeat, buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 400),
      provenance: LoopProvenance.finish(provenance, bars: bars, bpm: bpm, sample: sample))
    sampleLibrary[id] = buffer
    if self.clip(id) == nil { clips.append(clip) }
    startLoop(id, atOnce: true)
    return id
  }

  // MARK: grabbing what was played

  /// Take the last `bars` whole bars `deck` has already played, out of its capture history:
  /// from `bars` bars before the latest downbeat at or before the render head, to that downbeat.
  /// A net deck's downbeats are its tick anchors; a sample deck's come from its beat grid. The
  /// clip lands on the row and loops at once, like a fresh take; its provenance says
  /// `"grabbed": true`. Refused (nil) on a deck that is not playing or has no beat clock, or
  /// when the history does not reach back that far (`CaptureTap.defaultCapacity`, ~21 s).
  @discardableResult
  public func grabLastBars(_ deck: String, bars: Int) -> String? {
    guard bars > 0, let d = decks[deck], d.playing, let s = d.beatState, s.bpm > 0,
      let oldest = d.capture.startFrame, let captured = d.capture.endFrame
    else { return nil }
    let now = min(d.renderedFrames, captured)
    let barFrames = 4 * 60 / s.bpm * sampleRate
    var end = d.renderedFrames - Int((s.barPhase * barFrames).rounded())
    var endBeat = Double(s.bar * 4)
    var start = end - Int((Double(bars) * barFrames).rounded())
    if d.mode == .net {
      // the newest downbeat already played, and the one `bars` bars before it (exact frames)
      let ring = d.wave.anchors
      var cursor = max(0, ring.written - ring.capacity)
      let downs = Self.downbeats(ring, from: &cursor).filter { $0.frame <= now }
      guard let last = downs.last else { return nil }
      end = last.frame
      endBeat = last.beat
      let first = endBeat - Double(4 * bars)
      start =
        downs.last(where: { abs($0.beat - first) < 0.5 && $0.frame < last.frame })?.frame
        ?? end - Int((Double(bars) * barFrames).rounded())
    }
    guard start >= oldest, start < end, end <= captured else { return nil }
    var l: [Float] = []
    var r: [Float] = []
    l.reserveCapacity(end - start)
    r.reserveCapacity(end - start)
    guard d.capture.copy(from: start, to: end, left: &l, right: &r) == end else { return nil }
    let startBeat = endBeat - Double(4 * bars)
    var provenance = LoopProvenance.capture(
      d, startBeat: startBeat, build: BuildInfo.current.build)
    provenance["grabbed"] = .bool(true)
    return addTake(
      deck: deck, bars: bars, startBeat: startBeat, left: l, right: r, provenance: provenance,
      sample: d.mode == .sample && !d.isDemo ? d.loaded : nil)
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
  /// It is kept in `removedClips` with its place and how it sounded, so `restoreClip` can put it
  /// back as it was.
  public func removeClip(_ id: String) {
    guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
    stopLoop(id, now: true)
    let sound = ClipSound(
      muted: clipMutes.contains(id), soloed: clipSolos.contains(id), keyLock: clipKeyLocks[id])
    rememberRemovedClip(clips.remove(at: i), at: i, sound: sound)
    forgetClipSound(id)
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
      provenance: LoopProvenance.crop(c, from: from, to: to), color: c.color)
    replace(at: i, with: cropped)
    // sequences that used the original use the crop from now on (when they are next rendered)
    for k in clips.indices {
      clips[k].steps = clips[k].steps?.map {
        $0.clipID == id ? SequenceStep(clipID: cropped.id, repeats: $0.repeats) : $0
      }
    }
    return cropped.id
  }

  /// Put `new` where the clip at `i` is: its level and colour carry over, and if it was looping
  /// under the mixer the new one carries on in phase.
  private func replace(at i: Int, with new: LoopClip) {
    var new = new
    if new.color == nil { new.color = clips[i].color }
    let id = clips[i].id
    let wasLooping = loopState(id) == .on || loopState(id) == .starting
    stopLoop(id, now: true)
    sampleLibrary[new.id] = new.buffer
    if let g = clipGains[id] { clipGains[new.id] = g }
    replaceInScenes(id, with: new.id)
    carryClipSound(from: id, to: new.id)
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
    /// Comes in at the next launch boundary (`loopQuantum`).
    case starting
    case on
    /// Goes out at the next launch boundary.
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

  /// `at`: change it at that deck frame instead of at once (a scene launch, on its boundary).
  public func setClipGain(_ id: String, _ g: Double, at: Int? = nil) {
    let before = clipGain(id)
    clipGains[id] = g
    if let v = loopVoices.firstIndex(where: { $0.clipID == id }) {
      let level = Float(audibleClipGain(id))
      if let at {
        // remembered, so a mute or solo before then keeps the change on its frame
        loopVoices[v].gainUntil = (loopVoices[v].gainUntil?.gain ?? before, at)
        loopChannel.bank?.send(.gainAt(voice: v, level, frame: at))
      } else {
        loopVoices[v].gainUntil = nil
        loopChannel.bank?.send(.gain(voice: v, level))
      }
    }
  }

  /// Start or stop clip `id` looping under the mixer, on the next launch boundary (a bar unless
  /// `loopQuantum` says otherwise). Starting a clip that is on its way out keeps it in.
  public func setLooping(_ id: String, _ on: Bool) {
    if on { startLoop(id) } else { stopLoop(id, now: false) }
  }

  /// Every loop out, on the next launch boundary.
  public func stopAllLoops() {
    for id in loopingClips { stopLoop(id, now: false) }
  }

  /// `atOnce`: start now, in phase, instead of waiting for the next launch boundary (a fresh
  /// take, which ends on a downbeat that has just gone by). `at`: start at that deck frame (a
  /// scene, whose clips all switch on one boundary).
  func startLoop(_ id: String, atOnce: Bool = false, at frame: Int? = nil) {
    guard let clip = clip(id), let bank = loopChannel.bank else { return }
    if let v = loopVoices.firstIndex(where: { $0.clipID == id }) {
      guard loopVoices[v].stopFrame != nil else { return }  // already in
      loopVoices[v].stopFrame = nil
      loopVoices[v].boundary = nil
      // cancels the stop (or brings a fade-out back up)
      bank.send(.start(voice: v, frame: 0, fade: loopFadeFrames(bpm: loopVoices[v].targetBPM)))
      return
    }
    guard let v = loopVoices.firstIndex(where: { $0.clipID == nil }) else { return }
    let clock = loopClock(for: clip)
    let earliest = loopChannel.renderedFrames + Self.loopLead
    let at =
      frame.map { max($0, earliest) }
      ?? (atOnce ? earliest : clock.nextBoundary(after: earliest, every: loopQuantum))
    let beats = Double(clip.beats)
    var b = (clock.beat(at) - (clock.ref?.name == clip.source ? clip.startBeat : 0))
      .truncatingRemainder(dividingBy: beats)
    if b < 0 { b += beats }
    let target = clock.bpm ?? clip.bpm
    // key-locked at another tempo: a stretched copy made before, if there is one for it
    let audio = loopAudio(clip, at: target)
    let length = Double(audio.buffer.length)
    let ratio = target / audio.bpm
    let tt = bank.voices[v]
    tt.load(audio.buffer)
    tt.send(.loop(start: 0, end: length))
    tt.send(.pitch(ratio: ratio - 1))
    tt.send(.seek(sample: b * length / beats))
    tt.send(.start)
    bank.send(.gain(voice: v, Float(audibleClipGain(id))))
    bank.send(.start(voice: v, frame: at, fade: loopFadeFrames(bpm: target, short: atOnce)))
    loopVoices[v] = LoopVoice(
      clipID: id, ref: clock.ref?.name, ratio: ratio, bufferBPM: audio.bpm, targetBPM: target,
      startFrame: at, scheduledAt: loopChannel.renderedFrames, bufferLength: length,
      boundary: atOnce ? nil : clock.waitingBoundary(every: loopQuantum))
  }

  /// `at`: stop at that deck frame (a scene launch) instead of the next launch boundary.
  func stopLoop(_ id: String, now: Bool, at frame: Int? = nil) {
    guard let bank = loopChannel.bank, let v = loopVoices.firstIndex(where: { $0.clipID == id })
    else { return }
    if !bank.isActive(v) && loopVoices[v].stopFrame == nil {
      // not in yet: never let it start
      bank.send(.stop(voice: v, frame: 0, fade: 0))
      loopVoices[v].stopFrame = 0
      return
    }
    let earliest = loopChannel.renderedFrames + (now ? 0 : Self.loopLead)
    let clock = loopClock(for: clip(id))
    let at =
      now
      ? earliest
      : frame.map { max($0, earliest) }
        ?? clock.nextBoundary(after: earliest, every: loopQuantum)
    let fade = loopFadeFrames(bpm: loopVoices[v].targetBPM, short: now)
    bank.send(.stop(voice: v, frame: at, fade: fade))
    loopVoices[v].stopFrame = at
    loopVoices[v].scheduledAt = loopChannel.renderedFrames
    loopVoices[v].boundary = now ? nil : clock.waitingBoundary(every: loopQuantum)
  }

  /// Housekeeping (from `serviceLoopTakes`): free voices whose loop is out, keep each loop at its
  /// reference deck's tempo, and key-locked ones at their pitch (`serviceKeyLock`).
  func serviceLoops() {
    guard let bank = loopChannel.bank else { return }
    let now = loopChannel.renderedFrames
    let louder = loopFollow == .louder ? updateDominantDeck() : nil
    for v in loopVoices.indices {
      guard let id = loopVoices[v].clipID else { continue }
      if let stop = loopVoices[v].stopFrame {
        if now >= stop && !bank.isActive(v) {
          loopVoices[v] = LoopVoice()
        } else {
          retimeWaiting(v, bank, now: now)
        }
        continue
      }
      retimeWaiting(v, bank, now: now)
      // moved back from a deck: the deck hands over when the loop comes in, on the downbeat
      if bank.isActive(v) {
        for d in decks.values where d.clipID == id && d.playing { d.setPlaying(false) }
      }
      guard let clip = clip(id) else { continue }
      // following the louder deck, a playing loop takes its tempo from whichever that is now;
      // following its own deck, back to that one when it plays
      if let louder, louder.clipID != id, bank.isActive(v) {
        loopVoices[v].ref = louder.name
      } else if loopFollow == .source, let own = decks[clip.source], own.playing, own.clipID != id,
        bank.isActive(v)
      {
        loopVoices[v].ref = own.name
      }
      if let ref = loopVoices[v].ref.flatMap({ decks[$0] }), ref.playing,
        let bpm = ref.effectiveBPM
      {
        loopVoices[v].targetBPM = bpm
      }
      serviceKeyLock(v, clip, now: now)
      let ratio = loopVoices[v].targetBPM / loopVoices[v].bufferBPM
      if abs(ratio - loopVoices[v].ratio) > 1e-6 {
        loopVoices[v].ratio = ratio
        bank.voices[v].send(.pitch(ratio: ratio - 1))
      }
    }
  }

  /// How far ahead of the render head a start or stop is scheduled at the least (the command
  /// must reach the audio thread first): ~43 ms at 48 kHz.
  static let loopLead = 2048

  /// A start or stop still waiting for its boundary follows the reference deck to it. The frame
  /// was worked out from the deck's tempo and phase when it was scheduled; a tempo fader, a
  /// nudge or SYNC during a long countdown (2, 4 or 8 bars) moves that deck's boundary, and the
  /// loop would come in (or go out) off it. So once the deck's tempo is not the one the frame
  /// was worked out at (`LoopVoice.boundary`), each pass moves the frame to the deck's launch
  /// line nearest it, and a waiting start is seeked to the clip's phase there. Only while both
  /// frames are well ahead of the render head (the audio thread cannot have reached either),
  /// only while the same deck is still the clip's clock, and only by less than a quarter of the
  /// line spacing: a tempo change moves the line that little, while a looping sample, whose beat
  /// count starts again on every pass, would otherwise seem to put its lines anywhere.
  private func retimeWaiting(_ v: Int, _ bank: LoopBank, now: Int) {
    let voice = loopVoices[v]
    guard let boundary = voice.boundary, let id = voice.clipID, let clip = clip(id) else {
      return
    }
    let clock = loopClock(for: clip)
    guard clock.ref?.name == boundary.ref, let bpm = clock.bpm, clock.framesPerBeat > 0 else {
      return
    }
    guard boundary.follow || abs(bpm - boundary.bpm) > 1e-9 else { return }
    loopVoices[v].boundary?.follow = true
    let safe = now + 2 * Self.loopLead
    let reach = Double(boundary.beats) / 4 * clock.framesPerBeat
    func moved(_ old: Int, _ new: Int) -> Bool {
      let d = abs(new - old)
      return old > safe && d > Self.retimeTolerance && Double(d) < reach
    }
    if let stop = voice.stopFrame {
      let at = max(clock.nearestBoundary(to: stop, every: boundary.beats), now + Self.loopLead)
      guard bank.isActive(v), moved(stop, at) else { return }
      bank.send(.stop(voice: v, frame: at, fade: loopFadeFrames(bpm: voice.targetBPM)))
      loopVoices[v].stopFrame = at
      return
    }
    guard !bank.isActive(v), let start = voice.startFrame, voice.bufferLength > 0 else { return }
    let at = max(clock.nearestBoundary(to: start, every: boundary.beats), now + Self.loopLead)
    guard moved(start, at) else { return }
    let beats = Double(clip.beats)
    var b = (clock.beat(at) - (boundary.ref == clip.source ? clip.startBeat : 0))
      .truncatingRemainder(dividingBy: beats)
    if b < 0 { b += beats }
    bank.voices[v].send(.seek(sample: b * voice.bufferLength / beats))
    bank.send(.start(voice: v, frame: at, fade: loopFadeFrames(bpm: voice.targetBPM)))
    loopVoices[v].startFrame = at
  }

  /// How far (frames) a waiting boundary may drift before it is moved: ~1.3 ms, above a sample
  /// deck's beat estimate's jitter.
  static let retimeTolerance = 64

  /// What a loop lines up with: the deck it was taken from if that plays, else another playing
  /// deck, else a loop already going under the mixer, else nothing (it starts on its own).
  func loopClock(for clip: LoopClip?) -> LoopClock {
    let sr = sampleRate
    // following the louder deck, that one first; else the clip's own deck first
    let first = loopFollow == .louder ? updateDominantDeck() : clip.flatMap { decks[$0.source] }
    let candidates =
      ([first, clip.flatMap { decks[$0.source] }] + decks.values.sorted { $0.name < $1.name })
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
      // What the voice holds may be a stretched copy: the beat from its own length (published
      // with its playhead, so the two always belong to the same audio). The tempo is the one it
      // plays at, `targetBPM`, as the main thread set it: not the loaded audio's tempo × the
      // turntable's rate, which mixes the new copy's tempo with the old rate for the block a
      // swap takes to land (`swapVoice`).
      let tt = bank.voices[v]
      let length = Double(tt.length > 0 ? tt.length : other.buffer.length)
      let samplesPerBeat = length / Double(other.beats)
      var pos = tt.position.truncatingRemainder(dividingBy: length)
      if pos < 0 { pos += length }
      let bpm = loopVoices[v].targetBPM
      return LoopClock(
        ref: nil, origin: (loopChannel.renderedFrames, pos / samplesPerBeat),
        framesPerBeat: 60 / bpm * sr, bpm: bpm)
    }
    return LoopClock(
      ref: nil, origin: (loopChannel.renderedFrames, 0), framesPerBeat: 0, bpm: nil)
  }
}

/// A beat clock for lining loops up: the beat at any deck frame, and the next downbeat (or
/// launch boundary).
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
  func nextDownbeat(after frame: Int) -> Int { nextBoundary(after: frame, every: 4) }

  /// The launch line (a beat that is a multiple of `beats`) nearest `frame`, before or after it.
  func nearestBoundary(to frame: Int, every beats: Int) -> Int {
    guard framesPerBeat > 0 else { return frame }
    let q = Double(max(1, beats))
    var back = beat(frame).truncatingRemainder(dividingBy: q)
    if back < 0 { back += q }
    let ahead = q - back
    return ahead <= back
      ? frame + Int((ahead * framesPerBeat).rounded(.up))
      : frame - Int((back * framesPerBeat).rounded(.down))
  }

  /// What a start or stop scheduled now on a `beats` line of this clock waits for
  /// (`LoopVoice.boundary`); nil without a reference deck.
  func waitingBoundary(every beats: Int) -> (beats: Int, ref: String, bpm: Double, follow: Bool)? {
    guard let ref, let bpm else { return nil }
    return (beats, ref.name, bpm, false)
  }

  /// The first beat at or after `frame` that is a multiple of `beats`, counted in the
  /// reference's own numbering (beat 0 is its bar 1), so 4-bar phrases (16) land on bars 1, 5,
  /// 9… of the deck, not 4 bars from whenever the button was pressed.
  func nextBoundary(after frame: Int, every beats: Int) -> Int {
    guard framesPerBeat > 0 else { return frame }
    let q = Double(max(1, beats))
    let b = beat(frame)
    var toGo = (q - b.truncatingRemainder(dividingBy: q)).truncatingRemainder(dividingBy: q)
    if toGo < 0 { toGo += q }
    return frame + Int((toGo * framesPerBeat).rounded(.up))
  }
}

/// One voice of the loop bank, as the main thread sees it.
struct LoopVoice {
  var clipID: String?
  /// The deck whose tempo it follows.
  var ref: String?
  /// Its turntable's speed: `targetBPM / bufferBPM`.
  var ratio = 1.0
  /// The tempo the loaded audio plays at at speed 1: the clip's own, or a stretched copy's.
  var bufferBPM = 120.0
  /// The tempo it is to play at: its reference deck's, else the one it started at.
  var targetBPM = 120.0
  /// Set once it is told to stop (it goes out at this frame).
  var stopFrame: Int?
  /// The frame it was told to come in at.
  var startFrame: Int?
  /// When its pending start or stop was scheduled (the countdown's full length).
  var scheduledAt: Int?
  /// A level change waiting for a frame (a scene's, on its boundary): the clip's level until
  /// then (`clipGains` already holds the new one) and the frame.
  var gainUntil: (gain: Double, frame: Int)?
  /// Samples in the audio it was started with (a stretched copy's, perhaps).
  var bufferLength = 0.0
  /// The boundary its pending start or stop waits for: a line every `beats` beats of reference
  /// deck `ref`, worked out at that deck's tempo `bpm`; `follow` once that tempo has changed
  /// (`retimeWaiting` then keeps it on the deck's line); nil for one not on a deck's boundary.
  var boundary: (beats: Int, ref: String, bpm: Double, follow: Bool)?
  /// Key lock: the tempo a stretch is wanted for and the frame it was first wanted at (it is
  /// rendered once that has held for `DJEngine.stretchDebounce`), and the render in flight.
  var stretchWant: (bpm: Double, since: Int)?
  var stretching: Int?
}

extension Deck {
  /// Load a clip as a looping sample with its grid, its tempo matched to `ref` and its playhead
  /// at the point of the loop that lines up with `ref`'s bar.
  func loadClip(_ clip: LoopClip, against ref: Deck?) {
    load(clip.buffer, title: clip.title, level: false)
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
