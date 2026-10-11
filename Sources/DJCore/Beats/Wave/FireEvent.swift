/// What the wave engine tells the scopes, from the audio thread, through lock-free rings.
///
/// Both records are plain values (`BitwiseCopyable`), stamped in the deck's **frame time
/// base**: `Deck.renderedFrames`, the count of frames the deck's source node has rendered.
/// A record stamped `frame` is exactly where in the deck's output the tick began sounding:
/// the start-of-block frame plus the sample offset of the tick inside the block. Audio
/// seconds = frame / sampleRate.
///
/// The two streams live in `LatestRing`s (`WaveDeckSource.fires` / `.anchors`): the audio
/// thread only ever writes, and any number of readers follow them, each with its own cursor
/// (`WaveDeckSource.readEvents`). A reader that falls a whole ring behind loses the oldest
/// records and is told how many. Read the fires *before* the anchors: the audio thread writes
/// a tick's anchor before that tick's fires, so every fire a reader has seen has its anchor
/// already in the anchor ring (`readEvents` does it in that order).
public struct FireFlags: OptionSet, BitwiseCopyable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  /// The hit landed on a drum lane (a gate: kick, snare, hat, clap...), not a tonal one.
  public static let drum = FireFlags(rawValue: 1 << 0)
  /// The net is a stinger (`hit1`, `hit2`...), one-bar accents the performer fires.
  public static let stinger = FireFlags(rawValue: 1 << 1)
  /// A macro (a mute timer, beat repeat, or a tempo effect) was in effect when it fired.
  public static let macro = FireFlags(rawValue: 1 << 2)
}

/// One audible hit of a transition: the event stream is what the engine actually plays, the
/// same rule as `onFire` in beats' JS. Muted nets and muted notes, control nets, and
/// transitions with no voice produce no event; neither do silent replays (a section launch
/// or `fastForward` rebuilding the marking, `align`, a scrub), because those do not run
/// through the tick clock.
public struct FireEvent: BitwiseCopyable, Sendable {
  /// Deck frame at which this tick's audio begins (the sample the gates were struck on).
  public var frame: Int64
  /// The graph's tick counter *after* the step that fired this: the first tick of a song is 1.
  /// `WaveDeckSource.tick`, read after the block, is >= this.
  public var tick: Int32
  /// Which project this came from (`WaveProject.generation`). `net` and `transition` index
  /// into that project; after a swap at a bar boundary they mean something else.
  public var generation: Int32
  /// Index into `WaveGraph.nets` (project order) of the net that fired.
  public var net: Int32
  /// Index into that net's `transIds`.
  public var transition: Int32
  /// MIDI note number of the binding.
  public var note: Int16
  /// MIDI velocity 0...127 as bound (not scaled).
  public var velocity: UInt8
  /// MIDI channel 1...16 (the binding's, else the track's); 10...15 are drums.
  public var channel: UInt8
  /// Length in sixteenth steps (0: the binding only has a duration in ms).
  public var durSteps: Float
  /// Length in ms the way the tonal voice hears it: `durSteps` at the tempo of this tick, else
  /// the binding's legacy duration. Drums ignore it but it is filled in all the same.
  public var durMs: Float
  public var flags: FireFlags

  public init(
    frame: Int64, tick: Int32, generation: Int32, net: Int32, transition: Int32, note: Int16,
    velocity: UInt8, channel: UInt8, durSteps: Float, durMs: Float, flags: FireFlags
  ) {
    self.frame = frame
    self.tick = tick
    self.generation = generation
    self.net = net
    self.transition = transition
    self.note = note
    self.velocity = velocity
    self.channel = channel
    self.durSteps = durSteps
    self.durMs = durMs
    self.flags = flags
  }
}

public struct TickAnchorFlags: OptionSet, BitwiseCopyable, Sendable {
  public let rawValue: UInt16
  public init(rawValue: UInt16) { self.rawValue = rawValue }

  /// Not a step: the clock tick at which a queued project took over (at a bar boundary).
  /// `tick` is the new project's counter (which has restarted, or starts where a section
  /// launch seeded it) and `generation` changes here. Time stays regular across it: the swap
  /// uses up one tick of the clock. A project installed on a *stopped* deck gets no such
  /// anchor; the generation just changes at the next anchor, which `.discontinuity` flags.
  public static let swap = TickAnchorFlags(rawValue: 1 << 0)

  /// This anchor does not continue the previous one: the net clock was started, paused and
  /// resumed, stopped, realigned (`align`) or scratched since, or this is the first anchor
  /// ever. Its `(frame, tick)` pair is true, but neither the step numbers nor the spacing in
  /// frames follow on from the anchor before it, so a time axis must not interpolate across
  /// it. Hits made while scratching (`freeze` ... `release`) are not reported, and neither are
  /// the ticks they move over: after `release` the tick has jumped, and says so here.
  public static let discontinuity = TickAnchorFlags(rawValue: 1 << 1)
}

/// One tick of the net clock: exactly when each tick began in the deck's frame time base,
/// including ticks that fire nothing audible and ticks that change the tempo. Joining
/// consecutive anchors gives the step <-> time mapping a time axis needs, with no estimating
/// from the tempo: within a generation, and between anchors that carry neither `.swap` nor
/// `.discontinuity`, ticks are consecutive and frames are spaced floor/ceil(sr * 60 / (tempo * 4)).
public struct TickAnchor: BitwiseCopyable, Sendable {
  /// Deck frame at which this tick begins.
  public var frame: Int64
  /// The graph's tick counter after this tick (same meaning as `FireEvent.tick`).
  public var tick: Int32
  public var generation: Int32
  /// The net clock's tempo in BPM during this tick (after the pitch fader and any tempo macro).
  public var tempo: Float
  public var flags: TickAnchorFlags

  public init(
    frame: Int64, tick: Int32, generation: Int32, tempo: Float, flags: TickAnchorFlags
  ) {
    self.frame = frame
    self.tick = tick
    self.generation = generation
    self.tempo = tempo
    self.flags = flags
  }
}
