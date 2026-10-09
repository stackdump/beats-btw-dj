@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization

// The master tap: a mono (L+R)/2 history of the master mix, taken from the render thread, once
// per render cycle, exactly like a deck's tap.
//
// Where it listens
// ----------------
// A render notification on the engine's output unit (`AudioUnitAddRenderNotify` on
// `engine.outputNode.audioUnit`): after the unit has pulled the whole graph for a cycle, the
// notification is handed the buffers that go to the device. That is the master mix after every
// deck strip, EQ, the crossfader and the master volume (`DJEngine.master`), and, when cue
// routing is on, after the channel router, so the tap reads the master pair
// (`enableCueRouting(masterPair:)`) and ignores the headphone feed.
//
// Why not `installTap`: AVAudioEngine delivers a tap's buffers in chunks of at least 100 ms, on
// another thread, one or two chunks late. A scope fed that way trails the render by a
// quarter of a second and moves in steps; it also has to be removed and put back whenever the
// graph around the main mixer is rewired (and doing that from two threads at once raises an
// uncatchable AVFoundation exception). A sink node would be exact, but the engine does not pull
// sink nodes in offline manual rendering, so nothing could be tested. The render notification
// works the same offline and live, is registered once and never touched again, and the only
// thing "subscribing" does is flip `ScopeTap.isEnabled`, which the notification reads.
//
// Time base
// ---------
// Sample stamps are *engine frames*: the same units as `DJEngine.frame`, every deck's
// `renderedFrames` and `FireEvent.frame`. The frame clock node (a silent source connected to the
// main mixer) counts the frames each cycle pulls through the mixer, so by the time the output
// unit's post-render notification runs, the clock has counted this cycle too: the cycle started
// at `clock.frames - frames`. A fire stamped at deck frame F is therefore at
// `masterTap.sequence(ofFrame: F)` in the tap exactly (pinned by tests): the strip, EQ and mixer
// nodes add no latency. After every cycle `masterTap.endFrame == DJEngine.frame`; nothing is
// delivered late. What the listener hears is `outputLatencyFrames` behind that.

/// The context of the output unit's render notification. Owned by the engine; registered on the
/// output unit once (main thread) and called on the render thread for every cycle.
final class MasterTapProbe: @unchecked Sendable {
  private let tap: ScopeTap
  private let clock: FrameClock
  /// First channel of the master pair among the output's channels: 0 on a plain stereo path,
  /// `masterPair` when the channel router is in.
  private let firstChannel = Atomic<Int>(0)
  /// Address of the output unit the notification is registered on (0: not yet).
  private let registered = Mutex<UInt>(0)

  init(tap: ScopeTap, clock: FrameClock) {
    self.tap = tap
    self.clock = clock
  }

  /// Did the output unit accept the notification? (If not, the master tap stays empty.)
  var isAttached: Bool { registered.withLock { $0 != 0 } }

  /// Which output channels carry the master mix.
  func setMasterChannel(_ first: Int) { firstChannel.store(max(0, first), ordering: .relaxed) }

  /// Register on the engine's output unit if that has not been done for this unit. Idempotent;
  /// safe from any thread.
  func attach(to engine: AVAudioEngine) {
    guard let unit = engine.outputNode.audioUnit else { return }
    let address = UInt(bitPattern: unit)
    let refCon = Unmanaged.passUnretained(self).toOpaque()
    registered.withLock { current in
      if current == address { return }
      // A different unit means the engine replaced its output unit; the old one is gone with
      // it (its registration dies with it), so it is not touched.
      let status = AudioUnitAddRenderNotify(unit, masterTapRender, refCon)
      current = status == noErr ? address : 0
    }
  }

  /// Unregister. Call before the engine goes away.
  func detach() {
    let refCon = Unmanaged.passUnretained(self).toOpaque()
    registered.withLock { current in
      if let unit = AudioUnit(bitPattern: current) {
        AudioUnitRemoveRenderNotify(unit, masterTapRender, refCon)
      }
      current = 0
    }
  }

  /// Render thread. The output unit finished a cycle of `n` frames; `data` is what it produced.
  func rendered(_ data: UnsafeMutablePointer<AudioBufferList>, frames n: Int) {
    guard tap.isEnabled, n > 0 else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    let first = firstChannel.load(ordering: .relaxed)
    // The clock node has counted this cycle already (see the header): it began n frames ago.
    let start = clock.frames.load(ordering: .relaxed) - n
    if buffers.count == 1, buffers[0].mNumberChannels > 1 {
      // interleaved: one buffer, `k` channels
      let k = Int(buffers[0].mNumberChannels)
      guard first < k, let base = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
        return
      }
      tap.push(
        left: base + first, right: first + 1 < k ? base + first + 1 : nil, frames: n,
        startFrame: start, stride: k)
    } else {
      // one buffer per channel
      guard first < buffers.count,
        let left = buffers[first].mData?.assumingMemoryBound(to: Float.self)
      else { return }
      let right =
        first + 1 < buffers.count
        ? buffers[first + 1].mData?.assumingMemoryBound(to: Float.self) : nil
      tap.push(left: left, right: right, frames: n, startFrame: start)
    }
  }
}

/// `AURenderCallback` for `AudioUnitAddRenderNotify`: pre- and post-render notifications. Only a
/// successful post-render one carries finished audio. The `OutputIsSilence` flag is deliberately
/// not consulted: on the routed path it comes back set from the upstream pulls (the idle
/// headphone bus) while the master pair is audible (measured offline), and the buffers always
/// hold the cycle's real data.
private let masterTapRender: AURenderCallback = { refCon, flags, _, _, frames, data in
  let f = flags.pointee
  guard f.contains(.unitRenderAction_PostRender), !f.contains(.unitRenderAction_PostRenderError),
    let data
  else { return noErr }
  Unmanaged<MasterTapProbe>.fromOpaque(refCon).takeUnretainedValue()
    .rendered(data, frames: Int(frames))
  return noErr
}

extension DJEngine {
  /// Is the master tap wired to the output unit? True once the engine is built; false would
  /// mean the unit refused the render notification and `masterTap` will stay empty.
  public var masterTapAttached: Bool { masterProbe.isAttached }

  /// How far behind the render head the listener hears the audio, in frames: the output
  /// device's presentation latency (zero when rendering offline). Every time stamp in the
  /// scope plumbing (deck and master taps, fire events, tick anchors) is at the render head;
  /// subtract this from "now" to line the display up with the speakers.
  public var outputLatencyFrames: Int {
    max(0, Int((engine.outputNode.presentationLatency * sampleRate).rounded()))
  }
}
