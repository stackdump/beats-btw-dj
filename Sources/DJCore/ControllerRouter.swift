import Foundation

/// Where one incoming MIDI message went.
public enum RouteResult {
  case jog(JogEvent)
  case surface(ControlEvent, SurfaceOutcome)
  /// A surface port's message that its profile does not describe.
  case undecoded
  /// No controller is attached to this port.
  case ignored
}

/// Every attached controller, wired to one engine: the Hercules jog wheels (`JogAdapter`)
/// and the button/fader surfaces (`SurfaceController`). Pure routing: no CoreMIDI, no
/// threads, no wall clock — `ControllerHub` feeds it from the hardware, `SessionPlayer`
/// feeds it from a recording. Not thread-safe: use from one thread (the main actor in the
/// app).
public final class ControllerRouter {
  public let dj: DJEngine
  public let jogProfile: JogProfile
  public let surfaceProfiles: [SurfaceProfile]
  public private(set) var jogAdapters: [JogAdapter]
  public private(set) var surfaces: [String: SurfaceController] = [:]  // by port name

  public init(
    engine: DJEngine, jogProfile: JogProfile = .inpulse200MK3,
    surfaces: [SurfaceProfile] = SurfaceProfile.all
  ) {
    dj = engine
    self.jogProfile = jogProfile
    surfaceProfiles = surfaces
    jogAdapters = engine.decks.keys.sorted().map {
      JogAdapter(profile: jogProfile, clock: engine.decks[$0]!, deck: $0)
    }
  }

  /// The profile that handles a port, if any.
  public func profileName(for port: String) -> String? {
    surfaceProfiles.first { $0.matches(portName: port) }?.name
      ?? (jogProfile.matches(portName: port) ? jogProfile.name : nil)
  }

  /// Create the surface controller for `port` if a profile matches. True if the port is ours.
  @discardableResult
  public func attach(port: String) -> Bool {
    guard profileName(for: port) != nil else { return false }
    if surfaces[port] == nil, let s = surfaceProfiles.first(where: { $0.matches(portName: port) }) {
      surfaces[port] = SurfaceController(profile: s, engine: dj)
    }
    return true
  }

  /// Forget surface controllers whose ports are gone.
  public func keepOnly(_ present: Set<String>) {
    surfaces = surfaces.filter { present.contains($0.key) }
  }

  /// Route one message. The jog wheels get first look (the Inpulse shares its port with
  /// ordinary controls). Recorded when the engine has a recorder.
  @discardableResult
  public func route(
    port: String, bytes: [UInt8], now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> RouteResult {
    if jogProfile.matches(portName: port), let e = jogProfile.parse(bytes) {
      dj.recorder?.record(midi: port, bytes)
      for a in jogAdapters { a.handle(e) }
      return .jog(e)
    }
    guard let s = surfaces[port] else { return .ignored }
    dj.recorder?.record(midi: port, bytes)
    guard let (e, outcome) = s.handle(bytes: bytes, now: now) else { return .undecoded }
    return .surface(e, outcome)
  }

  /// Time-based housekeeping (jog-ring nudge decay). Call every ~10 ms.
  public func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    for a in jogAdapters { a.decay(now: now) }
  }

  /// LED updates for every attached surface, by port.
  public func ledFrames(now: TimeInterval = ProcessInfo.processInfo.systemUptime)
    -> [(port: String, messages: [[UInt8]])]
  {
    surfaces.map { ($0.key, $0.value.ledFrame(now: now)) }
  }

  public func blackouts() -> [(port: String, messages: [[UInt8]])] {
    surfaces.map { ($0.key, $0.value.blackout()) }
  }
}
