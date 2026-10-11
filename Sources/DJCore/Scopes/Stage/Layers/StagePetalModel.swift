import Foundation

// StagePetalModel: SPEC mode 11, the petal (stage.js `renderPetal`, and the petal branch of
// `stageOnTransitionFired`). Each panel is one petal of a flower, at a fixed angle round the ring;
// every fire on its net spikes the petal's energy, which decays smoothly, so the flower's breathing
// is the arrangement.
//
//   fire    energy = min(1, energy + 0.45)                     (per net)
//   frame   energy *= exp(-2.3 * dt); gone below 0.005         (dt in seconds)
//   petal i of n   angle i/n * 2π - π/2; e = sqrt(energy)
//           len        baseR + (maxR - baseR) * (0.18 + 0.95 e)       baseR 8 %, maxR 42 % of min(w, h)
//           halfWidth  (π/n) * (0.45 + 0.5 e)
//           outline    moveTo(centre), quad(ctrl at angle - halfWidth, radius (baseR + len) * 0.55, tip),
//                      quad(ctrl at angle + halfWidth, ..., centre)
//
// The energy is kept per NET (deck and net id: beats has one project, the stage here can show two
// decks), so a riff-group panel that flips to another variant shows that variant's own energy, as
// the JS does.

/// A net's identity for the energy map: net ids are only unique within one deck's project.
public struct PetalKey: Hashable, Sendable {
  public var deck: String
  public var netId: String

  public init(deck: String, netId: String) {
    self.deck = deck
    self.netId = netId
  }
}

/// One petal, as it is drawn.
public struct PetalShape: Equatable, Sendable {
  public var hue: Double
  /// The raw energy 0...1 and its square root (what the shape reads).
  public var raw: Double
  public var energy: Double
  public var angle: Double
  public var center: StagePoint
  public var baseRadius: Double
  public var length: Double
  public var halfWidth: Double
  public var tip: StagePoint
  /// The quadratic curves' control points: left (`angle - halfWidth`) and right.
  public var left: StagePoint
  public var right: StagePoint
  /// The fill is `createRadialGradient(centre, baseR * 0.5, tip, len)`: a two-circle (conical)
  /// gradient from the centre to a circle of radius `length` AROUND THE TIP.
  public var gradientStartRadius: Double
  public var gradientEndRadius: Double
  /// `hsla(hue, 80%, 55%, 0.25 + 0.55 e)` at stop 0, `hsla(hue, 95%, 65%, 0.05 + 0.25 e)` at 1.
  public var fillInner: ScopeColor
  public var fillOuter: ScopeColor
  /// The outline: `hsla(hue, 95%, 70%, 0.4 + 0.5 e)`, width `1 + 2.5 e`.
  public var outline: ScopeColor
  public var lineWidth: Double
  /// Its glow: `hsla(hue, 95%, 60%, 0.6 e)`, blur `4 + 14 e`.
  public var shadow: ScopeColor
  public var shadowBlur: Double
  /// stage.js sets the shadow state AFTER filling a petal and never clears it inside the loop, so
  /// the NEXT petal's fill is drawn with this one's glow (the first petal's has none). Kept as
  /// the JS has it: the fill of petal i carries petal i-1's `shadow` and `shadowBlur`.
  public var fillShadow: ScopeColor?
  public var fillShadowBlur: Double
}

/// The petals' energies and the numbers of a petal.
public struct StagePetals: Equatable, Sendable {
  /// `Math.min(1, prev + 0.45)`.
  public static let bump = 0.45
  /// `Math.exp(-dt * 2.3)`: halves every 301 ms.
  public static let decayRate = 2.3
  /// Below this an energy is dropped.
  public static let floor = 0.005
  /// `baseR = min(w, h) * 0.08`, `maxR = min(w, h) * 0.42`.
  public static let baseFraction = 0.08
  public static let maxFraction = 0.42

  public private(set) var energy: [PetalKey: Double] = [:]

  public init() {}

  /// A fire on a net.
  public mutating func fire(_ key: PetalKey) {
    energy[key] = min(1, (energy[key] ?? 0) + Self.bump)
  }

  /// One frame of decay, `dt` in seconds.
  public mutating func decay(dt: Double) {
    let factor = exp(-dt * Self.decayRate)
    for (key, value) in energy {
      let next = value * factor
      if next < Self.floor {
        energy[key] = nil
      } else {
        energy[key] = next
      }
    }
  }

  public func raw(_ key: PetalKey) -> Double { energy[key] ?? 0 }

  /// `setVisualizer`: leaving and returning starts fresh.
  public mutating func reset() { energy.removeAll() }

  /// Petal `i` of `n` at raw energy `raw`.
  public static func shape(
    index i: Int, count n: Int, raw: Double, hue: Double, center c: StagePoint, width: Double,
    height: Double
  ) -> PetalShape {
    let short = min(width, height)
    let baseR = short * baseFraction
    let maxR = short * maxFraction
    let angle = Double(i) / Double(n) * 2 * Double.pi - Double.pi / 2
    let e = raw.squareRoot()
    let len = baseR + (maxR - baseR) * (0.18 + e * 0.95)
    let half = (Double.pi / Double(n)) * (0.45 + e * 0.5)
    let ctrlR = (baseR + len) * 0.55
    func point(_ a: Double, _ r: Double) -> StagePoint {
      StagePoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }
    return PetalShape(
      hue: hue, raw: raw, energy: e, angle: angle, center: c, baseRadius: baseR, length: len,
      halfWidth: half, tip: point(angle, len), left: point(angle - half, ctrlR),
      right: point(angle + half, ctrlR), gradientStartRadius: baseR * 0.5,
      gradientEndRadius: len, fillInner: .hsla(hue, 80, 55, 0.25 + e * 0.55),
      fillOuter: .hsla(hue, 95, 65, 0.05 + e * 0.25),
      outline: .hsla(hue, 95, 70, 0.4 + e * 0.5), lineWidth: 1 + e * 2.5,
      shadow: .hsla(hue, 95, 60, e * 0.6), shadowBlur: 4 + e * 14, fillShadow: nil,
      fillShadowBlur: 0)
  }

  /// Every petal of the ring, in panel order (the order they are drawn in), with the previous
  /// petal's glow on each fill as the JS leaves it. `channels` and `keys` are per panel.
  public func shapes(
    channels: [Int], keys: [PetalKey], center: StagePoint, width: Double, height: Double
  ) -> [PetalShape] {
    let n = min(channels.count, keys.count)
    var out: [PetalShape] = []
    out.reserveCapacity(n)
    for i in 0..<n {
      var p = Self.shape(
        index: i, count: n, raw: raw(keys[i]), hue: ScopeColors.channelHue(channels[i]),
        center: center, width: width, height: height)
      if let before = out.last {
        p.fillShadow = before.shadow
        p.fillShadowBlur = before.shadowBlur
      }
      out.append(p)
    }
    return out
  }
}
