import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 22 on screen: the arc layer dims while playing and turns with the Auto-DJ swing,
// and the last-fired step keeps its #ffd36a ring after the flash has faded.
@MainActor
struct RingExtrasRenderTests {
  func ring(lastFired: Int = 0, phase: Double = 0, muted: Bool = false) -> RingView {
    RingView(
      id: "kick", role: "kick", size: 4, hits: [true, false, true, false],
      velocities: [100, 0, 127, 0], token: 1, lastFired: lastFired, phase: phase, muted: muted)
  }

  /// A ring of `n` resting dots (nothing hit, so nothing but the extras is drawn).
  func bare(size n: Int, token: Int = 1, lastFired: Int = -1, muted: Bool = false) -> RingView {
    RingView(
      id: "k", role: "k", size: n, hits: [Bool](repeating: false, count: n),
      velocities: [Int](repeating: 0, count: n), token: token, lastFired: lastFired, phase: 0.99,
      muted: muted)
  }

  /// The four steps of a 4-ring in a 100 pt square: top, right, bottom, left (inset 15: room
  /// for the playhead's glow, `RingGeometry.inset`).
  func at(_ i: Int) -> CGPoint { RingGeometry.position(i, of: 4, size: 100) }
  /// The ring's radius in that square: 35 pt.
  var ringRadius: Double { Double(at(1).x) - 50 }

  func render(_ arcs: RingArcs?, ring r: RingView? = nil) throws -> Pixels {
    try #require(
      renderPixels(
        RingNetView(ring: r ?? ring(), tint: .orange, arcs: arcs), width: 100, height: 100))
  }

  func renderScaled(
    _ arcs: RingArcs?, ring r: RingView, side: Int = 100, scale: Int = 4
  ) throws -> Pixels {
    try #require(
      renderPixelsScaled(
        RingNetView(ring: r, tint: .orange, arcs: arcs), width: side, height: side, scale: scale))
  }

  @Test func withoutArcsTheRingIsDotsOnly() throws {
    let px = try render(nil)
    // the midpoint of the chord from step 0 to step 1 is empty
    #expect(px.color(Int(chordMid.x), Int(chordMid.y)).a == 0)
  }

  /// The chord from the top dot (50, 15) to the right dot (85, 50) of a 4-ring in 100 pt: its
  /// midpoint (67.5, 32.5), and the direction across it.
  var chordMid: (x: Double, y: Double) {
    (Double(at(0).x + at(1).x) / 2, Double(at(0).y + at(1).y) / 2)
  }
  let across = (x: 0.7071067811865476, y: -0.7071067811865476)

  @Test func arcsAreDimAndThinWhilePlayingAndFullWhenStopped() throws {
    let stopped = try renderScaled(RingArcs(playing: false), ring: ring())
    let playing = try renderScaled(RingArcs(playing: true), ring: ring())
    func peak(_ px: Pixels) -> Int {
      px.peakAlpha(acrossAt: chordMid, direction: across, half: 3, scale: 4)
    }
    func width(_ px: Pixels, atLeast level: Int) -> Double {
      px.widthAtOrAbove(level, acrossAt: chordMid, direction: across, half: 3, scale: 4)
    }
    // stopped: alpha 1 on a 2 pt line
    #expect(peak(stopped) >= 250, "stopped: \(peak(stopped))")
    #expect(abs(width(stopped, atLeast: 128) - 2) < 0.5, "\(width(stopped, atLeast: 128)) pt wide")
    // playing: alpha 0.3 (76 of 255, give or take rounding) on a 1 pt line
    #expect(peak(playing) >= 68 && peak(playing) <= 85, "playing: \(peak(playing))")
    #expect(abs(width(playing, atLeast: 38) - 1) < 0.5, "\(width(playing, atLeast: 38)) pt wide")
    // the stroke is #4a90d9
    let px = stopped
    #expect(px.near(Int(chordMid.x * 4), Int(chordMid.y * 4), (74, 144, 217), tol: 30))
  }

  @Test func aMutedRingsArcsAreAsFaintAsItsDots() throws {
    let loud = try renderScaled(RingArcs(playing: false), ring: ring(muted: false))
    let muted = try renderScaled(RingArcs(playing: false), ring: ring(muted: true))
    let a = loud.peakAlpha(acrossAt: chordMid, direction: across, half: 3, scale: 4)
    let b = muted.peakAlpha(acrossAt: chordMid, direction: across, half: 3, scale: 4)
    #expect(a >= 250)
    #expect(b >= 80 && b <= 98, "0.35 of full: \(b)")
  }

  @Test func theDotsAreNotDimmedByThePlayingArcs() throws {
    let stopped = try render(RingArcs(playing: false))
    let playing = try render(RingArcs(playing: true))
    // the hit at step 2 (bottom) keeps the tint in both
    let p = at(2)
    #expect(stopped.color(Int(p.x), Int(p.y)).r > 220)
    #expect(playing.color(Int(p.x), Int(p.y)).r > 220)
  }

  @Test func theArcLayerTurnsAboutTheCentre() throws {
    // At 45 degrees the diamond of chords becomes a square: its right edge is x = 50 + R cos 45
    // (74.7 for R = 35), and the chord midpoint (67.5, 32.5) is off the arcs.
    let edge = Int((50 + ringRadius * 0.5.squareRoot()).rounded())
    let (mx, my) = (Int(chordMid.x), Int(chordMid.y))
    let px = try render(RingArcs(playing: false, angleDegrees: 45))
    #expect(px.color(edge, 50).a > 150, "the turned chord passes (\(edge), 50)")
    #expect(px.color(mx, my).a < 60, "and has left (\(mx), \(my)): \(px.color(mx, my))")
    // a quarter turn maps a regular 4-ring onto itself
    let quarter = try render(RingArcs(playing: false, angleDegrees: 90))
    #expect(quarter.color(mx, my).a > 150)
  }

  /// A triangle is not turned onto itself by 30 degrees either way, so the direction shows.
  /// Its corners start at 12, 4 and 8 o'clock; turned 30 degrees clockwise they sit at 1, 5 and
  /// 9, so a chord runs straight down at x = 50 + R/2 (corners at 30 and 150 degrees) and none
  /// runs at x = 50 - R/2. Counter-clockwise it is the other way round.
  @Test func theSwingTurnsClockwiseForAPositiveAngle() throws {
    let tri = bare(size: 3)
    let r = Double(RingGeometry.position(0, of: 3, size: 100).y)
    let (right, left) = (Int(50 + (50 - r) / 2), Int(50 - (50 - r) / 2))  // the pixel holding x
    func lit(_ angle: Double, _ x: Int, _ y: Int) throws -> Int {
      try render(RingArcs(playing: false, angleDegrees: angle), ring: tri).color(x, y).a
    }
    #expect(try lit(30, right, 50) > 200, "+30: the chord at x = \(right)")
    #expect(try lit(30, left, 50) < 30, "+30: nothing at x = \(left)")
    #expect(try lit(-30, left, 50) > 200, "-30: the chord at x = \(left)")
    #expect(try lit(-30, right, 50) < 30, "-30: nothing at x = \(right)")
  }

  /// 3 steps in 100 pt: chords of 76 pt, long enough for heads (wings of 4 pt, tips set back
  /// 7 pt from the target dot). Chord 0 runs from the top corner (50, 6) to (88.1, 72).
  @Test func arrowheadsSitAtTheTargetEndAndFlipWithTheDirectionFlag() throws {
    let tri = bare(size: 3)
    let a = RingGeometry.position(0, of: 3, size: 100)
    let b = RingGeometry.position(1, of: 3, size: 100)
    let (pa, pb) = ((x: Double(a.x), y: Double(a.y)), (x: Double(b.x), y: Double(b.y)))
    // 85 % of the way to each wing's end: past the chord's own edge, so only a wing lights it
    let atB = arrowheadWingPoints(from: pa, to: pb, setBack: 7, length: 4, fraction: 0.85)
    let atA = arrowheadWingPoints(from: pb, to: pa, setBack: 7, length: 4, fraction: 0.85)
    let forward = try renderScaled(RingArcs(playing: false), ring: tri)
    let reversed = try renderScaled(RingArcs(playing: false, reverseArrows: true), ring: tri)
    for w in atB {
      #expect(forward.alpha(atPoint: w.x, w.y, scale: 4) > 200, "head at the target end")
      #expect(reversed.alpha(atPoint: w.x, w.y, scale: 4) < 60, "none there when reversed")
    }
    for w in atA {
      #expect(reversed.alpha(atPoint: w.x, w.y, scale: 4) > 200, "reversed: head at the source")
      #expect(forward.alpha(atPoint: w.x, w.y, scale: 4) < 60, "none there going forward")
    }
  }

  @Test func aRingTooSmallForHeadsDrawsNoneWhateverTheDirection() throws {
    // 16 steps in 66 pt: a head would land on the dots (RingArcs.headLength is nil)
    let r = bare(size: 16)
    func render66(_ arcs: RingArcs) throws -> Pixels {
      try #require(
        renderPixels(RingNetView(ring: r, tint: .orange, arcs: arcs), width: 66, height: 66))
    }
    let fwd = try render66(RingArcs(playing: false))
    let back = try render66(RingArcs(playing: false, reverseArrows: true))
    #expect(fwd.rgba == back.rgba, "no arrowheads, so the flag changes nothing")
    // while 8 steps in 100 pt carry them: the flag moves them
    let eight = bare(size: 8)
    let f8 = try render(RingArcs(playing: false), ring: eight)
    let b8 = try render(RingArcs(playing: false, reverseArrows: true), ring: eight)
    #expect(f8.rgba != b8.rgba)
  }

  @Test func theLastFiredStepKeepsItsGoldRingAfterTheFlashFades() throws {
    let rp = RingPlayhead.radius(base: 5)
    let p = at(0)
    func gold(_ px: Pixels) -> Bool {
      px.near(Int(p.x + rp), Int(p.y), RingPlayhead.rgb8, tol: 25)
    }
    #expect(gold(try render(nil, ring: ring(lastFired: 0, phase: 0))), "flash at full")
    #expect(gold(try render(nil, ring: ring(lastFired: 0, phase: 0.99))), "flash gone, ring stays")
    // it moves with the fire
    let moved = try render(nil, ring: ring(lastFired: 2, phase: 0.99))
    let q = at(2)
    #expect(moved.near(Int(q.x + rp), Int(q.y), RingPlayhead.rgb8, tol: 25))
    #expect(!moved.near(Int(p.x + rp), Int(p.y), RingPlayhead.rgb8, tol: 25))
    // nothing fired yet: no ring
    let none = try render(nil, ring: ring(lastFired: -1))
    #expect(!none.near(Int(p.x + rp), Int(p.y), RingPlayhead.rgb8, tol: 25))
  }

  /// The playhead of a 4-ring in 120 pt, at step 0 (60, 15), dot base 5: a ring of radius
  /// 9.5 pt drawn 3/20 of that thick (1.425 pt), with a 0.7 glow outside and a 0.35 ramp inside.
  /// Looked at on the lower half of the ring, at 4 pixels to the point (the arc layer and the
  /// next steps stay clear of it there).
  func playheadProfile() throws -> Pixels {
    try renderScaled(nil, ring: bare(size: 4, token: 2, lastFired: 0), side: 120)
  }
  var playheadCentre: (x: Double, y: Double) {
    let p = RingGeometry.position(0, of: 4, size: 120)
    return (Double(p.x), Double(p.y))
  }

  func meanAlpha(_ px: Pixels, at r: Double) -> Double {
    px.meanAlpha(
      onCircleAround: playheadCentre, radius: r, from: 0.15, to: Double.pi - 0.15, scale: 4)
  }

  @Test func theGoldRingIsThreeTwentiethsOfItsRadiusThick() throws {
    let px = try playheadProfile()
    // the radial run of (nearly) opaque alpha: 1.425 pt = 5.7 px, less the soft edges
    var n = 0
    var r = 6.0
    while r < 13 {
      if meanAlpha(px, at: r) >= 0.97 * 255 { n += 1 }
      r += 0.25
    }
    let width = Double(n) * 0.25
    #expect(width >= 1.0 && width <= 1.9, "ring is \(width) pt thick (CSS 3 px of 20: 1.425)")
  }

  @Test func theGoldRingGlowsOutsideAndRampsUpInside() throws {
    let px = try playheadProfile()
    // 1 pt either side of the ring's centre line, past the 0.7 pt half-stroke: the glow's
    // shadow is the same on both sides, the inside has the 0.35 ramp on top
    let outside = meanAlpha(px, at: 9.5 + 1.0)
    let inside = meanAlpha(px, at: 9.5 - 1.0)
    // outer: sigma 1.425 pt, alpha 0.7: about 55 of 255 a point out
    #expect(outside > 35 && outside < 80, "outer glow: \(outside)")
    // inner: the ramp adds 0.35 * (1.1 / 1.9) = 0.2 over what the shadow gives
    #expect(inside - outside > 20, "inner glow adds to the shadow: \(inside) vs \(outside)")
    // and the glow is narrow: three points out there is nothing
    #expect(meanAlpha(px, at: 9.5 + 4.5) < 8, "no wide halo (CSS 6 px blur)")
  }

  @Test func theGridPassesTheArcsToEveryRing() throws {
    let rings = ["kick", "snare"].map {
      RingView(
        id: $0, role: $0, size: 4, hits: [true, false, true, false], velocities: [100, 0, 127, 0],
        token: 1, lastFired: -1, phase: 0, muted: false)
    }
    let view = NetRingsView(
      snapshot: NetSnapshot(tick: 0, rings: rings), tint: .orange, arcs: RingArcs(playing: false))
    savePNG(view, width: 320, height: 90, name: "ring-extras-grid")
    let px = try #require(renderPixels(view, width: 320, height: 90))
    let blue = px.count(inX: 0..<320, y: 0..<90) { r, g, b in b > 150 && r < 120 && g > 100 }
    #expect(blue > 100, "arcs are drawn in both rings: \(blue)")
  }

  @Test func humanLook() throws {
    let r = RingView(
      id: "k", role: "k", size: 16,
      hits: (0..<16).map { $0 % 4 == 0 },
      velocities: (0..<16).map { $0 % 4 == 0 ? 110 : 0 }, token: 6, lastFired: 5, phase: 0.2,
      muted: false)
    let row = HStack(spacing: 8) {
      RingNetView(ring: r, tint: .orange)
      RingNetView(ring: r, tint: .orange, arcs: RingArcs(playing: false))
      RingNetView(ring: r, tint: .orange, arcs: RingArcs(playing: true))
      RingNetView(ring: r, tint: .orange, arcs: RingArcs(playing: false, angleDegrees: 30))
    }.padding(8).background(Color.black)
    savePNG(row, width: 560, height: 150, name: "ring-extras-look")
    #expect(renderPixels(row, width: 560, height: 150) != nil)
  }
}

/// The hand-over of a deck to its next track, through the app model's poll.
@MainActor
struct RingSwingAppTests {
  @Test func aHandOverSwingsTheDecksRingAndPlayingDimsIt() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true  // queueNext composes inline
    let a = try #require(dj["A"])
    a.loadNet(PreparedTrack(spec: TrackSpec(genre: "techno", seed: 1), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    var clock = 100.0
    let m = AppModel(engine: dj)
    m.uptime = { clock }
    m.start()  // polls once: the first look only records the count
    func arcs() -> RingArcs { m.decks["A"]?.ringArcs ?? RingArcs() }
    #expect(arcs().angleDegrees == 0 && !arcs().playing)

    a.queueNext(TrackSpec(genre: "house", seed: 2, structure: "minimal"))
    #expect(a.advanceToNext())
    clock = 101
    m.poll()
    #expect(arcs().angleDegrees == 0, "the swing starts at this poll")
    clock = 101.4
    m.poll()
    #expect(abs(arcs().angleDegrees - 78.75) < 1e-9, "400 ms in: 90 * eased(0.5)")
    clock = 101.8
    m.poll()
    #expect(abs(arcs().angleDegrees - 90) < 1e-9)
    clock = 120
    m.poll()
    #expect(abs(arcs().angleDegrees - 90) < 1e-9, "and it stays")
    #expect(!arcs().reverseArrows)

    // the next hand-over swings back, arrows reversed
    a.queueNext(TrackSpec(genre: "dnb", seed: 3))
    #expect(a.advanceToNext())
    clock = 121
    m.poll()
    clock = 121.8
    m.poll()
    #expect(abs(arcs().angleDegrees) < 1e-9 && arcs().reverseArrows)

    // playing dims the arcs
    a.setPlaying(true)
    m.poll()
    #expect(arcs().playing && arcs().alpha == 0.3)
    a.setPlaying(false)
    m.poll()
    #expect(!arcs().playing && arcs().alpha == 1)
    // a sample deck has no ring: nothing is tracked for it
    #expect(m.decks["B"]?.ringArcs == RingArcs())
  }
}
