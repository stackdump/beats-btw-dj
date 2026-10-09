import AudioToolbox

@testable import DJCore

/// Hand the master tap's render notification a finished cycle, the way the output unit would:
/// `channels` as one buffer each, or interleaved into one buffer.
func feedMasterProbe(
  _ probe: MasterTapProbe, channels: [[Float]], interleaved: Bool = false
) {
  let frames = channels.first?.count ?? 0
  let buffers = interleaved ? 1 : channels.count
  let bytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * buffers
  let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
  defer { raw.deallocate() }
  let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
  list.pointee.mNumberBuffers = UInt32(buffers)
  var storage: [[Float]] =
    interleaved ? [(0..<frames).flatMap { i in channels.map { $0[i] } }] : channels
  var pointers: [UnsafeMutablePointer<Float>] = []
  for i in storage.indices {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, storage[i].count))
    p.initialize(from: storage[i], count: storage[i].count)
    pointers.append(p)
  }
  defer { for p in pointers { p.deallocate() } }
  withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
    for i in 0..<buffers {
      (first + i).pointee = AudioBuffer(
        mNumberChannels: interleaved ? UInt32(channels.count) : 1,
        mDataByteSize: UInt32(storage[i].count * 4), mData: pointers[i])
    }
  }
  probe.rendered(list, frames: frames)
  storage.removeAll()
}
