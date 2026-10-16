@preconcurrency import AVFoundation
import AudioToolbox
import Synchronization

// The loop recorder's ear: a stereo history of one deck after its EQ and filter, before the
// fader and the crossfader, so a take sounds like the deck and not like the mix.
//
// Where it listens: a render notification on the deck's EQ unit (`AudioUnitAddRenderNotify` on
// `filterNode.audioUnit`), the same technique as `MasterTapProbe`, for the same reasons (no
// latency, the same offline and live, registered once). The EQ is pulled once per cycle, after
// the deck's source node has rendered that cycle, so the cycle began at `renderedFrames - n` in
// the deck's frame time base: the units of `Deck.renderedFrames` and `TickAnchor.frame`.
//
// Unlike the scope taps it is always on: holding LOOP snaps back to the bar already playing, so
// the history has to be there before anyone asks. One cycle costs two memcpys.

/// A stereo history of a deck after its EQ, on the deck's frame time base.
///
/// Threading: `rendered` is the render thread's (one producer). Everything else is any thread.
final class CaptureTap: @unchecked Sendable {
  /// 2^20 frames: 21.8 s at 48 kHz. A take is drained into the recorder while it is held, so
  /// this only bounds how far a reader may fall behind (the snap-back is under a bar).
  static let defaultCapacity = 1 << 20

  let left: LatestRing<Float>
  let right: LatestRing<Float>
  /// Deck frame of sequence number 0 (-1 until the first cycle).
  private let originAtomic = Atomic<Int>(-1)
  private let renderedFrames: @Sendable () -> Int
  private let registered = Mutex<UInt>(0)

  init(capacity: Int = CaptureTap.defaultCapacity, renderedFrames: @escaping @Sendable () -> Int) {
    left = LatestRing(capacity: capacity)
    right = LatestRing(capacity: capacity)
    self.renderedFrames = renderedFrames
  }

  /// Deck frame of the first sample in the history, or nil before any audio.
  var originFrame: Int? {
    let o = originAtomic.load(ordering: .acquiring)
    return o < 0 ? nil : o
  }

  /// One past the newest frame captured (deck frames); `originFrame` when empty.
  var endFrame: Int? { originFrame.map { $0 + right.written } }

  /// The oldest frame still held.
  var startFrame: Int? { originFrame.map { $0 + max(0, right.written - right.capacity) } }

  /// Copy deck frames `from..<to` (as far as captured) onto `l`/`r`. Returns the frame after
  /// the last one copied. Frames already overwritten come back as silence, so a slow reader
  /// gets a take of the right length with a hole, never a shifted one.
  func copy(from: Int, to: Int, left l: inout [Float], right r: inout [Float]) -> Int {
    guard let origin = originFrame, let end = endFrame, from < min(to, end) else { return from }
    let stop = min(to, end)
    var cursor = from
    withUnsafeTemporaryAllocation(of: Float.self, capacity: 1024) { a in
      withUnsafeTemporaryAllocation(of: Float.self, capacity: 1024) { b in
        while cursor < stop {
          if cursor < origin {  // before the deck ever rendered
            let n = min(stop, origin) - cursor
            l.append(contentsOf: repeatElement(0, count: n))
            r.append(contentsOf: repeatElement(0, count: n))
            cursor += n
            continue
          }
          let want = min(1024, stop - cursor)
          let seq = cursor - origin
          // Right is written after left: whatever right has, left has too.
          let rr = right.read(from: seq, into: UnsafeMutableBufferPointer(rebasing: b[0..<want]))
          if rr.lost > 0 {
            let n = min(rr.lost, stop - cursor)
            l.append(contentsOf: repeatElement(0, count: n))
            r.append(contentsOf: repeatElement(0, count: n))
            cursor += n
            continue
          }
          guard rr.count > 0 else { break }
          let lr = left.read(
            from: seq, into: UnsafeMutableBufferPointer(rebasing: a[0..<rr.count]))
          if lr.lost > 0 || lr.count < rr.count {
            // lapped between the two reads: the newer data is gone from left; keep time
            l.append(contentsOf: repeatElement(0, count: rr.count))
          } else {
            l.append(contentsOf: UnsafeBufferPointer(rebasing: a[0..<rr.count]))
          }
          r.append(contentsOf: UnsafeBufferPointer(rebasing: b[0..<rr.count]))
          cursor += rr.count
        }
      }
    }
    return cursor
  }

  /// Register on the EQ unit. Idempotent; safe from any thread.
  func attach(to unit: AudioUnit?) {
    guard let unit else { return }
    let address = UInt(bitPattern: unit)
    let refCon = Unmanaged.passUnretained(self).toOpaque()
    registered.withLock { current in
      if current == address { return }
      let status = AudioUnitAddRenderNotify(unit, captureTapRender, refCon)
      current = status == noErr ? address : 0
    }
  }

  var isAttached: Bool { registered.withLock { $0 != 0 } }

  func detach() {
    let refCon = Unmanaged.passUnretained(self).toOpaque()
    registered.withLock { current in
      if let unit = AudioUnit(bitPattern: current) {
        AudioUnitRemoveRenderNotify(unit, captureTapRender, refCon)
      }
      current = 0
    }
  }

  /// Render thread. The EQ finished a cycle of `n` frames.
  func rendered(_ data: UnsafeMutablePointer<AudioBufferList>, frames n: Int) {
    guard n > 0 else { return }
    let start = renderedFrames() - n
    var origin = originAtomic.load(ordering: .relaxed)
    if origin < 0 {
      origin = start
      originAtomic.store(origin, ordering: .releasing)
    }
    let expected = origin + right.written
    if start > expected {  // the deck skipped time: fill it, so frame = origin + sequence holds
      left.write(repeating: 0, count: start - expected)
      right.write(repeating: 0, count: start - expected)
    } else if start < expected {
      return  // never seen; a repeated cycle would shift everything after it
    }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    guard buffers.count > 0, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
      left.write(repeating: 0, count: n)
      right.write(repeating: 0, count: n)
      return
    }
    if buffers.count == 1, buffers[0].mNumberChannels > 1 {
      // interleaved: not what the engine uses between nodes, but keep the time base
      let k = Int(buffers[0].mNumberChannels)
      for i in 0..<n { left.write(l[i * k]) }
      for i in 0..<n { right.write(l[i * k + 1]) }
      return
    }
    let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
    left.write(contentsOf: UnsafeBufferPointer(start: l, count: n))
    right.write(contentsOf: UnsafeBufferPointer(start: r, count: n))
  }
}

private let captureTapRender: AURenderCallback = { refCon, flags, _, _, frames, data in
  let f = flags.pointee
  guard f.contains(.unitRenderAction_PostRender), !f.contains(.unitRenderAction_PostRenderError),
    let data
  else { return noErr }
  Unmanaged<CaptureTap>.fromOpaque(refCon).takeUnretainedValue()
    .rendered(data, frames: Int(frames))
  return noErr
}
