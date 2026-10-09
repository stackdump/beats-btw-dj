@preconcurrency import AVFoundation
import AudioToolbox

/// A pass-through AudioUnit that copies what flows through it into an `AudioTap`.
///
/// It sits between the main mixer and whatever the master goes to (the output, or the
/// channel router), so the tap holds the post-mix, post-master-gain signal. An
/// `AVAudioSinkNode` would be simpler, but the engine does not pull sink nodes in manual
/// rendering mode (nor, in testing, reliably elsewhere), and an `installTap` block runs on
/// another thread and allocates a buffer per callback. This runs on the render thread and
/// allocates nothing after `allocateRenderResources`.
final class MasterTapAU: AUAudioUnit, @unchecked Sendable {
  static let componentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0x4A_54_41_50,  // 'JTAP'
    componentManufacturer: 0x44_4A_56_45,  // 'DJVE'
    componentFlags: 0, componentFlagsMask: 0)

  nonisolated(unsafe) private static var registered = false

  /// Build the node. `tap` receives the mono mix of every block.
  static func makeNode(tap: AudioTap, sampleRate: Double) throws -> AVAudioUnitEffect {
    if !registered {
      AUAudioUnit.registerSubclass(
        MasterTapAU.self, as: componentDescription, name: "dj-vevr-se: Master Tap", version: 1)
      registered = true
    }
    let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
    guard let au = node.auAudioUnit as? MasterTapAU else { throw CocoaError(.featureUnsupported) }
    au.tap = tap
    return node
  }

  var tap: AudioTap?
  private var inBuses: AUAudioUnitBusArray!
  private var outBuses: AUAudioUnitBusArray!
  /// Used only if the engine hands us an output list without buffers.
  private var scratch: UnsafeMutablePointer<Float>?
  private var scratchFrames = 0

  override init(
    componentDescription: AudioComponentDescription,
    options: AudioComponentInstantiationOptions = []
  ) throws {
    try super.init(componentDescription: componentDescription, options: options)
    let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    inBuses = AUAudioUnitBusArray(
      audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: stereo)])
    outBuses = AUAudioUnitBusArray(
      audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: stereo)])
  }

  override var inputBusses: AUAudioUnitBusArray { inBuses }
  override var outputBusses: AUAudioUnitBusArray { outBuses }
  override var channelCapabilities: [NSNumber]? { [2, 2] }

  override func allocateRenderResources() throws {
    try super.allocateRenderResources()
    scratchFrames = Int(maximumFramesToRender)
    scratch = .allocate(capacity: scratchFrames * 2)
    scratch!.initialize(repeating: 0, count: scratchFrames * 2)
  }

  override func deallocateRenderResources() {
    super.deallocateRenderResources()
    scratch?.deallocate()
    scratch = nil
  }

  override var internalRenderBlock: AUInternalRenderBlock {
    return { [unowned self] flags, timestamp, frames, _, outputData, _, pull in
      guard let pull, let scratch = self.scratch, Int(frames) <= self.scratchFrames else {
        return kAudioUnitErr_Uninitialized
      }
      let n = Int(frames)
      let out = UnsafeMutableAudioBufferListPointer(outputData)
      for c in 0..<min(2, out.count) where out[c].mData == nil {
        out[c].mData = UnsafeMutableRawPointer(scratch + c * self.scratchFrames)
        out[c].mDataByteSize = UInt32(n * 4)
      }
      let status = pull(flags, timestamp, frames, 0, outputData)
      if status != noErr { return status }
      if let tap = self.tap, out.count >= 1,
        let l = out[0].mData?.assumingMemoryBound(to: Float.self)
      {
        let r = out.count > 1 ? out[1].mData?.assumingMemoryBound(to: Float.self) : nil
        tap.write(l, r, frames: n)
      }
      return noErr
    }
  }
}
