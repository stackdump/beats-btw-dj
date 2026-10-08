import Foundation

/// A ring net as a display sees it: where its hits are and where the token is.
public struct RingView: Equatable, Sendable {
  public var id: String
  public var role: String
  public var size: Int
  /// Per step: is there a note on the transition that fires from this step's place?
  public var hits: [Bool]
  public var velocities: [Int]
  /// Step the token sits on (the one that fires next).
  public var token: Int
  /// Step that fired most recently (-1 before the first tick).
  public var lastFired: Int
  /// How far into the current tick we are, 0…1: for a fading flash on `lastFired`.
  public var phase: Double
  public var muted: Bool

  public init(
    id: String, role: String, size: Int, hits: [Bool], velocities: [Int], token: Int,
    lastFired: Int, phase: Double, muted: Bool
  ) {
    self.id = id
    self.role = role
    self.size = size
    self.hits = hits
    self.velocities = velocities
    self.token = token
    self.lastFired = lastFired
    self.phase = phase
    self.muted = muted
  }
}

public struct NetSnapshot: Equatable, Sendable {
  public var tick: Int
  public var rings: [RingView]

  public init(tick: Int, rings: [RingView]) {
    self.tick = tick
    self.rings = rings
  }
}

/// The shape of a composer ring: `p0 → t0 → p1 → … → p(n-1) → t(n-1) → p0`, one token on p0.
struct RingShape: Equatable {
  var size: Int
  var hits: [Bool]
  var velocities: [Int]

  init?(_ nb: NetBundle) {
    let n = nb.places.count
    guard n > 0, nb.transitions.count == n, nb.arcs.count == 2 * n else { return nil }
    var seen = Set<String>()
    for a in nb.arcs {
      guard !a.inhibit, a.weight == [1] else { return nil }
      seen.insert("\(a.source)>\(a.target)")
    }
    for i in 0..<n {
      guard seen.contains("p\(i)>t\(i)"), seen.contains("t\(i)>p\((i + 1) % n)") else { return nil }
      guard let p = nb.places["p\(i)"], p.initial.reduce(0, +) == (i == 0 ? 1 : 0) else {
        return nil
      }
    }
    size = n
    hits = (0..<n).map { nb.bindings["t\($0)"] != nil }
    velocities = (0..<n).map { nb.bindings["t\($0)"]?.velocity ?? 0 }
  }
}

extension Deck {
  /// The audible ring of each role (kick, snare, …, plus the stingers), with token positions
  /// derived from the net clock — a single-token ring has its token on `tick mod n` — so
  /// nothing here reads the executor's state across threads.
  public var netSnapshot: NetSnapshot? {
    guard mode == .net, let project = netProject, let g = wave.latest?.graph else { return nil }
    let tick = wave.tick
    var rings: [RingView] = []
    let roles = Self.roleOrder + ["hit1", "hit2", "hit3", "hit4"]
    for role in roles {
      guard let target = g.roleTargets[strHash(role)] else { continue }
      let candidates = target >= 0 ? g.groupNets[target] : [-target - 2]
      let pick = candidates.first { !wave.isNetMuted(index: $0) } ?? candidates.first
      guard let idx = pick, let nb = project.nets[g.nets[idx].id] else { continue }
      let id = g.nets[idx].id
      let shape: RingShape
      if let cached = ringShapes[id] {
        shape = cached
      } else if let s = RingShape(nb) {
        ringShapes[id] = s
        shape = s
      } else {
        continue
      }
      rings.append(
        RingView(
          id: id, role: role, size: shape.size, hits: shape.hits, velocities: shape.velocities,
          token: tick % shape.size, lastFired: tick == 0 ? -1 : (tick - 1) % shape.size,
          phase: wave.tickPhase, muted: wave.isNetMuted(index: idx)))
    }
    return NetSnapshot(tick: tick, rings: rings)
  }
}
