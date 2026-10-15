import Foundation

/// Cue / loop snapping on a sample deck with a beat grid.
public enum Quantize: Sendable, Equatable {
  case off, beat, bar
}

/// Where a deck is on its beat grid.
public struct BeatState: Equatable, Sendable {
  /// The tempo the deck is running at now (BPM × tempo fader × nudge).
  public var bpm: Double
  /// Position in beats from the grid origin (beat 0 = the downbeat of bar 0).
  public var beat: Double

  public var beatPhase: Double { beat - beat.rounded(.down) }
  public var barPhase: Double { (beat / 4) - (beat / 4).rounded(.down) }
  /// 0…3: the beat within the bar.
  public var beatInBar: Int { Int((barPhase * 4).rounded(.down)) }
  public var bar: Int { Int((beat / 4).rounded(.down)) }
}

public enum SyncAlign: Sendable {
  case tempoOnly, beat, bar
}

public struct SyncResult: Equatable, Sendable {
  /// The tempo-fader position that was set (−1…1).
  public var pitch: Double
  /// 1, or 0.5 / 2 when half or double time of the other deck fits the fader range better.
  public var multiplier: Double
  /// The match needed more than the fader's range and was clamped.
  public var tempoClamped: Bool
  /// How far this deck was moved to line up, in its own beats (negative = held back).
  public var shiftedBeats: Double
}

extension Deck {
  // MARK: beat state

  /// The tempo before the fader.
  public var baseBPM: Double? {
    switch mode {
    case .net: netProject == nil ? nil : netBaseBPM
    case .sample: beatGrid?.bpm
    }
  }

  /// The tempo the deck is set to run at: base × tempo fader × nudge.
  public var effectiveBPM: Double? {
    baseBPM.map { $0 * (1 + pitch * Self.pitchRange) * (1 + netNudge) }
  }

  public var beatState: BeatState? {
    guard let bpm = effectiveBPM else { return nil }
    switch mode {
    case .net:
      let t = wave.tick
      let ticks = t == 0 ? 0 : Double(t - 1) + wave.tickPhase
      return BeatState(bpm: bpm, beat: ticks / 4)
    case .sample:
      guard let g = beatGrid, turntable.length > 0 else { return nil }
      let len = Double(turntable.length)
      var p = turntable.position.truncatingRemainder(dividingBy: len)
      if p < 0 { p += len }
      return BeatState(
        bpm: bpm, beat: (p - g.offset) / g.samplesPerBeat(sampleRate: turntable.sampleRate))
    }
  }

  // MARK: waveform

  /// Peaks for the strip display, off the main thread (inline in deterministic mode).
  func computeWaveform(_ buffer: SampleBuffer) {
    waveformToken += 1
    let token = waveformToken
    if deterministic {
      waveform = WaveformOverview(buffer: buffer, columns: 1200)
      return
    }
    Task.detached(priority: .utility) { [self] in
      let w = WaveformOverview(buffer: buffer, columns: 1200)
      await MainActor.run {
        if token == waveformToken, loaded === buffer { waveform = w }
      }
    }
  }

  // MARK: analysis, tapping

  /// Measure the tempo off the main thread; the result lands if the deck still holds
  /// this buffer.
  func analyze(_ buffer: SampleBuffer) {
    analysisToken += 1
    let token = analysisToken
    Task.detached(priority: .utility) { [self] in
      let grid = BPMAnalyzer.analyze(buffer)
      await MainActor.run {
        guard token == analysisToken, loaded === buffer, let grid else { return }
        beatGrid = grid
        onGrid?(grid)
      }
    }
  }

  /// Put a grid in place directly (a session replay, or a stored analysis).
  func setBeatGrid(_ grid: BeatGrid) {
    guard mode == .sample else { return }
    analysisToken += 1  // an analysis still running must not overwrite it
    beatGrid = grid
  }

  /// Declare the tempo by hand (or after a tap). Keeps the current grid offset.
  public func setBPM(_ bpm: Double) {
    guard mode == .sample, bpm > 0 else { return }
    beatGrid = BeatGrid(bpm: bpm, offset: beatGrid?.offset ?? 0, confidence: 1)
    onGrid?(beatGrid!)
  }

  /// Declare that the playhead is on a downbeat: the grid origin moves here.
  public func setDownbeatHere() {
    guard mode == .sample, let g = beatGrid, turntable.length > 0 else { return }
    let spb = g.samplesPerBeat(sampleRate: turntable.sampleRate)
    var p = turntable.position.truncatingRemainder(dividingBy: Double(turntable.length))
    if p < 0 { p += Double(turntable.length) }
    beatGrid = BeatGrid(bpm: g.bpm, offset: p.truncatingRemainder(dividingBy: spb), confidence: 1)
    onGrid?(beatGrid!)
  }

  // MARK: sync

  /// The tempo rule `sync` and `follow` share: the same tempo, or half / double time if that
  /// fits the fader better. `ratio` (effective / base BPM) is clamped to the pitch range.
  public static func tempoMatch(base: Double, target: Double)
    -> (mult: Double, ratio: Double, clamped: Bool)
  {
    var choice = (mult: 1.0, ratio: target / base)
    for m in [0.5, 2.0] {
      let r = target * m / base
      if abs(r - 1) < abs(choice.ratio - 1) { choice = (m, r) }
    }
    let range = pitchRange
    return (
      choice.mult, min(1 + range, max(1 - range, choice.ratio)), abs(choice.ratio - 1) > range
    )
  }

  /// Match tempo (and optionally beat or bar phase) to `other`.
  @discardableResult
  public func sync(to other: Deck, align: SyncAlign = .beat) -> SyncResult? {
    guard let base = baseBPM, let target = other.effectiveBPM, other.beatState != nil else {
      return nil
    }
    let choice = Self.tempoMatch(base: base, target: target)
    pitch = (choice.ratio - 1) / Self.pitchRange
    netNudge = 0
    applyNetTempo()

    var shifted = 0.0
    if align != .tempoOnly, let me = beatState, let you = other.beatState {
      // Positions in the other deck's beats: with multiplier m this deck's beat is m of theirs.
      let mine = me.beat * choice.mult
      var err = mine - you.beat
      let period = align == .bar ? 4.0 : 1.0
      err = err - (err / period).rounded() * period  // wrap to [-period/2, period/2]
      shifted = -err / choice.mult  // in this deck's beats
      move(beats: shifted)
    }
    return SyncResult(
      pitch: pitch, multiplier: choice.mult, tempoClamped: choice.clamped, shiftedBeats: shifted)
  }

  /// Move the playhead along the beat grid (positive = forward in the music).
  func move(beats: Double) {
    guard beats != 0 else { return }
    switch mode {
    case .net: wave.align(ticks: beats * 4)
    case .sample:
      guard let g = beatGrid else { return }
      let spb = g.samplesPerBeat(sampleRate: turntable.sampleRate)
      turntable.send(.seek(sample: turntable.position + beats * spb))
    }
  }

  /// Keep this deck's tempo locked to `leader`'s (tempo only: phase stays where it is).
  /// `follow(nil)` lets go.
  public func follow(_ leader: Deck?) {
    self.leader = leader
    if let leader { sync(to: leader, align: .tempoOnly) }
  }

  /// Back to the start of the sample, or tick 0 of the net.
  public func rewind() {
    switch mode {
    case .sample: turntable.send(.seek(sample: 0))
    case .net: relocate(toTick: 0)
    }
  }

  // MARK: quantize

  /// Snap a sample position to the grid.
  public func snapped(_ position: Double) -> Double {
    guard quantize != .off, let g = beatGrid else { return position }
    let spb = g.samplesPerBeat(sampleRate: turntable.sampleRate)
    let unit = quantize == .bar ? spb * 4 : spb
    return g.offset + ((position - g.offset) / unit).rounded() * unit
  }

  /// Loop `beats` beats long, starting on the nearest beat (or bar if quantizing to bars).
  public func loopBeats(_ beats: Double) {
    guard mode == .sample, let g = beatGrid, loaded != nil else { return }
    let spb = g.samplesPerBeat(sampleRate: turntable.sampleRate)
    let unit = quantize == .bar ? spb * 4 : spb
    let start = g.offset + ((turntable.position - g.offset) / unit).rounded(.down) * unit
    setLoop(start, start + beats * spb)
  }
}
