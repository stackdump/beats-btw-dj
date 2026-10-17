// The loops' master FX ("Loops master FX", not a clip's "Loop FX"): the loop channel "L" as a third
// target for the master macros and sliders, beside the net decks A and B. The audio side is
// `LoopMasterBus` (Audio/LoopMasterBus.swift); this is where a fire gets its bar and its tempo.
//
// The pokes are the decks' own: `DeckAction.macro(deck: "L", id:)` and `.panic(deck: "L")` (so
// sessions, the journal, MCP and the socket need nothing new), the APC's faders and macro pads
// aimed at "L" (`DJEngine.focus`, recorded as MIDI), and `.loopFxLink(on:)` for the link.
//
// The boundary: a fire on "L" lands on the next launch line of the loops' clock (`loopClock`, the
// grid loops start and stop on: the launch quantum, at most a bar), at that clock's tempo, so a
// 1-bar sweep runs from one loop bar line to the next. With no clock (nothing playing) it lands at
// once, at 120 BPM. A linked fire (from a deck, `loopFxLink`) lands at once, with the deck's.
// Only master macros apply (FX, pitch, feel's filter): net macros need a net.

extension DJEngine {
  /// The loops' master bus (the loop channel's chain and macros).
  public var loopMaster: LoopMasterBus? { loopChannel.bank?.master }

  /// Beats a fire on the loops waits for: the launch quantum, at most a bar.
  var loopMasterQuantum: Int { min(max(1, loopQuantum), 4) }

  /// Fire master macro `m` on the loops for `bars` bars (nil: its default; 0: permanent), on the
  /// next launch line (`atOnce`: the next block), at the loop clock's tempo.
  func fireLoopMaster(_ m: MasterMacro, bars: Int?, atOnce: Bool = false) {
    guard let bus = loopMaster else { return }
    let clock = loopClock(for: nil)
    let frame =
      atOnce
      ? 0
      : clock.nextBoundary(
        after: loopChannel.renderedFrames + Self.loopLead, every: loopMasterQuantum)
    bus.fire(m, bars: bars, frame: frame, bpm: clock.bpm ?? 120)
  }

  /// A deck's master macro (nil: its panic), passed on to the loops while they are linked.
  func linkedLoopMaster(_ m: MasterMacro?, bars: Int?) {
    guard loopFxLink else { return }
    if let m { fireLoopMaster(m, bars: bars, atOnce: true) } else { loopMaster?.panic() }
  }

  /// Link the loops' master FX to the decks' (`loopFxLink`).
  public func setLoopFxLink(_ on: Bool) { loopFxLink = on }

  /// The loop-bus fire frame for a fire now (`fireLoopMaster`): for the UI's countdown and tests.
  public func loopMasterFireFrame() -> Int {
    loopClock(for: nil).nextBoundary(
      after: loopChannel.renderedFrames + Self.loopLead, every: loopMasterQuantum)
  }
}
