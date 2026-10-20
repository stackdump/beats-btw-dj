import Foundation

// Rewinding a running engine: stand it where a checkpoint (`JournalState`) says, in place,
// without building a new engine. Everything after the target goes — the row's clips, scenes and
// removed list, the decks' sources, follows, voice tweaks and knobs, the locks, the mixer, the
// row's settings — and then the state is restored as into a fresh engine (`restore(into:)`).
//
// Main-thread work, like every other control path: buffers and projects leave the audio thread
// the way any load retires them (the turntables' and the wave sources' retire rings, drained on
// the main thread), so the render thread frees and allocates nothing for it.

extension DJEngine {
  /// Reset this engine to `state`, as `state.restore(into:clip:)` stands a fresh one there.
  /// `clip` finds a clip's audio by id (the loop library); a clip it can't find is left out and
  /// named in the returned warnings. Nothing is recorded: a reset is not an input.
  ///
  /// Live (not `deterministic`), compiles and jumps already on their way are let through first
  /// and then superseded (each deck's `generation` moves on, so whatever they finish lands
  /// nowhere), and a net deck's `position` is awaited as a jump (`jumpToTick`) before the decks
  /// start. In `deterministic` mode it all happens inline.
  @MainActor @discardableResult
  public func reset(to state: JournalState, clip: (String) -> LoopClip?) async -> [String] {
    if !deterministic { await Task.yield() }  // pending main-actor loads start, to be superseded
    restoreAutoMix(AutoMixState())  // a hand-off in flight lets go of its decks first
    clearLoopRow()
    clearScenes()
    for d in decks.values.sorted(by: { $0.name < $1.name }) { resetDeck(d) }
    lockedActions = []
    owners = [:]
    crossfader = 0.5
    master = 0.8
    loopChannel.mute = false
    resetLoopSettings()
    let staged = state.restore(into: self, clip: clip, deferNetSeeks: !deterministic)
    for s in staged.netSeeks { await s.deck.jumpToTick(s.tick) }
    staged.play()
    return staged.warnings
  }

  /// A deck as a fresh engine has it: stopped, empty, following no one, no voice tweaks,
  /// disabled roles or next track, default knobs; anything still composing for it superseded.
  func resetDeck(_ d: Deck) {
    d.generation += 1
    d.cancelNext()
    d.awaitingNext = false
    d.startingNext = false
    d.follow(nil)
    d.eject()
    d.wave.clearVoiceSettings()
    for r in d.disabledRoles.sorted() { d.setRoleDisabled(r, false) }
    d.apply(DeckParams())
    d.setWander(false)
  }
}
