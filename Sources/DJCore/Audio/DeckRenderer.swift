import AudioToolbox
import Synchronization

/// What a deck's `AVAudioSourceNode` block does, as an object the block can capture without
/// capturing the `Deck` (no retain cycle, nothing but plain references on the audio thread).
///
/// Per render call it renders whichever source is active, counts the frames, and, only while a
/// scope has subscribed, pushes the mono mixdown into the deck's `ScopeTap` (and, only while the
/// stage's corona has subscribed, the LEFT channel alone into `leftTap`).
///
/// A clip moved onto deck A or B keeps its after effects (`LoopFx.swift`): the deck has a
/// `LoopFxVoice` and a safety limiter of its own (the loop bank's, one voice), allocated here,
/// fed through `fxCommands`. They run only in sample mode and only while the chain is in the
/// path (`LoopFxVoice.running`, or the limiter coming back up), so a dry deck's samples are the
/// turntable's bytes. The oversampled shapers make the deck `LoopFxVoice.latency` (23) samples
/// late against its own dry signal (the dry side of the mix waits as long), as under the mixer:
/// beat grid, tap and fire stamps are not moved for it (0.5 ms at 48 kHz).
///
/// Threading: `renderBlock` is the audio thread's; `sendFx` the main thread's. Everything else
/// here is read-only or an atomic read, from any thread.
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
  /// The clip's FX chain and limiter on a sample deck (nil on the loop channel: its voices
  /// have their own).
  let fx: LoopFxVoice?
  private let fxLimiter: LoopFxLimiter?
  private let fxCommands = SPSCRing<DeckFxCommand>(capacity: 32)
  /// The right channel for a mono render through the stereo chain (`fxChunk` frames a pass).
  private let fxScratch: UnsafeMutablePointer<Float>
  private static let fxChunk = 512

  init(turntable: Turntable, wave: WaveDeckSource, bank: LoopBank? = nil) {
    self.turntable = turntable
    self.wave = wave
    self.bank = bank
    meter = LoudnessMeter(sampleRate: turntable.sampleRate)
    fx = bank == nil ? LoopFxVoice(sampleRate: turntable.sampleRate) : nil
    fxLimiter = bank == nil ? LoopFxLimiter(sampleRate: turntable.sampleRate) : nil
    fxScratch = .allocate(capacity: Self.fxChunk)
    fxScratch.initialize(repeating: 0, count: Self.fxChunk)
  }

  deinit { fxScratch.deallocate() }

  /// Main thread. New FX for the clip on the deck: `sounding` smooths and crossfades the change
  /// (the clip is playing on), otherwise the chain starts clean at them (a load). Dropped with a
  /// full ring (32 waiting: never in practice, the audio thread empties it every block).
  func sendFx(_ p: LoopFxParams, sounding: Bool) {
    guard fx != nil else { return }
    fxCommands.push(DeckFxCommand(params: p, sounding: sounding))
  }

  /// Is the FX chain in the deck's path (as of the last block)? Tests.
  var fxRunning: Bool { fx?.running ?? false }

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
      processFx(frames: frames, left: left, right: right)
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

  /// Audio thread. The clip's FX over the turntable's block, then the limiter, both only while
  /// they are in the path. Commands are taken in sample mode only (a net deck leaves them for
  /// when it is a sample deck again).
  private func processFx(
    frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    guard let fx, let fxLimiter else { return }
    while let c = fxCommands.pop() { fx.set(c.params, sounding: c.sounding) }
    let ran = fx.running
    guard ran || !fxLimiter.idle else { return }
    if ran {
      if let right {
        fx.process(left, right, n)
      } else {
        var i = 0
        while i < n {
          let k = min(Self.fxChunk, n - i)
          fxScratch.update(from: left + i, count: k)
          fx.process(left + i, fxScratch, k)
          i += k
        }
      }
    }
    fxLimiter.process(left, right, n)
  }
}

/// A clip's FX for a sample deck's chain (`DeckRenderer.sendFx`).
struct DeckFxCommand {
  var params: LoopFxParams
  var sounding: Bool
}
