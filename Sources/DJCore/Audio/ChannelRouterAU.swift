@preconcurrency import AVFoundation
import AudioToolbox

/// An in-process AudioUnit that places two stereo inputs on chosen channel pairs of one
/// multichannel output: input 0 (the master mix) → `masterPair`, input 1 (the headphone
/// feed) → `cuePair`; every other output channel stays silent.
///
/// This is what lets one `AVAudioEngine` drive an interface like the Inpulse's, whose
/// outputs 1/2 are the speakers and 3/4 the headphones, sample-locked: AVAudioEngine has
/// no built-in way to put a stereo bus on channels 3/4 (Apple's matrix mixer only pulled
/// its first input bus in testing, and sink nodes are not pulled by the engine).
final class ChannelRouterAU: AUAudioUnit, @unchecked Sendable {
  static let componentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0x4A_52_4F_55,  // 'JROU'
    componentManufacturer: 0x44_4A_56_45,  // 'DJVE'
    componentFlags: 0, componentFlagsMask: 0)

  nonisolated(unsafe) private static var registered = false

  /// Instantiate through AVAudioEngine's AVAudioUnit wrapper.
  static func makeNode(
    outputChannels: Int, masterPair: Int, cuePair: Int, sampleRate: Double
  ) async throws -> (AVAudioUnit, ChannelRouterAU) {
    if !registered {
      AUAudioUnit.registerSubclass(
        ChannelRouterAU.self, as: componentDescription, name: "dj-vevr-se: Channel Router",
        version: 1)
      registered = true
    }
    let unit = try await AVAudioUnit.instantiate(
      with: componentDescription, options: .loadInProcess)
    guard let au = unit.auAudioUnit as? ChannelRouterAU else {
      throw CocoaError(.featureUnsupported)
    }
    au.configure(
      outputChannels: outputChannels, masterPair: masterPair, cuePair: cuePair,
      sampleRate: sampleRate)
    return (unit, au)
  }

  private var inBuses: AUAudioUnitBusArray!
  private var outBuses: AUAudioUnitBusArray!
  private(set) var outputChannels = 4
  private(set) var masterPair = 0
  private(set) var cuePair = 2

  // Render scratch, sized in allocateRenderResources.
  private var scratch: UnsafeMutablePointer<Float>?
  private var scratchFrames = 0
  // One AudioBufferList (2 buffers) per input bus, allocated once so render never mallocs.
  private var lists: [UnsafeMutablePointer<AudioBufferList>] = []

  override init(
    componentDescription: AudioComponentDescription,
    options: AudioComponentInstantiationOptions = []
  ) throws {
    try super.init(componentDescription: componentDescription, options: options)
    try rebuildBuses(sampleRate: 48_000, outputChannels: 4)
  }

  private func rebuildBuses(sampleRate: Double, outputChannels: Int) throws {
    let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let layout = AVAudioChannelLayout(
      layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(outputChannels))!
    let multi = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
      channelLayout: layout)
    inBuses = AUAudioUnitBusArray(
      audioUnit: self, busType: .input,
      busses: [try AUAudioUnitBus(format: stereo), try AUAudioUnitBus(format: stereo)])
    outBuses = AUAudioUnitBusArray(
      audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: multi)])
    self.outputChannels = outputChannels
  }

  func configure(outputChannels: Int, masterPair: Int, cuePair: Int, sampleRate: Double) {
    precondition(
      masterPair >= 0 && cuePair >= 0 && masterPair + 2 <= outputChannels
        && cuePair + 2 <= outputChannels)
    self.masterPair = masterPair
    self.cuePair = cuePair
    try? rebuildBuses(sampleRate: sampleRate, outputChannels: outputChannels)
  }

  override var inputBusses: AUAudioUnitBusArray { inBuses }
  override var outputBusses: AUAudioUnitBusArray { outBuses }
  override var channelCapabilities: [NSNumber]? { [2, -1, 2, -1] }

  override func allocateRenderResources() throws {
    try super.allocateRenderResources()
    scratchFrames = Int(maximumFramesToRender)
    scratch = .allocate(capacity: scratchFrames * 4)
    scratch!.initialize(repeating: 0, count: scratchFrames * 4)
    lists = (0..<2).map { _ in
      UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size,
        alignment: 16
      ).assumingMemoryBound(to: AudioBufferList.self)
    }
  }

  override func deallocateRenderResources() {
    super.deallocateRenderResources()
    scratch?.deallocate()
    scratch = nil
    for l in lists { UnsafeMutableRawPointer(l).deallocate() }
    lists = []
  }

  override var internalRenderBlock: AUInternalRenderBlock {
    let nOut = outputChannels
    let mPair = masterPair
    let cPair = cuePair
    return { [unowned self] flags, timestamp, frames, _, outputData, _, pull in
      guard let pull, let scratch = self.scratch, Int(frames) <= self.scratchFrames else {
        return kAudioUnitErr_Uninitialized
      }
      let n = Int(frames)
      // Pull each stereo input into its own half of the scratch.
      var status: OSStatus = noErr
      for bus in 0..<2 {
        let base = scratch + bus * 2 * self.scratchFrames
        let list = self.lists[bus]
        list.pointee.mNumberBuffers = 2
        withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
          let bufs = UnsafeMutableBufferPointer(start: first, count: 2)
          for c in 0..<2 {
            bufs[c] = AudioBuffer(
              mNumberChannels: 1, mDataByteSize: UInt32(n * 4),
              mData: UnsafeMutableRawPointer(base + c * self.scratchFrames))
          }
        }
        status = pull(flags, timestamp, frames, bus, list)
        if status != noErr { return status }
        // The upstream node may hand back its own buffers: copy into our scratch.
        withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
          let bufs = UnsafeMutableBufferPointer(start: first, count: 2)
          for c in 0..<2 {
            let dst = base + c * self.scratchFrames
            if let src = bufs[c].mData?.assumingMemoryBound(to: Float.self), src != dst {
              dst.update(from: src, count: n)
            }
          }
        }
      }
      let out = UnsafeMutableAudioBufferListPointer(outputData)
      for ch in 0..<min(nOut, out.count) {
        guard let dst = out[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
        out[ch].mDataByteSize = UInt32(n * 4)
        var from: UnsafeMutablePointer<Float>?
        if ch == mPair || ch == mPair + 1 {
          from = scratch + 0 * 2 * self.scratchFrames + (ch - mPair) * self.scratchFrames
        } else if ch == cPair || ch == cPair + 1 {
          from = scratch + 1 * 2 * self.scratchFrames + (ch - cPair) * self.scratchFrames
        }
        if let from {
          dst.update(from: from, count: n)
        } else {
          dst.update(repeating: 0, count: n)
        }
      }
      return noErr
    }
  }
}
