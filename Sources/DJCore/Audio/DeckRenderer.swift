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
/// A sample deck A / B also runs the net decks' master chain (`master`, the loop channel's
/// `LoopMasterBus`, one per deck, built here off the audio thread: `MasterChain` builds
/// wavetables): turntable → clip FX → master bus → limiter. The master macros (sweeps, holds, the
/// Feel puck's filter axis, the pitch shifter) land on the deck's next bar at its tempo
/// (`Deck.fire(_: MasterMacro)`). At rest the bus is bit-transparent, so a deck without master
/// FX renders the turntable's bytes. Its vinyl brake slows the turntable and the clip FX (the
/// renderer is its `BrakeSource`) and on release skips the playhead on by the frames it fell
/// behind, landing on the deck's grid; a hand on the platter or a transport stop cancels it (the
/// jog wins, from wherever the brake left the record).
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
  /// The master chain and macros on a sample deck (nil on the loop channel: its bank has its own).
  let master: LoopMasterBus?
  /// Did the clip's FX chain run in this block (audio thread)? The limiter runs while it does.
  private var blockFx = false
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
    master = bank == nil ? LoopMasterBus(sampleRate: turntable.sampleRate) : nil
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
    } else if let master {
      blockFx = false
      // this block's hand / transport first: a jog or a stop takes the record from the brake
      turntable.takeCommands()
      if master.braking && (turntable.handOn || !turntable.motorRunning) { master.cancelBrake() }
      master.render(self, frames: frames, left: left, right: right, startFrame: start)
      limit(frames: frames, left: left, right: right, engaged: master.engaged)
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

  /// Audio thread. The clip's FX over the turntable's block, only while it is in the path.
  /// Commands are taken in sample mode only (a net deck leaves them for when it is a sample deck
  /// again).
  private func processFx(
    frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?
  ) {
    guard let fx else { return }
    while let c = fxCommands.pop() { fx.set(c.params, sounding: c.sounding) }
    guard fx.running else { return }
    blockFx = true
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

  /// Audio thread. The safety limiter, last (after the master chain: distortion, crush and the
  /// pitch shifter can lift peaks), while the clip FX or the master bus changed the block or it
  /// is still coming back up.
  private func limit(
    frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?,
    engaged: Bool
  ) {
    guard let fxLimiter, blockFx || engaged || !fxLimiter.idle else { return }
    fxLimiter.process(left, right, n)
  }
}

// The master bus renders the turntable and the clip's FX as its source: the vinyl brake slows
// both together, and its release puts the turntable's playhead where it would have been.
extension DeckRenderer: BrakeSource {
  var playing: Bool { turntable.playing }

  func process(
    _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, frames: Int,
    startFrame: Int
  ) {
    turntable.process(left, right, frames: frames, startFrame: startFrame)
    processFx(frames: frames, left: left, right: right)
  }

  func brakeLag(sampleRate: Double) -> Double { turntable.brakeLag(sampleRate: sampleRate) }
  func brakeChunk(output: Int, pulled: Int) { turntable.brakeChunk(output: output, pulled: pulled) }
  func catchUp(ticks: Double) { turntable.catchUp(ticks: ticks) }
}

/// A clip's FX for a sample deck's chain (`DeckRenderer.sendFx`).
struct DeckFxCommand {
  var params: LoopFxParams
  var sounding: Bool
}
