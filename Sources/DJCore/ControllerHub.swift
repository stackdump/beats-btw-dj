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
    surfaceProfiles.first { $0.matches(portName: port) }?.name
      ?? (jogProfile.matches(portName: port) ? jogProfile.name : nil)
  }

  /// Per-port tallies of what arrived, for the coverage report.
  public private(set) var stats: [String: Stats] = [:]
  public struct Stats: Sendable {
    public var bound = 0, jog = 0, unbound = 0, unmapped = 0, undecoded = 0
  }

  func route(_ m: MIDIMessage) {
    // Jog wheels first (the Inpulse shares its port with ordinary controls).
    if jogProfile.matches(portName: m.port), let e = jogProfile.parse(m.bytes) {
      for a in jogAdapters { a.handle(e) }
      stats[m.port, default: Stats()].jog += 1
      onMessage?(m, "\(e)")
      return
    }
    guard let s = surfaces[m.port] else { return }
    guard let (e, outcome) = s.handle(bytes: m.bytes) else {
      stats[m.port, default: Stats()].undecoded += 1
      onMessage?(m, "(undecoded)")
      return
    }
    let control =
      "\(e.group)[\(e.index)]" + (e.name.map { " \($0)" } ?? "")
      + (e.delta != 0 ? " Δ\(e.delta)" : String(format: "=%.3f", e.value))
    switch outcome {
    case .bound(let b):
      stats[m.port, default: Stats()].bound += 1
      onMessage?(m, "\(control) → \(b.action.rawValue) \(b.deck ?? "")")
    case .unbound(let reason):
      stats[m.port, default: Stats()].unbound += 1
      onMessage?(m, "\(control) (unbound: \(reason))")
    case .pickup(let b):
      stats[m.port, default: Stats()].bound += 1
      onMessage?(
        m,
        "\(control) → \(b.action.rawValue) \(b.deck ?? "") (soft takeover: move to current value)")
    case .unmapped:
      stats[m.port, default: Stats()].unmapped += 1
      onMessage?(m, "\(control) (UNMAPPED — profile gap)")
    }
  }

  private var lastLED = 0.0

  func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    for a in jogAdapters { a.decay(now: now) }
    for d in dj.decks.values {
      d.turntable.drainRetired()
      d.service()
    }
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
