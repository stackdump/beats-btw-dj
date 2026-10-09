import DJCore
import SwiftUI
import Testing

@testable import DJViews

// The raster is drawn as a bitmap of the static layer (RasterImage) plus a per-frame playhead.
// These tests render the leaf drawing over hand-made scenes whose pixels are worked out by hand
// (W 1088, three 40 px lanes, 256 steps: x = 64 + 4·step), then the whole ScopeRasterView over a
// real offline engine with the layout chosen so every event lands on whole pixels.

private let bg = (5, 10, 20)  // #050a14
private let grid = (26, 42, 58)  // #1a2a3a
private let barLine = (47, 74, 106)  // #2f4a6a
private let section = (233, 69, 96)  // #e94560
private let textGrey = (136, 153, 170)  // #8899aa
private let kickRed = (233, 69, 96)  // #e94560
private let bassBlue = (74, 144, 217)  // #4a90d9
private let leadGreen = (46, 204, 113)  // #2ecc71

private func lane(_ key: String, drum: Bool, lo: Int, hi: Int, hex: String) -> ScopeLane {
  ScopeLane(
    key: key, ids: [key], channel: drum ? 10 : 1, group: drum ? "drums" : "main", drum: drum,
    instrument: "", notes: [], durationsMs: [], lo: lo, hi: hi, color: ScopeColor(hex: hex)!,
    deck: "A")
}

private let threeLanes = [
  lane("kick", drum: true, lo: 36, hi: 36, hex: "#e94560"),
  lane("bass", drum: false, lo: 36, hi: 48, hex: "#4a90d9"),
  lane("lead", drum: false, lo: 48, hi: 72, hex: "#2ecc71"),
]

private struct Ev {
  var step: Int
  var lane: Int
  var note: Int = 60
  var vel: Int = 100
  var dur: Float = 1
}

private func scene(
  id: Int, steps: Int = 256, lanes: [ScopeLane] = threeLanes, events: [Ev] = [],
  loop: Bool = false, cycle: Int = 0, failed: Bool = false, sections: [ScopeSection] = []
) -> RasterScene {
  var r = failed ? RasterResult.failure("boom") : RasterResult(steps: steps)
  r.loop = loop
  r.cycle = cycle
  for e in events {
    r.step.append(Int32(e.step))
    r.lane.append(UInt8(e.lane))
    r.note.append(UInt8(e.note))
    r.vel.append(UInt8(e.vel))
    r.dur.append(e.dur)
  }
  return RasterScene(result: r, lanes: lanes, sections: sections, id: id)
}

private let events: [Ev] = [
  Ev(step: 16, lane: 0, note: 36, vel: 127),  // kick spike at x 128
  Ev(step: 32, lane: 1, note: 42, vel: 100, dur: 8),  // bass note, 8 steps: x 192, 32 wide
  Ev(step: 100, lane: 2, note: 60, vel: 100, dur: 2),  // lead note: x 464, 8 wide
]

private func clock(tick: Int = 0, phase: Double = 0, playing: Bool = false) -> ScopeClock {
  var c = ScopeClock.idle
  c.tick = tick
  c.tickPhase = phase
  c.transport = playing ? .playing : .stopped
  return c
}

/// The leaf drawing in a plain Canvas (no hub, no timeline): background, then `RasterDrawing`.
@MainActor
private struct Plot: View {
  let snapshot: RasterSnapshot
  let cache: RasterImageCache

  var body: some View {
    Canvas { ctx, size in
      MainActor.assumeIsolated {
        ctx.fill(
          Path(CGRect(origin: .zero, size: size)), with: .color(ScopeColors.background.color))
        RasterDrawing.draw(
          into: &ctx, size: size, scale: 1, snapshot: snapshot, cache: cache)
      }
    }
  }
}

@MainActor
private func render(
  _ scene: RasterScene?, message: String? = nil, clock: ScopeClock = clock(), width: Int = 1088,
  height: Int = 148, name: String? = nil
) -> Pixels? {
  let view = Plot(
    snapshot: RasterSnapshot(scene: scene, message: message, clock: clock),
    cache: RasterImageCache())
  if let name { savePNG(view, width: width, height: height, name: name) }
  return renderPixels(view, width: width, height: height)
}

/// Pixels in a box that are closer to `c` than `tol` per channel.
private func count(_ px: Pixels, _ c: (Int, Int, Int), x: Range<Int>, y: Range<Int>, tol: Int = 40)
  -> Int
{
  px.count(inX: x, y: y) { r, g, b in
    abs(r - c.0) <= tol && abs(g - c.1) <= tol && abs(b - c.2) <= tol
  }
}

@MainActor
struct ScopeRasterViewTests {
  // MARK: the static layer, pixel by pixel

  @Test func aHandMadeRasterDrawsEveryPartWhereTheLayoutSaysItGoes() throws {
    let px = try #require(
      render(scene(id: 1, events: events), name: "raster-hand-made"))
    #expect(px.width == 1088 && px.height == 148)
    // background: the gutter between names, the plot between bars
    #expect(px.near(40, 100, bg, tol: 2) && px.near(600, 70, bg, tol: 2))
    #expect(px.near(1000, 5, bg, tol: 2), "above the plot")
    // bar lines: every bar, brighter on the fourth (b = 0, 4, 8 ...)
    #expect(px.near(64, 100, barLine, tol: 3), "bar 0")
    #expect(px.near(128, 100, grid, tol: 3), "bar 1")
    #expect(px.near(192, 100, grid, tol: 3), "bar 2")
    #expect(px.near(320, 100, barLine, tol: 3), "bar 4")
    // the lines run the plot's height: not above it, not into the axis
    #expect(px.near(128, 10, bg, tol: 2) && px.near(128, 140, bg, tol: 40))
    #expect(px.near(128, 14 + 100, grid, tol: 3) && px.near(128, 14 + 119, grid, tol: 3))
    // lane separators: a 1 px grid line at the top of each lane, from the gutter on
    #expect(px.near(600, 14, grid, tol: 3) && px.near(600, 54, grid, tol: 3))
    #expect(px.near(600, 94, grid, tol: 3) && px.near(50, 54, bg, tol: 2))
    // events, in their lane colours: the kick spike (x 128, 32 px up from the floor at 54)
    #expect(px.near(128, 40, kickRed, tol: 3) && px.near(128, 22, kickRed, tol: 3))
    #expect(px.near(128, 20, grid, tol: 3), "one px above its top")
    #expect(px.near(129, 40, bg, tol: 2), "and one px wide")
    // the bass note (x 192..224, rows 73-74) and the lead note (x 464..472, rows 113-114)
    #expect(px.near(200, 73, bassBlue, tol: 3) && px.near(223, 74, bassBlue, tol: 3))
    #expect(px.near(200, 72, bg, tol: 2) && px.near(200, 75, bg, tol: 2))
    #expect(px.near(224, 74, bg, tol: 2), "32 px, not 33")
    #expect(px.near(466, 113, leadGreen, tol: 3) && px.near(471, 114, leadGreen, tol: 3))
    #expect(px.near(472, 113, bg, tol: 2))
    // lane names in the lane colours, in the gutter
    #expect(count(px, kickRed, x: 0..<62, y: 14..<54, tol: 60) > 8, "kick")
    #expect(count(px, bassBlue, x: 0..<62, y: 54..<94, tol: 60) > 8, "bass")
    #expect(count(px, leadGreen, x: 0..<62, y: 94..<134, tol: 60) > 8, "lead")
    // bar numbers under the plot, in the text grey; none above it
    #expect(count(px, textGrey, x: 64..<1088, y: 134..<148, tol: 60) > 30)
    #expect(count(px, textGrey, x: 64..<1088, y: 0..<14, tol: 60) == 0)
    // no loop marker, no section lines
    #expect(count(px, section, x: 60..<70, y: 0..<148, tol: 3) == 0)
  }

  @Test func thePlayheadIsAWhiteColumnAtTheEnginesTickPlusPhase() throws {
    let s = scene(id: 2, events: events)
    // tick 16 + half a tick, playing: x = 64 + 16.5 · 4 = 130
    let px = try #require(render(s, clock: clock(tick: 16, phase: 0.5, playing: true)))
    let head = (205, 206, 208)  // white at 80 % over the background
    #expect(px.near(130, 100, head, tol: 4), "\(px.color(130, 100))")
    #expect(px.near(130, 20, head, tol: 4) && px.near(130, 133, head, tol: 4), "the plot's height")
    #expect(
      px.near(130, 14, (209, 212, 216), tol: 4), "from the top row (over the lane's grid line)")
    #expect(px.near(130, 12, bg, tol: 2) && px.near(130, 140, bg, tol: 40))
    #expect(px.near(131, 100, bg, tol: 2) && px.near(129, 100, bg, tol: 2), "one px wide")
    // stopped at tick 16: it rests at the tick, x = 128 (on the bar line)
    let still = try #require(render(s, clock: clock(tick: 16, phase: 0.5, playing: false)))
    #expect(still.near(128, 100, (209, 212, 216), tol: 4), "white at 80 % over the bar line")
    #expect(still.near(130, 100, bg, tol: 2))
    // stopped at the top: no playhead anywhere in the plot
    let top = try #require(render(s, clock: clock(tick: 0, phase: 0, playing: false)))
    let white = top.count(inX: 64..<1088, y: 14..<134) { r, g, b in r > 150 && g > 150 && b > 150 }
    #expect(white == 0)
    // it wraps with the raster: tick 260 of 256 steps is step 4
    let wrapped = try #require(render(s, clock: clock(tick: 260, phase: 0, playing: true)))
    #expect(wrapped.near(80, 100, head, tol: 4))
  }

  @Test func aLoopRasterMarksItsCycleAtTheLeftEdge() throws {
    let s = scene(
      id: 3, steps: 64, events: [Ev(step: 8, lane: 0, note: 36, vel: 127)], loop: true, cycle: 64)
    let px = try #require(render(s, name: "raster-loop"))
    // 64 steps = 4 bars over 1024 px: 16 steps a bar... x = 64 + 16 · step; marker at 63...64
    #expect(px.near(63, 100, section, tol: 3) && px.near(64, 100, section, tol: 3))
    #expect(px.near(62, 100, bg, tol: 2))
    #expect(px.near(63, 12, section, tol: 3), "from 2 px above the plot")
    #expect(px.near(63, 10, bg, tol: 2))
    // "loop · 4 bar cycle" in the section colour in the top margin
    #expect(count(px, section, x: 66..<300, y: 0..<13, tol: 60) > 20)
    // a spike at step 8: x = 64 + 128
    #expect(px.near(192, 40, kickRed, tol: 3))
  }

  @Test func aLoopWithNoRepeatSaysSo() throws {
    let s = scene(id: 4, steps: 1024, loop: true, cycle: 0)
    let px = try #require(render(s))
    #expect(count(px, section, x: 66..<300, y: 0..<13, tol: 60) > 20)
    // 64 bars over 1024 px: 16 px a bar, a line on each
    #expect(px.near(64 + 16 * 4, 100, barLine, tol: 3) && px.near(64 + 16, 100, grid, tol: 3))
  }

  @Test func sectionsAreMarkedWithTheirNames() throws {
    let s = scene(
      id: 5,
      sections: [
        ScopeSection(step: 0, name: "intro"), ScopeSection(step: 64, name: "verse"),
        ScopeSection(step: 300, name: "after"),
      ])
    let px = try #require(render(s, name: "raster-sections"))
    // verse starts at step 64: x = 64 + 256 = 320, marker at 319...320 from 12 down
    #expect(px.near(319, 100, section, tol: 3) && px.near(320, 100, section, tol: 3))
    #expect(px.near(318, 100, bg, tol: 2))
    #expect(px.near(319, 12, section, tol: 3) && px.near(319, 10, bg, tol: 2))
    #expect(px.near(63, 100, section, tol: 3), "intro at the left edge")
    // names at the top; the section that starts past the end has no marker or name
    #expect(count(px, section, x: 323..<400, y: 0..<13, tol: 60) > 12, "verse")
    #expect(count(px, section, x: 67..<130, y: 0..<13, tol: 60) > 12, "intro")
    #expect(count(px, section, x: 700..<1088, y: 0..<148, tol: 20) == 0, "'after' is past the end")
  }

  @Test func noLanesSaysThereAreNoMusicParts() throws {
    let px = try #require(render(scene(id: 6, lanes: []), height: 100, name: "raster-no-parts"))
    // the text sits at (70, 18) in the plot, in the text grey; nothing else but the grid
    #expect(count(px, textGrey, x: 64..<260, y: 14..<34, tol: 60) > 20)
    #expect(count(px, textGrey, x: 300..<1088, y: 14..<72, tol: 60) == 0)
  }

  @Test func aFailedRasterIsAOneBarGridWithAMessage() throws {
    let px = try #require(render(scene(id: 7, failed: true), name: "raster-failed"))
    #expect(count(px, textGrey, x: 64..<260, y: 14..<34, tol: 60) > 30, "raster unavailable")
    // 16 steps: bars 0 and 1 at the two ends of the plot, the lanes still drawn
    #expect(px.near(64, 100, barLine, tol: 3), "bar 0; bar 1 is at the right edge, off the image")
    #expect(px.near(600, 54, grid, tol: 3))
    // no loop marker on a failure
    #expect(!px.near(63, 100, section, tol: 3))
  }

  @Test func withNoRasterYetTheMessageSitsTopLeft() throws {
    let px = try #require(
      render(nil, message: "computing the arrangement…", height: 120, name: "raster-computing"))
    #expect(count(px, textGrey, x: 6..<200, y: 6..<22, tol: 60) > 30)
    #expect(px.near(600, 60, bg, tol: 2), "nothing else is drawn")
    let none = try #require(render(nil, message: nil, height: 120))
    #expect(none.count(inX: 0..<1088, y: 0..<120) { r, g, b in r + g + b > 80 } == 0)
  }

  // MARK: fractional geometry, antialiasing and text

  @Test func marksOnFractionalPixelsAreAntialiasedLikeACanvasFillRect() throws {
    // 256 steps over 936 px: x = 64 + 3.65625 · step. The kick spike on step 1 is 1 px wide from
    // x 67.65625: .34375 of pixel 67 and .65625 of pixel 68. The bass note on step 32 ends at
    // 181 + 29.25 = 210.25: a quarter of pixel 210.
    let evs = [
      Ev(step: 1, lane: 0, note: 36, vel: 127), Ev(step: 32, lane: 1, note: 42, vel: 100, dur: 8),
    ]
    let px = try #require(render(scene(id: 30, steps: 256, events: evs), width: 1000))
    func mix(_ c: (Int, Int, Int), _ cover: Double) -> (Int, Int, Int) {
      (
        Int((Double(bg.0) + cover * Double(c.0 - bg.0)).rounded()),
        Int((Double(bg.1) + cover * Double(c.1 - bg.1)).rounded()),
        Int((Double(bg.2) + cover * Double(c.2 - bg.2)).rounded())
      )
    }
    #expect(px.near(66, 40, bg, tol: 2), "before the spike")
    #expect(px.near(67, 40, mix(kickRed, 0.34375), tol: 3), "\(px.color(67, 40))")
    #expect(px.near(68, 40, mix(kickRed, 0.65625), tol: 3), "\(px.color(68, 40))")
    #expect(px.near(69, 40, bg, tol: 2), "after it")
    #expect(px.near(209, 73, bassBlue, tol: 3), "the note's last whole pixel")
    #expect(px.near(210, 73, mix(bassBlue, 0.25), tol: 3), "\(px.color(210, 73))")
    #expect(px.near(211, 73, bg, tol: 2))
  }

  @Test func marksThatOverlapInAPixelCompoundLikeSeparateFillRects() throws {
    // 4096 steps over 1024 px: a step is a quarter pixel. Kick spikes on steps 9, 10 and 11 are
    // 1 px wide at x 66.25, 66.5 and 66.75, so pixel 66 is covered by .75, .5 and .25 of them
    // and pixel 67 by .25, .5 and .75. Painted one after the other that is 1 - .25 · .5 · .75 =
    // .90625 of the colour; one fill of the union would be .75 (red 176 instead of 212).
    let evs = [9, 10, 11].map { Ev(step: $0, lane: 0, note: 36, vel: 127) }
    let px = try #require(render(scene(id: 31, steps: 4096, events: evs)))
    func mix(_ c: Int, _ b: Int) -> Int { Int((Double(b) + 0.90625 * Double(c - b)).rounded()) }
    let want = (mix(kickRed.0, bg.0), mix(kickRed.1, bg.1), mix(kickRed.2, bg.2))
    #expect(want.0 == 212)
    #expect(px.near(66, 40, want, tol: 3), "\(px.color(66, 40))")
    #expect(px.near(67, 40, want, tol: 3), "\(px.color(67, 40))")
    #expect(px.near(65, 40, bg, tol: 2) && px.near(68, 40, bg, tol: 2))
  }

  /// The box of ink (pixels that differ from the background by more than 60 in the three
  /// channels' sum) inside the given area: (minX, maxX, minY, maxY).
  private func inkBox(_ px: Pixels, x: Range<Int>, y: Range<Int>) -> (Int, Int, Int, Int)? {
    var box: (Int, Int, Int, Int)?
    for yy in y {
      for xx in x {
        let c = px.color(xx, yy)
        guard abs(c.r - bg.0) + abs(c.g - bg.1) + abs(c.b - bg.2) > 60 else { continue }
        let b = box ?? (xx, xx, yy, yy)
        box = (min(b.0, xx), max(b.1, xx), min(b.2, yy), max(b.3, yy))
      }
    }
    return box
  }

  @Test func textSitsWhereTheLayoutPutsItsTopLeftCorner() throws {
    // The 10 px face has its ascenders a pixel below the label's top and its baseline nine below
    // it (the JS draws with textBaseline = 'top'). A label that moved by two pixels fails.
    let s = scene(id: 32, sections: [ScopeSection(step: 64, name: "verse")])
    let px = try #require(render(s))
    let layout = RasterLayout(width: 1088, height: 148, laneCount: 3, steps: 256)
    func check(_ label: RasterLabel, in area: (Range<Int>, Range<Int>), what: String) throws {
      let box = try #require(inkBox(px, x: area.0, y: area.1), Comment(rawValue: what))
      let x = Int(label.x)
      let y = Int(label.y)
      #expect((x...(x + 3)).contains(box.0), "\(what): left edge \(box.0), label x \(x)")
      #expect(((y + 0)...(y + 3)).contains(box.2), "\(what): top row \(box.2), label y \(y)")
      #expect(((y + 7)...(y + 10)).contains(box.3), "\(what): bottom row \(box.3), label y \(y)")
    }
    // a lane name ("kick": k has an ascender) in its lane's band, x < the gutter
    let kick = layout.laneLabel(0, key: "kick")
    #expect(Int(kick.y) == 29)
    try check(kick, in: (0..<62, 15..<53), what: "kick")
    let bass = layout.laneLabel(1, key: "bass")
    try check(bass, in: (0..<62, 55..<93), what: "bass")
    // a section name at the top, right of its marker (the lowercase x-height starts lower)
    let verse = layout.sectionMarks(s.sections)[0].label
    let vbox = try #require(inkBox(px, x: 323..<400, y: 0..<13))
    #expect(vbox.0 >= Int(verse.x) && vbox.0 <= Int(verse.x) + 3, "verse left \(vbox.0)")
    #expect(vbox.2 >= Int(verse.y) + 2 && vbox.2 <= Int(verse.y) + 6, "verse top \(vbox.2)")
    #expect(vbox.3 >= Int(verse.y) + 7 && vbox.3 <= Int(verse.y) + 10, "verse bottom \(vbox.3)")
    // a bar number under the plot: digits are as tall as capitals
    let one = layout.axisLabels()[0]
    let abox = try #require(inkBox(px, x: 66..<120, y: 134..<148))
    #expect(abox.0 >= Int(one.x) && abox.0 <= Int(one.x) + 3, "bar number left \(abox.0)")
    #expect(abox.2 >= Int(one.y) && abox.2 <= Int(one.y) + 4, "bar number top \(abox.2)")
    #expect(abox.3 >= Int(one.y) + 7 && abox.3 <= Int(one.y) + 10, "bar number bottom \(abox.3)")
  }

  // MARK: the cache

  @Test func theBitmapIsDrawnOnceUntilTheSceneOrTheSizeChanges() throws {
    let cache = RasterImageCache()
    let a = scene(id: 10, events: events)
    let size = CGSize(width: 1088, height: 148)
    let first = cache.image(for: a, size: size, scale: 1)
    #expect(first != nil && first?.width == 1088 && first?.height == 148)
    for _ in 0..<5 { _ = cache.image(for: a, size: size, scale: 1) }
    #expect(cache.builds == 1, "a steady scene is drawn once")
    _ = cache.image(for: a, size: CGSize(width: 1000, height: 148), scale: 1)
    #expect(cache.builds == 2, "a resize")
    let retina = cache.image(for: a, size: CGSize(width: 1000, height: 148), scale: 2)
    #expect(cache.builds == 3 && retina?.width == 2000 && retina?.height == 296, "a new scale")
    _ = cache.image(
      for: scene(id: 11, events: events), size: CGSize(width: 1000, height: 148), scale: 2)
    #expect(cache.builds == 4, "a new scene")
    #expect(cache.image(for: a, size: .zero, scale: 1) == nil, "a zero size draws nothing")
  }

  @Test func aRetinaBitmapKeepsTheSameGeometry() throws {
    let a = scene(id: 12, events: events)
    let image = try #require(
      RasterImage.make(scene: a, size: CGSize(width: 1088, height: 148), scale: 2))
    #expect(image.width == 2176 && image.height == 296)
    // the kick spike at x 128 is 2 device px wide at x 256, rows 2 · 22...
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ok = data.withUnsafeMutableBytes { raw -> Bool in
      guard
        let c = CGContext(
          data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    #expect(ok)
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let i = (y * image.width + x) * 4
      return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    func near(_ p: (Int, Int, Int), _ c: (Int, Int, Int)) -> Bool {
      abs(p.0 - c.0) <= 3 && abs(p.1 - c.1) <= 3 && abs(p.2 - c.2) <= 3
    }
    #expect(near(pixel(256, 80), kickRed) && near(pixel(257, 80), kickRed))
    #expect(near(pixel(258, 80), bg) && near(pixel(255, 80), bg))
  }

  // MARK: through the whole view

  /// A deck A playing `project`, a sample deck B, a hub over them; nothing is rendered until asked.
  @MainActor final class Rig {
    let dj: DJEngine
    let hub: ScopeHub
    init(_ project: Project) throws {
      dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
      dj["A"]!.loadNet(project)
      dj["B"]!.loadDemo()
      dj["A"]!.wave.setTempo(300)
      dj["A"]!.setPlaying(true)
      dj["B"]!.setPlaying(true)
      hub = ScopeHub(engine: dj)
      try dj.start()
    }
    func run(seconds: Double) throws {
      var left = Int(seconds * 22_050)
      while left > 0 {
        let n = min(left, 22_050 / 2)
        try renderOffline(dj, frames: n)
        hub.pump()
        left -= n
      }
    }
  }

  /// The view over a real feed, with the width chosen so that every step is a whole number of
  /// pixels (and every lane a whole number of rows): events then land on exact pixels.
  @Test(arguments: ["loop", "minimal"])
  func theWholeViewDrawsTheEnginesOwnRasterInItsLaneColours(structure: String) async throws {
    var ov = JSONObject()
    ov["seed"] = .number(42)
    if structure != "loop" { ov["structure"] = .string(structure) }
    let project = compose(genre: "techno", overrides: .object(ov))
    let rig = try Rig(project)
    defer { rig.dj.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 1)
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let scene = try #require(raster.scene)
    #expect(raster.phase == .ready && scene.result.count > 50)

    let steps = scene.result.steps
    let laneCount = scene.lanes.count
    let perStep = max(1, 900 / steps)
    let width = 64 + steps * perStep
    let lh = 24
    let height = 28 + laneCount * lh
    let layout = RasterLayout(
      width: Double(width), height: Double(height), laneCount: laneCount, steps: steps)
    #expect(layout.lh == Double(lh) && layout.pw == Double(steps * perStep))

    let view = ScopeRasterView(feed: feed, measured: false, hub: rig.hub, raster: raster)
    let px = try #require(
      renderPixels(view, width: width, height: height), "rendered")
    savePNG(view, width: width, height: height, name: "raster-engine-\(structure)")

    // every lane that has an event shows its colour at that event's place (except where the
    // loop marker, a section marker or the playhead is drawn over it)
    let r = scene.result
    let c0 = feed.clock
    var covered: [Double] = [layout.gut - 1]
    covered += layout.sectionMarks(scene.sections).map { $0.rect.x }
    if let head = layout.playheadRect(tick: c0.tick, phase: c0.tickPhase, playing: c0.playing) {
      covered.append(head.x)
    }
    var checked = Set<Int>()
    for i in 0..<r.count {
      let l = Int(r.lane[i])
      let lane = scene.lanes[l]
      guard
        let e = layout.eventRect(
          step: Int(r.step[i]), lane: l, note: Int(r.note[i]), vel: Int(r.vel[i]),
          dur: Double(r.dur[i]), drum: lane.drum, lo: lane.lo, hi: lane.hi)
      else { continue }
      if covered.contains(where: { abs($0 - e.x) < 3 }) { continue }
      let c = lane.color.rgb8
      let want = (c.r, c.g, c.b)
      if lane.drum {
        guard r.vel[i] >= 40 else { continue }
        // the row just above the lane's floor, at the spike's column
        let y = Int(layout.top + Double(l + 1) * layout.lh) - 3
        #expect(
          px.near(Int(e.x.rounded()), y, want, tol: 4),
          Comment(rawValue: "\(lane.key) spike at step \(r.step[i])"))
      } else {
        // the row that is fully inside the 2 px bar, at the bar's first column
        // (x is a whole number up to the last bit of the division, so round it)
        #expect(
          px.near(Int(e.x.rounded()), Int(e.y) + 1, want, tol: 4),
          Comment(rawValue: "\(lane.key) note at step \(r.step[i])"))
      }
      checked.insert(l)
      if checked.count == laneCount { break }
    }
    #expect(
      checked.count >= min(laneCount, 5),
      "events of \(checked.count) of \(laneCount) lanes were looked at")

    // lane names are in their colours
    for (l, lane) in scene.lanes.enumerated() {
      let c = lane.color.rgb8
      let y0 = 14 + l * lh
      #expect(
        count(px, (c.r, c.g, c.b), x: 0..<62, y: y0..<(y0 + lh), tol: 70) > 4,
        Comment(rawValue: lane.key))
    }
    // the playhead of the playing deck is drawn where the clock says
    let c = feed.clock
    let head = try #require(
      layout.playheadRect(tick: c.tick, phase: c.tickPhase, playing: c.playing), "a playing deck")
    let col = Int(head.x)
    let bright = (px.color(col, height / 2).r - 5) + (px.color(col + 1, height / 2).r - 5)
    #expect(bright > 120, "white at 80 % spread over two columns: \(bright)")
    // loop marker only for the loop, section markers only for the arrangement
    if structure == "loop" {
      #expect(raster.scene?.result.loop == true)
      #expect(px.near(63, height / 2, section, tol: 3))
    } else {
      #expect(!scene.sections.isEmpty)
      #expect(px.near(63, height / 2, section, tol: 3), "the first section starts at step 0")
    }
  }

  @Test func theViewSpeaksTheStatusLineAndALoopReadsLikeScopeJs() async throws {
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let rig = try Rig(compose(genre: "house", overrides: .object(ov)))
    defer { rig.dj.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    try rig.run(seconds: 0.5)
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    let line = ScopeStatusLine()
    let view = ScopeRasterView(feed: feed, measured: false, hub: rig.hub, raster: raster)
      .environment(\.scopeStatusLine, line)
    _ = renderPixels(view, width: 700, height: 200)
    let r = try #require(raster.scene).result
    let text = try #require(line.text)
    #expect(text == RasterLayout.statusText(r))
    #expect(text.hasPrefix("raster · loop cycle · \(r.count) events · "), Comment(rawValue: text))
    #expect(text.hasSuffix(" ms"))
  }

  @Test func aSampleDeckShowsThatThereIsNoNet() async throws {
    let rig = try Rig(compose(genre: "techno", overrides: .object(JSONObject())))
    defer { rig.dj.stop() }
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    try rig.run(seconds: 0.5)
    let line = ScopeStatusLine()
    let view = ScopeRasterView(feed: feed, measured: false, hub: rig.hub)
      .environment(\.scopeStatusLine, line)
    let px = try #require(renderPixels(view, width: 600, height: 160))
    savePNG(view, width: 600, height: 160, name: "raster-sample-deck")
    #expect(count(px, textGrey, x: 6..<200, y: 6..<22, tol: 60) > 30, "no net on this deck")
    #expect(px.near(300, 100, bg, tol: 2))
    #expect(line.text == nil, "the host's own status stays")
  }

  @Test func theMasterShowsTheLeadDecksArrangement() async throws {
    let rig = try Rig(scopeProjectForViews(structure: nil))
    defer { rig.dj.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    try rig.run(seconds: 1)
    let raster = RasterController()
    raster.update(feed: feed)
    await raster.settled()
    #expect(raster.phase == .ready && feed.leadDeck == "A")
    let view = ScopeRasterView(feed: feed, measured: false, hub: rig.hub, raster: raster)
    let px = try #require(renderPixels(view, width: 800, height: 220))
    savePNG(view, width: 800, height: 220, name: "raster-master")
    let first = try #require(raster.scene?.lanes.first).color.rgb8
    #expect(
      count(px, (first.r, first.g, first.b), x: 64..<800, y: 14..<192, tol: 12) > 0, "its events")
    #expect(raster.scene?.lanes.allSatisfy { $0.deck == "A" } == true)
  }

  // MARK: status line

  @Test func theStatusLineBelongsToTheLastSpeaker() {
    let line = ScopeStatusLine()
    final class Owner {}
    let a = Owner()
    let b = Owner()
    #expect(line.text == nil)
    line.set("raster · 1 events", owner: a)
    #expect(line.text == "raster · 1 events")
    line.set(nil, owner: a)
    #expect(line.text == nil, "nil gives the host its line back")
    line.set("a", owner: a)
    line.set("b", owner: b)
    line.clear(owner: a)
    #expect(line.text == "b", "a view that went away does not wipe the next one's text")
    line.clear(owner: b)
    #expect(line.text == nil)
  }

  // MARK: cost

  @Test func drawingTheStaticLayerIsFastEvenForTheFullEventCapacity() throws {
    // the most a raster can hold: 262144 events over the widest sensible plot
    var r = RasterResult(steps: 16_384)
    let lanes = (0..<10).map { i in
      lane("l\(i)", drum: i < 3, lo: 36, hi: 72, hex: i % 2 == 0 ? "#e94560" : "#2ecc71")
    }
    r.step.reserveCapacity(262_144)
    for i in 0..<262_144 {
      r.step.append(Int32(i % 16_384))
      r.lane.append(UInt8(i % 10))
      r.note.append(UInt8(36 + (i * 7) % 37))
      r.vel.append(UInt8(1 + (i * 13) % 127))
      r.dur.append(Float(1 + i % 4))
    }
    let big = RasterScene(result: r, lanes: lanes, sections: [], id: 99)
    let clock = ContinuousClock()
    let t0 = clock.now
    let image = RasterImage.make(scene: big, size: CGSize(width: 1800, height: 640), scale: 2)
    let c = (clock.now - t0).components
    let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    print("RASTER: 262144 events at 1800x640 @2x: \(Int(ms)) ms (build \(buildKind))")
    #expect(image != nil)
    // generous: the point is that it is done once, off the per-frame path, not on every frame
    #expect(ms < 5000, "\(ms) ms")
  }
}

#if DEBUG
  private let buildKind = "debug"
#else
  private let buildKind = "release"
#endif

/// A loop or arranged techno project for the master test.
private func scopeProjectForViews(structure: String?) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(42)
  if let structure { ov["structure"] = .string(structure) }
  return compose(genre: "techno", overrides: .object(ov))
}
