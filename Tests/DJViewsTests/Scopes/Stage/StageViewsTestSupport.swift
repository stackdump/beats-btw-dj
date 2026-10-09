import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// An offline engine with a stage model over it, for the stage's render tests: deck A plays a
/// composed song at 300 BPM (a step is 50 ms), deck B the demo loop. The model's random source
/// is seeded, so panels drift the same way on every run.
@MainActor
final class StageViewRig {
  let dj: DJEngine
  let hub: ScopeHub
  let model: StageModel
  let width: Double
  let height: Double
  /// The model's wall clock, advanced by `run`.
  private(set) var now = 1000.0

  init(
    genre: String = "techno", seed: Double = 42, structure: String = "standard",
    source: ScopeSource = .deck("A"), width: Double = 1000, height: Double = 800,
    play: Bool = true
  ) throws {
    dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: genre, seed: seed, structure: structure), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.wave.setTempo(300)
    if play {
      dj["A"]!.setPlaying(true)
      dj["B"]!.setPlaying(true)
    }
    hub = ScopeHub(engine: dj)
    var rng = StageSeededRandom(seed: 7)
    model = StageModel(hub: hub, random: { rng.next() })
    model.settings.source = source
    self.width = width
    self.height = height
    try dj.start()
    model.attach()
  }

  /// Render `seconds` of audio in `step`-second blocks, advancing the model after each as the
  /// timeline would (wall clock and audio clock together).
  func run(seconds: Double, step: Double = 0.05) throws {
    var left = seconds
    while left > 1e-9 {
      let s = min(step, left)
      try renderOffline(dj, frames: Int((s * 22_050).rounded()))
      now += s
      model.advance(now: now, dt: s, width: width, height: height)
      left -= s
    }
  }

  func stop() {
    model.detach()
    dj.stop()
  }

  /// The scene of the last frame, in a window-sized frame.
  func scene(helpOpen: Bool = false) -> some View {
    StageScene(model: model, context: model.context, helpOpen: .constant(helpOpen))
  }
}

/// A failed `#expect(px.near(...))` prints every sub-expression: without this it dumps the
/// whole RGBA buffer (megabytes) into the log.
extension Pixels: CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "Pixels(\(width)x\(height))" }
  var debugDescription: String { description }
}

/// Colours and pixel probes of the stage tests, namespaced so a sibling test file with its own
/// helpers can never collide with them.
enum StageSwatch {
  static let background = (10, 10, 26)  // #0a0a1a
  static let arcBlue = (74, 144, 217)  // #4a90d9
  static let fill = (26, 26, 46)  // #1a1a2e
  static let red = (233, 69, 96)  // #e94560
  static let midiFill = (45, 31, 61)  // #2d1f3d

  /// `fg` at `alpha` over `bg`, as 8-bit channels (what a translucent stroke leaves).
  static func blend(_ fg: (Int, Int, Int), _ alpha: Double, over bg: (Int, Int, Int))
    -> (Int, Int, Int)
  {
    func mix(_ f: Int, _ b: Int) -> Int { Int((Double(b) + alpha * Double(f - b)).rounded()) }
    return (mix(fg.0, bg.0), mix(fg.1, bg.1), mix(fg.2, bg.2))
  }

  /// Is there any pixel near `c` within `r` points of (x, y)?
  static func anyNear(
    _ px: Pixels, _ x: Int, _ y: Int, r: Int, _ c: (Int, Int, Int), tol: Int = 30
  ) -> Bool {
    for yy in max(0, y - r)...min(px.height - 1, y + r) {
      for xx in max(0, x - r)...min(px.width - 1, x + r) where px.near(xx, yy, c, tol: tol) {
        return true
      }
    }
    return false
  }

  static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

  static func near(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
    near(p.x, x, tol) && near(p.y, y, tol)
  }

  static func ipt(_ p: StagePoint) -> (Int, Int) { (Int(p.x.rounded()), Int(p.y.rounded())) }

  /// The largest value of channel `channel` (0 r, 1 g, 2 b) over the pixels along the segment: a
  /// line of full coverage somewhere on it shows its exact colour there, whatever the
  /// anti-aliasing does elsewhere.
  static func peak(
    _ px: Pixels, channel: Int, from a: StagePoint, to b: StagePoint, trim: Double = 0.2
  ) -> Int {
    var best = 0
    let steps = 400
    for i in 0...steps {
      let t = trim + (1 - 2 * trim) * Double(i) / Double(steps)
      let x = Int((a.x + (b.x - a.x) * t).rounded(.down))
      let y = Int((a.y + (b.y - a.y) * t).rounded(.down))
      guard x >= 0, y >= 0, x < px.width, y < px.height else { continue }
      let c = px.color(x, y)
      best = max(best, channel == 0 ? c.r : channel == 1 ? c.g : c.b)
    }
    return best
  }
}

/// A one-panel stage with a hand-made net, for the pixel-exact paint tests. The panel is the lone
/// panel of a 600 x 600 stage (side 408, centred at (300, 300)); the net fits at scale 1, so a net
/// point (x, y) lands at stage (301 + x, 301 + y): the panel's corner plus its 1 point border.
///
///   places       P0 (0, -80)  and P1 (0, 80)
///   transitions  T0 (-80, 0) with a note,  T1 (80, 0) without
///   arcs         P0 -> P1 (a vertical line at x = 301 with its head near P1)
@MainActor
struct SyntheticStage {
  static let size = 600
  /// Net (0, 0) in stage coordinates.
  static let origin = (x: 301, y: 301)

  let model: StageModel
  let context: StageContext
  let panel: StagePanel

  init(
    tokens: [Double] = [0, 0], firedAt: [Double] = [-.infinity, -.infinity], audioNow: Double = 10,
    angle: Double = 0, scaleSide: Double? = nil, showBacks: Bool = false, showLabels: Bool = false,
    metaRotation: Double = 0, panels: Bool = true, hasNet: Bool = true,
    source: ScopeSource = .deck("A")
  ) throws {
    let shape = StageNetShape(
      netId: "n", placeIds: ["p0", "p1"], placeX: [0, 0], placeY: [-80, 80],
      transitionIds: ["t0", "t1"], transitionX: [-80, 80], transitionY: [0, 0],
      transitionHasMidi: [true, false],
      arcs: [NetInfo.NetArcGeometry(x1: 0, y1: -80, x2: 0, y2: 80)])
    let layout = StagePanelLayout.layoutRing(
      width: Double(Self.size), height: Double(Self.size), count: panels ? 1 : 0)
    let content = StagePanelView.contentSize(side: scaleSide ?? layout.side)
    let view = StagePanelView.fit(bounds: shape.bounds!, width: content, height: content)
    panel = StagePanel(
      id: "A/n", deck: "A", netId: "n", label: "Net", channel: 1, riffGroup: "",
      center: layout.center, ring: nil, side: layout.side, angle: angle, view: view, muted: false,
      opacity: 1, shape: shape, tokens: tokens, firedAt: firedAt)
    context = StageContext(
      width: Double(Self.size), height: Double(Self.size), layout: layout,
      panels: panels ? [panel] : [], audioNow: audioNow, hasNet: hasNet, source: source,
      metaRotation: metaRotation, showBacks: showBacks, showLabels: showLabels)
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    model = StageModel(hub: ScopeHub(engine: dj))
  }

  var scene: some View { StageScene(model: model, context: context) }

  func pixels() throws -> Pixels {
    try #require(renderPixels(scene, width: Self.size, height: Self.size))
  }

  /// The stage position of net point (x, y).
  static func at(_ x: Int, _ y: Int) -> (Int, Int) { (origin.x + x, origin.y + y) }
}
