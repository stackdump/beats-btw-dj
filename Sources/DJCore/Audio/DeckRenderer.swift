import AudioToolbox
import Synchronization

/// What a deck's `AVAudioSourceNode` block does, as an object the block can capture without
/// capturing the `Deck` (no retain cycle, nothing but plain references on the audio thread).
///
/// Per render call it renders whichever source is active, counts the frames, and, only while a
/// scope has subscribed, pushes the mono mixdown into the deck's `ScopeTap`.
///
/// Threading: `renderBlock` is the audio thread's. Everything else here is read-only or an
/// atomic read, from any thread.
final class DeckRenderer: @unchecked Sendable {
  let turntable: Turntable
  let wave: WaveDeckSource
  /// Pre-EQ, pre-fader mono mixdown of this deck, on the engine's frame time base.
  let tap = ScopeTap()
  private let renderedFramesAtomic = Atomic<Int>(0)

  init(turntable: Turntable, wave: WaveDeckSource) {
    self.turntable = turntable
    self.wave = wave
  }

  /// Frames this deck has rendered since it was made, counted on every render call in both
  /// source modes: the time base for tap samples, `FireEvent`s and tick anchors.
  ///
  /// Release/acquire: every tap sample and fire event stamped with a frame below the value
  /// you read is already in its ring.
  var renderedFrames: Int { renderedFramesAtomic.load(ordering: .acquiring) }

  /// Audio thread. The source node's block: renders into the buffer list the engine hands
  /// over. A list without a data pointer (not seen in practice) renders nothing, but its
  /// frames are still counted: the deck's time base has to stay in step with the engine's,
  /// because fire stamps and master-tap placement rely on it.
  func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    guard buffers.count > 0, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
      let start = renderedFramesAtomic.load(ordering: .relaxed)
      renderedFramesAtomic.store(start + frames, ordering: .releasing)
      return
    }
    let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
    renderBlock(frames: frames, left: l, right: r)
  }

  /// Audio thread. Renders `frames` samples of the active source into `left` (and `right`).
  func renderBlock(
    frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    let start = renderedFramesAtomic.load(ordering: .relaxed)  // only this thread writes it
    if wave.isActive {
      wave.render(frames: frames, left: left, right: right, startFrame: start)
    } else {
      turntable.render(frames: frames, left: left, right: right)
    }
    if tap.isEnabled {
      tap.push(left: left, right: right, frames: frames, startFrame: start)
    }
    renderedFramesAtomic.store(start + frames, ordering: .releasing)
  }
}
