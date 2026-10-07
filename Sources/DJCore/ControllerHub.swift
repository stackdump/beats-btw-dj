import CoreMIDI
import Foundation

/// Every supported controller, connected to one engine: the Hercules jog
/// wheels (via `JogAdapter`) and the button/fader surfaces (APC mini mk2,
/// MPK Mini) via `SurfaceController`. Hot-plug aware.
@MainActor
public final class ControllerHub {
  public struct Device: Equatable, Sendable {
    public let port: String
    public let profile: String
  }

  public let dj: DJEngine
  public private(set) var devices: [Device] = []
  /// Every routed message, decoded, for monitors and the UI.
  public var onMessage: ((MIDIMessage, String) -> Void)?

  public let jogProfile: JogProfile
  public let surfaceProfiles: [SurfaceProfile]
  public private(set) var jogAdapters: [JogAdapter] = []
  private var surfaces: [String: SurfaceController] = [:]  // by port name
  private var midiIn: MIDIIn?
  private let midiOut: MIDIOut?
  private var timer: Timer?

  public init(
    engine: DJEngine, jogProfile: JogProfile = .inpulse200MK3,
    surfaces: [SurfaceProfile] = SurfaceProfile.all
  ) {
    dj = engine
    self.jogProfile = jogProfile
    surfaceProfiles = surfaces
    midiOut = try? MIDIOut()
    jogAdapters = engine.decks.keys.sorted().map {
      JogAdapter(profile: jogProfile, clock: engine.decks[$0]!, deck: $0)
    }
  }

  public func start() throws {
    let midi = try MIDIIn(
      onSetupChange: {
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.rescan() } }
      },
      handler: { m in
        // DispatchQueue.main keeps arrival order (touch before scratch matters).
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.route(m) } }
      })
    midiIn = midi
    rescan()
    let t = Timer(timeInterval: 0.01, repeats: true) { _ in
      MainActor.assumeIsolated { [weak self] in self?.tick() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  public func stop() {
    timer?.invalidate()
    for (port, s) in surfaces { send(s.blackout(), to: port) }
  }

  /// Connect any newly appeared sources that match a profile.
  public func rescan() {
    guard let midiIn else { return }
    let known = Set(devices.map(\.port))
    _ = try? midiIn.connect { [self] p in
      guard !known.contains(p.name), let name = profileName(for: p.name) else { return false }
      devices.append(Device(port: p.name, profile: name))
      if let s = surfaceProfiles.first(where: { $0.matches(portName: p.name) }) {
        surfaces[p.name] = SurfaceController(profile: s, engine: dj)
      }
      return true
    }
    let present = Set(MIDIPort.sources().map(\.name))
    devices.removeAll { !present.contains($0.port) }
    surfaces = surfaces.filter { present.contains($0.key) }
  }

  func profileName(for port: String) -> String? {
    if jogProfile.matches(portName: port) { return jogProfile.name }
    return surfaceProfiles.first { $0.matches(portName: port) }?.name
  }

  func route(_ m: MIDIMessage) {
    if jogProfile.matches(portName: m.port) {
      if let e = jogProfile.parse(m.bytes) {
        for a in jogAdapters { a.handle(e) }
        onMessage?(m, "\(e)")
      } else {
        onMessage?(m, "")
      }
    } else if let s = surfaces[m.port] {
      if let e = s.profile.parse(m.bytes) {
        s.handle(e)
        let b = s.binding(for: e)
        onMessage?(
          m,
          "\(e.group)[\(e.index)]=\(String(format: "%.2f", e.value))"
            + (b.map { " → \($0.action.rawValue) \($0.deck ?? "")" } ?? ""))
      } else {
        onMessage?(m, "")
      }
    }
  }

  private var lastLED = 0.0

  func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    for a in jogAdapters { a.decay(now: now) }
    for d in dj.decks.values { d.turntable.drainRetired() }
    if now - lastLED >= 0.05 {
      lastLED = now
      for (port, s) in surfaces { send(s.ledFrame(now: now), to: port) }
    }
  }

  private func send(_ messages: [[UInt8]], to port: String) {
    guard !messages.isEmpty, let midiOut,
      let dest = MIDIPort.destinations().first(where: { $0.name == port })
    else {
      return
    }
    midiOut.send(messages, to: dest)
  }
}
