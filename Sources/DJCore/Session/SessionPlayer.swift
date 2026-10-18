@preconcurrency import AVFoundation
import Foundation

/// Steps an offline engine through time the way the live app does, in fixed blocks: apply
/// the inputs due, run the 100 Hz housekeeping (jog-ring decay, deck service), render a
/// block. Both `SessionPlayer` and tests that perform a set use it, so a live run and its
/// replay take exactly the same steps.
public final class OfflineConductor {
  public static let blockFrames = 128

  public let dj: DJEngine
  public let router: ControllerRouter
  private let out: AVAudioPCMBuffer
  private let housekeepingEvery: Int
  private var nextHousekeeping = 0

  public init(engine: DJEngine, router: ControllerRouter) {
    dj = engine
    self.router = router
    out = AVAudioPCMBuffer(
      pcmFormat: engine.engine.manualRenderingFormat, frameCapacity: 4096)!
    housekeepingEvery = max(1, Int(engine.sampleRate / 100))
  }

  /// Engine time in seconds, what the router sees as "now".
  public var now: TimeInterval { Double(dj.frame) / dj.sampleRate }

  /// One block: `inputs` runs first (apply whatever is due at `dj.frame`), then the
  /// housekeeping tick if due, then the render. Returns the block's left/right samples.
  public func step(inputs: () -> Void = {}) throws -> (left: [Float], right: [Float]) {
    inputs()
    if dj.frame >= nextHousekeeping {
      nextHousekeeping = dj.frame + housekeepingEvery
      router.tick(now: now)
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
      dj.serviceWander()
    }
    let status = try dj.engine.renderOffline(AVAudioFrameCount(Self.blockFrames), to: out)
    guard status == .success else { return ([], []) }
    let n = Int(out.frameLength)
    let l = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
    let r = Array(
      UnsafeBufferPointer(
        start: out.floatChannelData![out.format.channelCount > 1 ? 1 : 0], count: n))
    return (l, r)
  }
}

/// Planar float audio.
public struct RenderedAudio: Sendable {
  public var sampleRate: Double
  public var left: [Float]
  public var right: [Float]
  public var frames: Int { left.count }
  public init(sampleRate: Double, left: [Float], right: [Float]) {
    self.sampleRate = sampleRate
    self.left = left
    self.right = right
  }
}

/// Re-renders a `Session` offline: the same engine, the same inputs at the same frames.
/// Deterministic: two renders of one session are byte-identical.
public final class SessionPlayer {
  public let session: Session
  private let samples: (String) -> SampleBuffer?
  /// Roles left out of every net deck's render (stems for listening tests). Applied when a
  /// deck compiles, so the session — and its CID — are untouched.
  public var roleFilter: RoleFilter?
  /// Each deck's wander log after the last `render`: the walk the replay took.
  public private(set) var wanderLogs: [String: [WanderMove]] = [:]
  /// Called after every block `render` plays, with the engine and the frames rendered so far
  /// (tests: to see where a replay parts from the live set it was recorded from).
  var onBlock: ((DJEngine, Int) -> Void)?

  /// `samples` resolves a sample's content id (the demo loop is built in).
  public init(
    session: Session, roleFilter: RoleFilter? = nil,
    samples: @escaping (String) -> SampleBuffer? = { _ in nil }
  ) {
    self.session = session
    self.roleFilter = roleFilter
    self.samples = samples
  }

  public func render() throws -> RenderedAudio {
    let dj = try DJEngine(
      decks: session.decks.keys.sorted(), offline: true, sampleRate: session.sampleRate)
    dj.deterministic = true
    dj.sampleResolver = samples
    // Every sample the set ever loads must be in hand before the first frame.
    var needed: [String] = []
    for source in session.decks.values {
      if case .sample(let id, _, _) = source { needed.append(id) }
    }
    for e in session.events {
      if case .action(.load(_, .sample(let id, _, _))) = e.kind { needed.append(id) }
      if case .action(.clipImport(let id, _, _, _, _)) = e.kind { needed.append(id) }
    }
    for id in needed where id != DeckSourceDescriptor.demoID && samples(id) == nil {
      throw SessionError.missingSample(id: id)
    }
    if let roleFilter, !roleFilter.isEmpty {
      for name in session.decks.keys { dj[name]?.roleFilter = roleFilter }
    }
    // Starting state.
    for (name, source) in session.decks.sorted(by: { $0.key < $1.key }) {
      dj.applyAction(.load(deck: name, source: source))
      if let p = session.params[name] { dj[name]?.apply(p) }
    }
    dj.crossfader = session.crossfader
    dj.master = session.master
    try dj.start()
    defer { dj.stop() }

    let router = ControllerRouter(engine: dj)
    var attached = Set<String>()
    let conductor = OfflineConductor(engine: dj, router: router)
    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(session.frames)
    right.reserveCapacity(session.frames)
    var next = 0
    let events = session.events
    while left.count < session.frames {
      let (l, r) = try conductor.step {
        while next < events.count, events[next].frame <= dj.frame {
          apply(events[next], dj: dj, router: router, attached: &attached, now: conductor.now)
          next += 1
        }
      }
      if l.isEmpty { break }
      left += l
      right += r
      onBlock?(dj, left.count)
    }
    wanderLogs = dj.decks.mapValues(\.wander.log)
    left.removeLast(max(0, left.count - session.frames))
    right.removeLast(max(0, right.count - session.frames))
    return RenderedAudio(sampleRate: session.sampleRate, left: left, right: right)
  }

  private func apply(
    _ e: SessionEvent, dj: DJEngine, router: ControllerRouter, attached: inout Set<String>,
    now: TimeInterval
  ) {
    switch e.kind {
    case .midi(let port, let bytes):
      if !attached.contains(port) {
        router.attach(port: port)
        attached.insert(port)
      }
      router.route(port: port, bytes: bytes, now: now)
    case .action(let a):
      dj.applyAction(a)
    }
  }
}

// MARK: - WAV

public enum WAV {
  /// 32-bit float or 16-bit PCM, interleaved stereo RIFF.
  public static func encode(_ audio: RenderedAudio, float32: Bool = false) -> Data {
    let ch = 2
    let bytesPer = float32 ? 4 : 2
    let n = audio.frames
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + n * ch * bytesPer))
    d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(float32 ? 3 : 1)
    u16(UInt16(ch))
    u32(UInt32(audio.sampleRate))
    u32(UInt32(audio.sampleRate) * UInt32(ch * bytesPer))
    u16(UInt16(ch * bytesPer))
    u16(UInt16(bytesPer * 8))
    d.append(contentsOf: Array("data".utf8))
    u32(UInt32(n * ch * bytesPer))
    d.reserveCapacity(d.count + n * ch * bytesPer)
    for i in 0..<n {
      for s in [audio.left[i], audio.right[i]] {
        if float32 {
          u32(s.bitPattern)
        } else {
          let c = max(-1, min(1, s))
          u16(UInt16(bitPattern: Int16(c < 0 ? (c * 32768).rounded() : (c * 32767).rounded())))
        }
      }
    }
    return d
  }
}
