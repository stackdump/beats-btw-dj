import CoreAudio
import Foundation

/// A CoreAudio output device, as the headphone/cue output picker needs to see it.
public struct AudioOutputDevice: Equatable, Sendable {
  public let id: AudioDeviceID
  public let uid: String
  public let name: String
  /// Output channels across all of the device's output streams.
  public let outputChannels: Int
}

public enum AudioDevices {
  /// Every device with at least one output channel.
  public static func outputs() -> [AudioOutputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids.compactMap { id in
      let ch = outputChannelCount(id)
      guard ch > 0 else { return nil }
      return AudioOutputDevice(
        id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
        name: string(id, kAudioObjectPropertyName) ?? "device \(id)", outputChannels: ch)
    }
  }

  /// The Hercules Inpulse's own audio interface, if connected (it appears as an output
  /// device named after the controller).
  public static func inpulse() -> AudioOutputDevice? {
    outputs().first { $0.name.range(of: "inpulse", options: .caseInsensitive) != nil }
  }

  public static func device(uid: String) -> AudioOutputDevice? { outputs().first { $0.uid == uid } }

  private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr else { return nil }
    return cf?.takeRetainedValue() as String?
  }

  private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
      return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }
}
