// Stage layout: the pure geometry and selection rules of beats' Stage (stage.js), no engine and
// no UI. Everything here is a function of its arguments, so each constant is pinned by a test
// against the JS (the literals in StageLayoutTests come from running stage.js's arithmetic in
// node).
//
//   * `distributeEvenly`  : the golden-ratio stride permutation that spreads same-channel panels
//   * `eligibleKeys`      : which nets get a panel (stage.js `eligibleNetIds`)
//   * `variantSwap`       : the riff-group slot flip (stage.js `stageOnMuteStateChange`)
//   * `layoutRing`        : panel size and positions on the big ring, the meta-net's inner ring
//                           (stage.js `layoutRing`)
//   * `StagePanelView`    : one panel's fit-to-box transform (stage.js `layoutPanel`) and
//                           `nodeCenterInStage`

import Foundation

/// A point in stage coordinates (the whole window, y down).
public struct StagePoint: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

/// The toolbar's panel-size select (`.pn-stage-scale`).
public enum StageScale: String, CaseIterable, Sendable {
  case loop, s, m, l, xl

  /// stage.js `scaleMult`.
  public var multiplier: Double {
    switch self {
    case .loop: 1
    case .s: 0.45
    case .m: 0.75
    case .l: 1.6
    case .xl: 2.4
    }
  }

  /// The select's option text.
  public var title: String {
    switch self {
    case .loop: "Fit"
    case .s: "S"
    case .m: "M"
    case .l: "L"
    case .xl: "XL"
    }
  }
}

/// What the ring layout decided for a stage of `width` x `height` with `count` panels.
public struct StageRingLayout: Equatable, Sendable {
  public var width: Double
  public var height: Double
  public var count: Int
  /// A panel is a square this long.
  public var side: Double
  /// Distance from the stage centre to a panel centre (0 for a single panel).
  public var radius: Double
  public var center: StagePoint
  /// Panel centres, in panel order: panel `i` at angle `i/n * 2pi - pi/2` (12 o'clock first,
  /// clockwise). A single panel sits at the stage centre.
  public var panelCenters: [StagePoint]
  /// stage.js leaves `ringX`/`ringY` unset for a single panel (it returns before the ring is
  /// laid out), so pulse and flame skip it. False for `count == 1`.
  public var hasRing: Bool
  /// Radius of a meta-net place circle. Nil without a ring.
  public var placeR: Double?
  /// Radius at which the meta-net's places sit (0.35 of the ring). Nil without a ring.
  public var placeRadius: Double?
  /// The implied centre object, just inside the inner place ring; bolts and pulses stop on its
  /// perimeter. Nil without a ring (stage.js leaves `darkPlanetRadius` unset for one panel:
  /// every consumer then has its own fallback).
  public var darkPlanetRadius: Double?
  /// Meta-net place centres: place `i` at angle `(i + 0.5)/n * 2pi - pi/2`, pulled in to
  /// `placeRadius`. Empty without a ring.
  public var placeCenters: [StagePoint]
  /// The meta-net (inner places + radial arcs) is drawn for 2...16 panels only.
  public var showsMeta: Bool
}

public enum StagePanelLayout {
  /// More panels than this and the inner place circles overlap into a thick blue band.
  public static let maxMetaPanels = 16

  // MARK: distributeEvenly

  /// stage.js `gcd`.
  static func gcd(_ a: Int, _ b: Int) -> Int {
    var a = a
    var b = b
    while b != 0 { (a, b) = (b, a % b) }
    return a
  }

  /// The stride of `distributeEvenly` for `n` items: the integer in `2..<n` coprime to `n` that
  /// is closest to `n * 0.381966` (n / phi^2); on a tie the smaller. `n - 1` when none beats
  /// infinity (n < 3 never gets here).
  public static func stride(count n: Int) -> Int {
    let ideal = Double(n) * 0.381966
    var best = n - 1
    var bestDist = Double.infinity
    var k = 2
    while k < n {
      if gcd(k, n) == 1 {
        let d = abs(Double(k) - ideal)
        if d < bestDist {
          bestDist = d
          best = k
        }
      }
      k += 1
    }
    return best
  }

  /// stage.js `distributeEvenly`: panels arriving in channel order would cluster (all bass
  /// variants adjacent), which animates unevenly; re-index `i -> (i * stride) mod n` so that
  /// neighbours in the input land on opposite sides of the ring. Fewer than four items keep
  /// their order. The same input always gives the same output.
  public static func distributeEvenly<T>(_ items: [T]) -> [T] {
    let n = items.count
    if n < 4 { return items }
    let s = stride(count: n)
    var out = items
    for i in 0..<n { out[(i * s) % n] = items[i] }
    return out
  }

  // MARK: eligibility

  /// What `eligibleKeys` needs to know about one net of a loaded song.
  public struct NetDesc: Equatable, Sendable {
    /// Unique over the whole stage: `"<deck>/<net id>"`.
    public var key: String
    public var id: String
    public var deck: String
    /// "music" or "control".
    public var role: String
    public var riffGroup: String
    /// The track's channel (0 when there is no track).
    public var channel: Int
    public var placeCount: Int
    public var transitionCount: Int
    /// Muted right now (`_mutedNets` or `_manualMutedNets`).
    public var muted: Bool

    public init(
      key: String? = nil, id: String, deck: String = "", role: String = "music",
      riffGroup: String = "", channel: Int = 0, placeCount: Int = 1, transitionCount: Int = 1,
      muted: Bool = false
    ) {
      self.key = key ?? "\(deck)/\(id)"
      self.id = id
      self.deck = deck
      self.role = role
      self.riffGroup = riffGroup
      self.channel = channel
      self.placeCount = placeCount
      self.transitionCount = transitionCount
      self.muted = muted
    }

    /// Riff groups live in a deck's namespace.
    fileprivate var groupKey: String { riffGroup.isEmpty ? "" : "\(deck)\u{1}\(riffGroup)" }
  }

  /// stage.js `eligibleNetIds`, returning the nets' keys in ring order.
  ///
  /// All music nets with real content (control nets and empty nets never get a panel). A muted
  /// panel stays in the ring (dimmed) so the composition does not reflow when mutes flip
  /// mid-section; `hit*` stinger tracks are the exception: muted by default they would only be
  /// dead dimmed squares, so they get a panel only while unmuted. Riff-group variants (the A/B/C
  /// slot alternates) collapse to ONE panel per group, showing the unmuted variant (else the
  /// first), unless `expandVariants`. Panels are sorted by channel (stable), then spread round
  /// the ring by `distributeEvenly`.
  public static func eligibleKeys(_ nets: [NetDesc], expandVariants: Bool) -> [String] {
    var ids: [NetDesc] = []
    for net in nets {
      if net.role == "control" { continue }
      if net.placeCount == 0 || net.transitionCount == 0 { continue }
      if net.id.hasPrefix("hit") && net.muted { continue }
      ids.append(net)
    }
    var picked: [NetDesc] = []
    if expandVariants {
      picked = ids
    } else {
      var seen = Set<String>()
      for net in ids {
        let group = net.groupKey
        if group.isEmpty {
          picked.append(net)
          continue
        }
        if seen.contains(group) { continue }
        seen.insert(group)
        let members = ids.filter { $0.groupKey == group }
        picked.append(members.first { !$0.muted } ?? members[0])
      }
    }
    // Array.prototype.sort is stable: equal channels keep their project order.
    let sorted = picked.enumerated().sorted { a, b in
      if a.element.channel != b.element.channel { return a.element.channel < b.element.channel }
      return a.offset < b.offset
    }.map(\.element)
    return distributeEvenly(sorted).map(\.key)
  }

  /// stage.js `stageOnMuteStateChange`'s slot flip. A collapsed riff-group panel shows whichever
  /// variant is unmuted; when the group's active variant is not the one the panel shows (an A->B
  /// flip at a section boundary), the panel swaps to it. `nets` is EVERY net of the panel's deck
  /// (not only the eligible ones). Nil: keep the panel's net. Expanded variants never swap: each
  /// variant already owns a panel.
  public static func variantSwap(
    panelNetId: String, riffGroup: String, deck: String, nets: [NetDesc], expandVariants: Bool
  ) -> String? {
    if riffGroup.isEmpty || expandVariants { return nil }
    let active = nets.first { $0.deck == deck && $0.riffGroup == riffGroup && !$0.muted }
    guard let active, active.id != panelNetId else { return nil }
    return active.id
  }

  // MARK: ring

  /// stage.js `layoutRing`, minus the DOM. `width`/`height` are the stage (the window), `count`
  /// the number of panels.
  public static func layoutRing(
    width w: Double, height h: Double, count n: Int, scale: StageScale = .loop
  ) -> StageRingLayout {
    let center = StagePoint(x: w / 2, y: h / 2)
    if n <= 1 {
      // One panel: 68% of the short side, centred. stage.js returns here without setting the
      // ring (no ringX/ringY, no dark planet, no meta-net).
      let side = min(w, h) * 0.68
      return StageRingLayout(
        width: w, height: h, count: n, side: side, radius: 0, center: center,
        panelCenters: n == 1 ? [center] : [], hasRing: false, placeR: nil, placeRadius: nil,
        darkPlanetRadius: nil, placeCenters: [], showsMeta: false)
    }
    // Size each panel so a ring of N squares fits comfortably: 2 panels pair naturally, 3-5 form
    // a tight pentagon, 6+ still leave visible ring negative space.
    let baseFrac = n <= 3 ? 0.42 : n <= 5 ? 0.30 : n <= 8 ? 0.24 : 0.20
    let baseSide = min(w, h) * baseFrac
    // Panels may overlap at high N (and with the big scales): the interleaved sub-nets form a
    // mandala.
    let maxSide = min(w, h) * 0.65
    let side = max(60, min(maxSide, baseSide * scale.multiplier))
    let radius = min(w, h) / 2 - side / 2 - 24
    var panels: [StagePoint] = []
    panels.reserveCapacity(n)
    for i in 0..<n {
      let theta = Double(i) / Double(n) * Double.pi * 2 - Double.pi / 2
      panels.append(
        StagePoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta)))
    }
    // Inner-place ring: each place sits at the midpoint angle between two adjacent transitions,
    // pulled toward the centre so the composition reads as classic Petri net geometry.
    let placeR = max(22, side * 0.12)
    let placeRadius = radius * 0.35
    let dark = max(18, placeRadius - max(22, placeR) - 4)
    var places: [StagePoint] = []
    places.reserveCapacity(n)
    for i in 0..<n {
      let theta = (Double(i) + 0.5) / Double(n) * Double.pi * 2 - Double.pi / 2
      places.append(
        StagePoint(x: center.x + placeRadius * cos(theta), y: center.y + placeRadius * sin(theta)))
    }
    return StageRingLayout(
      width: w, height: h, count: n, side: side, radius: radius, center: center,
      panelCenters: panels, hasRing: true, placeR: placeR, placeRadius: placeRadius,
      darkPlanetRadius: dark, placeCenters: places, showsMeta: n <= maxMetaPanels)
  }
}

// MARK: - one panel's view

/// The bounding box of a net's places and transitions.
public struct StageBounds: Equatable, Sendable {
  public var minX: Double
  public var minY: Double
  public var maxX: Double
  public var maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }
}

/// How a net is fitted into its panel (stage.js `layoutPanel`, mirroring canvas.js `centerNet`):
/// scale to fit with a margin, capped at 1, and centre. The net spins about its own box centre
/// `(cx, cy)`, so a point of the net lands at
/// `origin + translate(tx, ty) * scale * translate(cx, cy) * rotate(angle) * translate(-cx, -cy)`.
public struct StagePanelView: Equatable, Sendable {
  /// Margin round the net inside its box, in net units.
  public static let pad = 40.0
  /// `layoutPanel` measures the panel's box with a floor of 120: a panel smaller than that (high
  /// N, small scale) is laid out in a 120-point box anchored at its top-left corner, so its net
  /// sits off-centre. Kept as it is.
  public static let minContent = 120.0

  public var scale: Double
  public var tx: Double
  public var ty: Double
  public var cx: Double
  public var cy: Double

  public init(scale: Double, tx: Double, ty: Double, cx: Double, cy: Double) {
    self.scale = scale
    self.tx = tx
    self.ty = ty
    self.cx = cx
    self.cy = cy
  }

  /// The side of the box a panel of `side` points is laid out in.
  public static func contentSize(side: Double) -> Double { max(minContent, side) }

  /// `layoutPanel`'s bounding box + fit for a box of `width` x `height` (already floored).
  public static func fit(bounds b: StageBounds, width: Double, height: Double) -> StagePanelView {
    let netW = b.maxX - b.minX + pad * 2
    let netH = b.maxY - b.minY + pad * 2
    let scale = min(1, width / netW, height / netH)
    let cx = (b.minX + b.maxX) / 2
    let cy = (b.minY + b.maxY) / 2
    return StagePanelView(
      scale: scale, tx: width / 2 - cx * scale, ty: height / 2 - cy * scale, cx: cx, cy: cy)
  }

  /// Where the net point `(x, y)` lands inside the panel's box when the net is turned by
  /// `angleDegrees` (the panel's flow angle). stage.js `nodeCenterInStage`, without the box's own
  /// offset.
  public func apply(x: Double, y: Double, angleDegrees: Double) -> StagePoint {
    let a = angleDegrees * Double.pi / 180
    let dx = x - cx
    let dy = y - cy
    let rx = dx * cos(a) - dy * sin(a) + cx
    let ry = dx * sin(a) + dy * cos(a) + cy
    return StagePoint(x: rx * scale + tx, y: ry * scale + ty)
  }
}

/// The Stage's frame caps by visual level (stage.js `STAGE_MIN_FRAME_MS`): every frame at level
/// 0, then 30 / 15 / 4 fps. (The scopes' table differs: `ScopeFramePacer`.)
public enum StageFramePacer {
  /// Seconds between frames at levels 0...3 (0: as fast as the display goes).
  public static let minIntervals: [Double] = [0, 1.0 / 30, 1.0 / 15, 1.0 / 4]

  public static func minInterval(level: Int) -> Double {
    minIntervals[min(max(level, 0), minIntervals.count - 1)]
  }

  /// At visual level 2 and up ("minimal"), per-fire flashes and pulses are skipped
  /// (`onRemoteTransitionFired`: `flashes = vizLevel < 2`).
  public static func showsFireEffects(level: Int) -> Bool { level < 2 }
}
