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

/// A finished take: whole bars of one deck, on the row under the mixer.
public struct LoopClip: Sendable, Identifiable, Equatable {
  /// Content id of the audio (`SampleBuffer.contentID`); also its key in `sampleLibrary`.
  public let id: String
  public let title: String
  /// The deck it was taken from.
  public let source: String
  public let bars: Int
  /// The tempo the bars were played at (the deck's, after its tempo fader).
  public let bpm: Double
  /// The source deck's beat at the clip's first sample: a downbeat (a multiple of 4).
  public let startBeat: Double
  public let buffer: SampleBuffer
  public let waveform: WaveformOverview

  public var grid: BeatGrid { BeatGrid(bpm: bpm, offset: 0, confidence: 1) }

  public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
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
    loopTakes[deck] = LoopTake(
      deck: deck, start: start, startBeat: startBeat, barFrames: barFrames, anchorCursor: cursor)
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
      waveform: WaveformOverview(buffer: buffer, columns: 400))
    sampleLibrary[id] = buffer
    clips.append(clip)
    playClip(id, on: loopChannel.name)
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
    clips.removeAll { $0.id == id }
    for d in [loopChannel] + decks.values where d.clipID == id { d.setPlaying(false) }
  }

  /// Put clip `id` on `deck` ("L", "A", "B"), looping its whole length, in time with the deck
  /// it is played against: on the loop channel the deck it was taken from, on A or B the other
  /// one. It is moved, not copied: any other deck playing it stops. On the loop channel it
  /// plays at once; on A or B it keeps that deck's transport.
  public func playClip(_ id: String, on deck: String) {
    guard let clip = clip(id), let target = self[deck] else { return }
    for d in [loopChannel] + decks.values where d !== target && d.clipID == id && d.playing {
      d.setPlaying(false)
    }
    let isLoop = target === loopChannel
    let wasPlaying = target.playing
    let ref: Deck? = {
      func usable(_ d: Deck?) -> Deck? {
        guard let d, d !== target, d.playing, d.clipID != id, d.beatState != nil else { return nil }
        return d
      }
      if isLoop {
        return usable(decks[clip.source])
          ?? decks.values.sorted { $0.name < $1.name }.lazy.compactMap(usable).first
      }
      return decks.values.sorted { $0.name < $1.name }.lazy.compactMap(usable).first
    }()
    target.loadClip(clip, against: ref)
    if isLoop { target.follow(ref) }
    if isLoop || wasPlaying { target.launch() } else { target.setPlaying(false) }
  }
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
      let beats = Double(clip.bars * 4)
      var b = (r.beat - clip.startBeat).truncatingRemainder(dividingBy: beats)
      if b < 0 { b += beats }
      offset = b * length / beats
    } else {
      pitch = 0
    }
    if offset > 0 { turntable.send(.seek(sample: offset)) }
  }
}
