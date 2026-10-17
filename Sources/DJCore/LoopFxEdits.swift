// A clip's after effects as the main thread sees them: a value on the clip (`LoopClip.fx`), set
// by the poke `DeckAction.clipFx` (journaled through `perform` like every clip edit), sent to
// the voice playing it as `LoopBankCommand.fx` (the clip-gain path), saved in the loop library
// with the clip and in the journal's checkpoint.
//
// Where FX go when a clip becomes another:
// - a crop keeps its clip's FX (it is the same loop, shorter);
// - a sequence is rendered from its steps' dry audio, back to back, so its steps' FX are not in
//   it (they would have to be baked in, which is the destructive edit this avoids): a new
//   sequence starts with its own FX off, and an edited one keeps the FX it had;
// - a clip moved onto deck A or B plays there dry (FX are the loop row's); back under the mixer
//   it has them again;
// - scenes recall levels and which clips play, not FX: FX are the clip's, like its colour.

extension DJEngine {
  /// Clip `id`'s FX (on the row or removed); off for an unknown clip.
  public func clipFx(_ id: String) -> LoopFX {
    clip(id)?.fx ?? removedClips.first { $0.clip.id == id }?.clip.fx ?? LoopFX()
  }

  /// Set clip `id`'s FX (clamped into range). A voice playing it changes over smoothly.
  public func setClipFx(_ id: String, _ fx: LoopFX) {
    let f = fx.clamped
    editClip(id) { $0.fx = f }
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id }) else { return }
    loopChannel.bank?.send(.fx(voice: v, LoopFxParams(f, sampleRate: sampleRate)))
  }
}
