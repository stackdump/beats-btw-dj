import AudioToolbox
import Synchronization

/// What a deck's `AVAudioSourceNode` block does, as an object the block can capture without
/// capturing the `Deck` (no retain cycle, nothing but plain references on the audio thread).
///
/// Per render call it renders whichever source is active, counts the frames, and, only while a
/// scope has subscribed, pushes the mono mixdown into the deck's `ScopeTap` (and, only while the
/// stage's corona has subscribed, the LEFT channel alone into `leftTap`).
///
/// Threading: `renderBlock` is the audio thread's. Everything else here is read-only or an
/// atomic read, from any thread.
final class DeckRenderer: @unchecked Sendable {
  let turntable: Turntable
  let wave: WaveDeckSource
  /// The loop channel's clips (nil on every other deck): rendered instead of the turntable.
  let bank: LoopBank?
  /// Pre-EQ, pre-fader mono mixdown of this deck, on the engine's frame time base.
  let tap = ScopeTap()
  /// Pre-EQ, pre-fader LEFT channel of this deck, for the stage's corona (see
  /// `ScopeFeed.setLeftChannelWanted`). Off unless someone subscribed; a small ring, because the
  /// reader only ever wants the newest few hundred samples.
  let leftTap = ScopeTap(capacity: ScopeTap.leftCapacity)
  private let renderedFramesAtomic = Atomic<Int>(0)
  /// Pre-EQ, pre-fader loudness of this deck (`Deck.shortTermLUFS`), always on (cheap: two
  /// biquads a channel).
  let meter: LoudnessMeter

  init(turntable: Turntable, wave: WaveDeckSource, bank: LoopBank? = nil) {
    self.turntable = turntable
    self.wave = wave
    self.bank = bank
    meter = LoudnessMeter(sampleRate: turntable.sampleRate)
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
    if let bank {
      bank.render(frames: frames, left: left, right: right, startFrame: start)
    } else if wave.isActive {
      wave.render(frames: frames, left: left, right: right, startFrame: start)
    } else {
      turntable.render(frames: frames, left: left, right: right)
    }
    meter.push(left, right, frames: frames)
    if tap.isEnabled {
      tap.push(left: left, right: right, frames: frames, startFrame: start)
    }
    if leftTap.isEnabled {
      leftTap.push(left: left, right: nil, frames: frames, startFrame: start)
    }
    renderedFramesAtomic.store(start + frames, ordering: .releasing)
  }
}
