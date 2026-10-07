import CoreMIDI
import Foundation

/// A MIDI endpoint as CoreMIDI reports it.
public struct MIDIPort: Sendable, Hashable {
  public let name: String
  public let endpoint: MIDIEndpointRef

  public static func sources() -> [MIDIPort] {
    (0..<MIDIGetNumberOfSources()).map { MIDIPort(endpoint: MIDIGetSource($0)) }
  }

  public static func destinations() -> [MIDIPort] {
    (0..<MIDIGetNumberOfDestinations()).map { MIDIPort(endpoint: MIDIGetDestination($0)) }
  }

  init(endpoint: MIDIEndpointRef) {
    self.endpoint = endpoint
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf)
    self.name = (cf?.takeRetainedValue() as String?) ?? "endpoint \(endpoint)"
  }
}

/// One MIDI 1.0 message with its host-time timestamp in seconds.
public struct MIDIMessage: Sendable {
  public let port: String
  public let bytes: [UInt8]
  public let time: TimeInterval
}

/// Listens to CoreMIDI sources and delivers MIDI 1.0 byte messages.
/// The handler runs on CoreMIDI's own thread: keep it short and hand off.
public final class MIDIIn: @unchecked Sendable {
  private var client = MIDIClientRef()
  private var input = MIDIPortRef()
  private var connected: [MIDIEndpointRef: String] = [:]
  private let lock = NSLock()

  public init(name: String = "dj-vevr-se", handler: @escaping @Sendable (MIDIMessage) -> Void)
    throws
  {
    try check(MIDIClientCreateWithBlock(name as CFString, &client, nil), "MIDIClientCreate")
    try check(
      MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &input) {
        [weak self] list, src in
        guard let self else { return }
        let endpoint = MIDIEndpointRef(UInt(bitPattern: src))
        let port = self.lock.withLock { self.connected[endpoint] } ?? "?"
        for packet in list.unsafeSequence() {
          let time = Self.seconds(packet.pointee.timeStamp)
          for bytes in Self.midi1Bytes(packet) {
            handler(MIDIMessage(port: port, bytes: bytes, time: time))
          }
        }
      }, "MIDIInputPortCreate")
  }

  deinit {
    MIDIPortDispose(input)
    MIDIClientDispose(client)
  }

  /// Connect every source whose name matches `filter` (nil = all). Returns the ports connected.
  @discardableResult
  public func connect(where filter: (MIDIPort) -> Bool = { _ in true }) throws -> [MIDIPort] {
    let ports = MIDIPort.sources().filter(filter)
    for p in ports {
      lock.withLock { connected[p.endpoint] = p.name }
      let ref = UnsafeMutableRawPointer(bitPattern: UInt(p.endpoint))
      try check(MIDIPortConnectSource(input, p.endpoint, ref), "MIDIPortConnectSource \(p.name)")
    }
    return ports
  }

  // UMP MIDI 1.0 channel-voice packets (message type 0x2) -> classic 3-byte messages.
  // Other message types (system, sysex) are dropped; the jog wheel only sends channel voice.
  static func midi1Bytes(_ packet: UnsafePointer<MIDIEventPacket>) -> [[UInt8]] {
    var out: [[UInt8]] = []
    let count = Int(packet.pointee.wordCount)
    withUnsafeBytes(of: packet.pointee.words) { raw in
      let words = raw.bindMemory(to: UInt32.self)
      for i in 0..<min(count, words.count) {
        let w = words[i]
        guard w >> 28 == 0x2 else { continue }
        out.append([UInt8((w >> 16) & 0xFF), UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F)])
      }
    }
    return out
  }

  static func seconds(_ hostTime: MIDITimeStamp) -> TimeInterval {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(hostTime) * Double(tb.numer) / Double(tb.denom) / 1e9
  }
}

struct MIDIError: Error, CustomStringConvertible {
  let call: String
  let status: OSStatus
  var description: String { "\(call) failed: OSStatus \(status)" }
}

private func check(_ status: OSStatus, _ call: String) throws {
  if status != noErr { throw MIDIError(call: call, status: status) }
}
