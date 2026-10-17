import Foundation

/// Whose tempo the loops under the mixer follow.
public enum LoopFollow: String, Sendable, CaseIterable {
  /// Each loop follows the deck it was taken from (else whichever deck plays).
  case source
  /// Every loop follows the louder of the playing decks: the one the room hears.
  case louder
}

extension DJEngine {
  /// How loud a deck's channel is in the master: its fader × trim × crossfader (0 when muted).
  /// The mixer's setting, not the audio's level, so it is steady and a replay gives the same.
  func channelLevel(_ d: Deck) -> Double {
    d.mute ? 0 : d.trim * d.volume * crossfadeGain(d.name)
  }

  /// The deck the loops follow under `.louder`: the louder playing deck with a tempo. It only
  /// changes hands when another deck is clearly louder (3 dB: a crossfade does not flap it
  /// back and forth across the middle), or when it stops or goes silent.
  @discardableResult
  func updateDominantDeck() -> Deck? {
    let playing = decks.values.sorted { $0.name < $1.name }
      .filter { $0.playing && $0.beatState != nil }
    guard let best = playing.max(by: { channelLevel($0) < channelLevel($1) }),
      channelLevel(best) > 0
    else {
      dominantDeck = nil
      return nil
    }
    if let current = dominantDeck.flatMap({ decks[$0] }),
      playing.contains(where: { $0 === current }),
      channelLevel(current) > 0, channelLevel(best) < channelLevel(current) * Self.dominanceMargin
    {
      return current
    }
    dominantDeck = best.name
    return best
  }

  /// How much louder another deck must be to take the loops over: 3 dB.
  static let dominanceMargin = pow(10, 3.0 / 20)

  /// Follow the louder deck, or each loop's own (recorded: `.loopFollow`).
  public func setLoopFollow(_ mode: LoopFollow) {
    loopFollow = mode
    if mode == .louder { updateDominantDeck() }
  }
}
