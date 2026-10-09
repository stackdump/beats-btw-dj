@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

extension DJEngine {
  /// 0 = headphones hear only the cued decks, 1 = only the master mix.
  public var headphoneMix: Double {
    get { _headphoneMix }
    set {
      _headphoneMix = min(1, max(0, newValue))
      applyHeadphoneMix()
    }
  }

  /// 0...1
  public var headphoneLevel: Double {
    get { _headphoneLevel }
    set {
      _headphoneLevel = min(1, max(0, newValue))
      applyHeadphoneMix()
    }
  }

  func applyHeadphoneMix() {
    cueSum.outputVolume = Float(1 - _headphoneMix)
    headMaster.outputVolume = Float(_headphoneMix)
    headBus.outputVolume = Float(_headphoneLevel)
  }

  /// Route the engine's output through the channel router: the master mix on
  /// `masterPair` (channels 1/2 by default), the headphone feed on `cuePair` (3/4).
  /// Call before `start()`. For an offline engine the manual-render format must already
  /// have `channels` channels (`DJEngine(outputChannels:)`); for live output use
  /// `enableCueOutput(device:)`.
  public func enableCueRouting(channels: Int = 4, masterPair: Int = 0, cuePair: Int = 2)
    async throws
  {
    precondition(!engine.isRunning, "route before starting the engine")
    let (unit, _) = try await ChannelRouterAU.makeNode(
      outputChannels: channels, masterPair: masterPair, cuePair: cuePair, sampleRate: sampleRate)
    if let old = channelRouter {
      engine.disconnectNodeOutput(old)
      engine.detach(old)
    }
    channelRouter = unit
    engine.attach(unit)
    engine.disconnectNodeOutput(masterTapNode)
    engine.connect(
      masterTapNode,
      to: [
        AVAudioConnectionPoint(node: unit, bus: 0),
        AVAudioConnectionPoint(node: headMaster, bus: 0),
      ], fromBus: 0, format: format)
    engine.connect(headBus, to: unit, fromBus: 0, toBus: 1, format: format)
    let layout = AVAudioChannelLayout(
      layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
    let multi = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
      channelLayout: layout)
    engine.connect(unit, to: engine.outputNode, format: multi)
  }

  /// Send the master to channels 1/2 and the headphone cue to 3/4 of an interface (the
  /// Inpulse's built-in sound card). Live output only; the device needs at least 4 outputs.
  public func enableCueOutput(device: AudioOutputDevice, masterPair: Int = 0, cuePair: Int = 2)
    async throws
  {
    guard device.outputChannels >= max(masterPair, cuePair) + 2 else {
      throw CueOutputError.notEnoughChannels(device: device.name, has: device.outputChannels)
    }
    var id = device.id
    guard let au = engine.outputNode.audioUnit else { throw CueOutputError.noOutputUnit }
    let status = AudioUnitSetProperty(
      au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { throw CueOutputError.deviceRejected(status) }
    try await enableCueRouting(
      channels: device.outputChannels, masterPair: masterPair, cuePair: cuePair)
  }
}

extension DJEngine {
  /// Undo `enableCueOutput`: master back to a plain stereo path on the system's default
  /// output device. Call with the engine stopped.
  public func disableCueRouting() throws {
    precondition(!engine.isRunning, "stop the engine first")
    guard let unit = channelRouter else { return }
    engine.disconnectNodeOutput(unit)
    engine.detach(unit)
    channelRouter = nil
    engine.disconnectNodeOutput(masterTapNode)
    engine.connect(
      masterTapNode,
      to: [
        AVAudioConnectionPoint(node: engine.outputNode, bus: 0),
        AVAudioConnectionPoint(node: headMaster, bus: 0),
      ], fromBus: 0, format: format)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
      let au = engine.outputNode.audioUnit
    {
      AudioUnitSetProperty(
        au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
        UInt32(MemoryLayout<AudioDeviceID>.size))
    }
  }
}

public enum CueOutputError: Error, Equatable {
  case notEnoughChannels(device: String, has: Int)
  case noOutputUnit
  case deviceRejected(OSStatus)
}
