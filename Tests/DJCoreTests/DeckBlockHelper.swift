import AudioToolbox

@testable import DJCore

/// Drive a deck's source-node block with a buffer list whose buffers have no data pointers
/// (the engine never does this, but the block must not lose count of the frames if it did).
func renderWithoutBuffers(_ deck: Deck, frames: Int, buffers: Int = 2) {
  let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * buffers
  let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
  defer { raw.deallocate() }
  let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  list.pointee.mNumberBuffers = UInt32(buffers)
  withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
    for i in 0..<buffers {
      (first + i).pointee = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    }
  }
  deck.renderer.render(list, frames: frames)
}

/// Drive the block with real buffers through the buffer-list entry point, as the engine does.
func renderThroughBufferList(_ deck: Deck, frames: Int) -> (left: [Float], right: [Float]) {
  var l = [Float](repeating: 0, count: frames)
  var r = [Float](repeating: 0, count: frames)
  let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
  let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
  defer { raw.deallocate() }
  let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  list.pointee.mNumberBuffers = 2
  l.withUnsafeMutableBufferPointer { lp in
    r.withUnsafeMutableBufferPointer { rp in
      withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
        first.pointee = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: lp.baseAddress)
        (first + 1).pointee = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: rp.baseAddress)
      }
      deck.renderer.render(list, frames: frames)
    }
  }
  return (l, r)
}
