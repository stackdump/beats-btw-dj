// A clip's after effects as the main thread sees them: a value on the clip (`LoopClip.fx`), set
// by the poke `DeckAction.clipFx` (journaled through `perform` like every clip edit), sent to
// the voice playing it as `LoopBankCommand.fx` (the clip-gain path), saved in the loop library
// with the clip and in the journal's checkpoint.
//
// Where FX go when a clip becomes another:
// - a crop keeps its clip's FX (it is the same loop, shorter);
// - a sequence is rendered from its steps' dry audio, back to back, so its steps' FX are not in
//   it (they would have to be baked in, which is the destructive edit this avoids): a new
//   sequence whose steps all share the same active FX takes them (it sounds as they did), one
//   of mixed steps starts with its FX off, and an edited one keeps the FX it had;
// - a clip moved onto deck A or B keeps them: the deck has a chain of its own (`DeckRenderer`),
//   set at the load and changed with the clip's; anything else loaded there plays dry;
// - a scene saved with a clip's FX on sets them again on its launch boundary (`SceneClip.fx`,
//   `LoopBankCommand.fxAt` for a voice already sounding); one saved with them off, or saved
//   before scenes kept FX, leaves the clip's FX as they are.

extension DJEngine {
  /// Clip `id`'s FX (on the row or removed); off for an unknown clip.
  public func clipFx(_ id: String) -> LoopFX {
    clip(id)?.fx ?? removedClips.first { $0.clip.id == id }?.clip.fx ?? LoopFX()
  }

  /// Set clip `id`'s FX (clamped into range). A voice or a deck playing it changes over
  /// smoothly. `at`: the loop voice playing it changes at that deck frame instead of at once (a
  /// scene launch, on its boundary); a deck playing it still changes at once.
  public func setClipFx(_ id: String, _ fx: LoopFX, at: Int? = nil) {
    let f = fx.clamped
    editClip(id) { $0.fx = f }
    for d in decks.values where d.clipID == id { d.setClipFx(f) }
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id }) else { return }
    let p = LoopFxParams(f, sampleRate: sampleRate)
    if let at {
      loopChannel.bank?.send(.fxAt(voice: v, p, frame: at))
    } else {
      loopChannel.bank?.send(.fx(voice: v, p))
    }
  }
}
