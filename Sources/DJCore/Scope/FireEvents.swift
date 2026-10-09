import Synchronization

/// One fired transition, as the scope views want it. Plain bits, so it travels through
/// an `SPSCRing` without retaining anything.
public struct FireEvent: BitwiseCopyable, Equatable, Sendable {
  /// Index into the project's `graph.nets` (resolve with `ScopeFeed.netId`).
  public var net: Int16
  public var transition: Int16
  /// MIDI note of the transition's binding, or -1 for a transition with none (a control
  /// or a plain place-to-place step).
  public var note: Int16
  public var velocity: UInt8
  public var flags: UInt8
  /// The net clock tick the transition fired on.
  public var tick: Int32
  /// Engine frame (the `AudioTap` timebase) of the sample the tick began on.
  public var frame: Int

  /// The binding sounds: its net and note were un-muted.
  public static let audibleFlag: UInt8 = 1
  /// The transition is a control (section jump, macro, stop, …).
  public static let controlFlag: UInt8 = 2

  public var isAudible: Bool { flags & Self.audibleFlag != 0 }
  public var isControl: Bool { flags & Self.controlFlag != 0 }

  public init(
    net: Int16, transition: Int16, note: Int16, velocity: UInt8, flags: UInt8, tick: Int32,
    frame: Int
  ) {
    self.net = net
    self.transition = transition
    self.note = note
    self.velocity = velocity
    self.flags = flags
    self.tick = tick
    self.frame = frame
  }
}

/// The audio-thread end of a deck's firing events. `WaveGraph.advance` pushes here as it
/// fires; the main thread drains `ring`. Overflow drops the new event and counts it.
///
/// `frameBase` and `frame` belong to the audio thread: the deck sets `frameBase` to its
/// tap position before rendering a block and the runner derives `frame` from it per tick.
public final class FireEventSink: @unchecked Sendable {
  public let ring: SPSCRing<FireEvent>
  private let droppedCount = Atomic<Int>(0)
  var frameBase = 0
  var frame = 0

  public init(capacity: Int = 4096) { ring = SPSCRing(capacity: capacity) }

  /// Events dropped because the ring was full (the main thread was not draining).
  public var dropped: Int { droppedCount.load(ordering: .relaxed) }

  /// Audio thread: where the next block starts on the tap's clock.
  public func beginBlock(frame: Int) { frameBase = frame }

  func push(_ e: FireEvent) {
    if !ring.push(e) { droppedCount.add(1, ordering: .relaxed) }
  }
}
