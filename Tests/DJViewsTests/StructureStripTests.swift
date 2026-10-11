import AppKit
import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 24 on screen: beats' colours, blocks sized by steps, phrase dividers and letters.
@MainActor
struct StructureStripRenderTests {
  func timeline(
    _ names: [String], widths: [Double], current: Int = -1, phrases: [Int: (Int, [String])] = [:]
  ) -> SectionTimeline {
    var start = 0.0
    var segs: [SectionTimeline.Segment] = []
    for (i, n) in names.enumerated() {
      let p = phrases[i]
      segs.append(
        .init(
          name: n, start: start, width: widths[i], isCurrent: i == current,
          phraseCount: p?.0 ?? 1, phrasePattern: p?.1 ?? []))
      start += widths[i]
    }
    return SectionTimeline(segments: segs, playhead: 0, totalTicks: 100)
  }

  func brightness(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Int { c.r + c.g + c.b }

  @Test func eachNamedSectionIsPaintedInItsBeatsColour() throws {
    let names = ["intro", "verse", "chorus", "bridge", "outro"]
    let hex: [(Int, Int, Int)] = [
      (74, 144, 217), (46, 204, 113), (233, 69, 96), (155, 89, 182), (245, 166, 35),
    ]
    let w = 500
    // each block 100 wide; the section at index 2 is the one playing
    let current = timeline(names, widths: Array(repeating: 0.2, count: 5), current: 2)
    let px = try #require(
      renderPixels(SectionTimelineView(timeline: current), width: w, height: 30))
    // sample the lower edge of each block, clear of the label text at the middle
    for i in 0..<5 {
      let x = i * 100 + 8
      if i == 2 {
        #expect(px.near(x, 26, hex[i], tol: 6), "\(names[i]) (playing) \(px.color(x, 26))")
      } else {
        let k = 0.45 / 0.95
        let dim = (Int(Double(hex[i].0) * k), Int(Double(hex[i].1) * k), Int(Double(hex[i].2) * k))
        #expect(px.near(x, 26, dim, tol: 6), "\(names[i]) resting \(px.color(x, 26)) vs \(dim)")
      }
    }
    savePNG(
      SectionTimelineView(timeline: current), width: w, height: 30, name: "structure-strip-colours")
  }

  @Test func namesBeatsDoesNotColourKeepTheirOldHue() throws {
    // The strip used Color(hue: hash(name), saturation: .55, brightness: .95 / .45); the colour
    // function that replaced it must give the same pixels for every name outside beats' five.
    for name in ["drop", "breakdown", "buildup", "pre-chorus", "solo", "x"] {
      for current in [true, false] {
        let old = NSColor(
          Color(
            hue: SectionTimeline.hue(name), saturation: 0.55, brightness: current ? 0.95 : 0.45)
        ).usingColorSpace(.sRGB)!
        let c = SectionTimeline.color(name, isCurrent: current)
        #expect(abs(c.r - Double(old.redComponent)) < 0.01, "\(name) r")
        #expect(abs(c.g - Double(old.greenComponent)) < 0.01, "\(name) g")
        #expect(abs(c.b - Double(old.blueComponent)) < 0.01, "\(name) b")
      }
    }
  }

  @Test func blocksAreSizedBySteps() throws {
    // 40 / 10 / 50 % of 500 pt: the colour changes at 200 and 250 (minus the 1 pt gap)
    let t = timeline(["intro", "chorus", "outro"], widths: [0.4, 0.1, 0.5])
    let px = try #require(renderPixels(SectionTimelineView(timeline: t), width: 500, height: 30))
    func name(_ x: Int) -> String {
      let c = px.color(x, 27)
      if abs(c.r - 35) < 12 && abs(c.b - 103) < 14 { return "intro" }
      if abs(c.r - 111) < 12 && abs(c.b - 45) < 14 { return "chorus" }
      if abs(c.r - 116) < 12 && abs(c.b - 17) < 14 { return "outro" }
      return "gap"
    }
    #expect(name(100) == "intro" && name(190) == "intro")
    #expect(name(215) == "chorus" && name(240) == "chorus")
    #expect(name(300) == "outro" && name(480) == "outro")
  }

  @Test func phraseDividersFallAtTheirFractions() throws {
    let t = timeline(["verse"], widths: [1], phrases: [0: (4, ["A", "B", "A", "C"])])
    let plain = timeline(["verse"], widths: [1])
    let with = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    let without = try #require(
      renderPixels(SectionTimelineView(timeline: plain), width: 400, height: 30))
    // the block is x 0.5 ... 399.5; dividers sit at 0.5 + f * 399 for f = 1/4, 2/4, 3/4. A 1 pt
    // white line at 25 % lightens the column; read the bottom row, clear of the label.
    for f in [0.25, 0.5, 0.75] {
      let x = Int(0.5 + f * 399)
      let lit = brightness(with.color(x, 27)) - brightness(without.color(x, 27))
      let side = brightness(with.color(x + 6, 27)) - brightness(without.color(x + 6, 27))
      #expect(lit > 30 && side == 0, "divider at \(f): +\(lit) there, +\(side) beside it")
    }
    // a section with one phrase has none
    let one = timeline(["verse"], widths: [1], phrases: [0: (1, ["A"])])
    let px = try #require(renderPixels(SectionTimelineView(timeline: one), width: 400, height: 30))
    #expect(brightness(px.color(100, 27)) == brightness(without.color(100, 27)))
  }

  /// The runs of columns that carry light text in rows 6..<24, split where at least `gap` empty
  /// columns follow one another. The block behind is dark (a dimmed section colour: red below 40).
  func textRuns(_ p: Pixels, xs: Range<Int>, gap: Int = 4) -> [ClosedRange<Int>] {
    var runs: [ClosedRange<Int>] = []
    var start: Int?
    var last = 0
    for x in xs {
      let lit = (6..<24).contains { p.color(x, $0).r > 90 }
      if lit {
        if let s = start, x - last > gap {
          runs.append(s...last)
          start = x
        } else if start == nil {
          start = x
        }
        last = x
      }
    }
    if let s = start { runs.append(s...last) }
    return runs
  }

  @Test func theLettersAreTypedAfterTheNameWithAFourPointGap() throws {
    let t = timeline(["verse"], widths: [1], phrases: [0: (4, ["A", "B", "A", "C"])])
    let plain = timeline(["verse"], widths: [1])
    let with = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    let without = try #require(
      renderPixels(SectionTimelineView(timeline: plain), width: 400, height: 30))
    // the dividers are 25 % white lines: too dim to count as text (red stays under 90)
    let bare = textRuns(without, xs: 4..<396)
    #expect(bare.count == 1, "just the name: \(bare)")
    let both = textRuns(with, xs: 4..<396)
    #expect(both.count == 2, "name, then letters: \(both)")
    guard both.count == 2 else { return }
    // the gap between the glyphs is the 4 pt margin plus the side bearings of two glyphs
    let gap = both[1].lowerBound - both[0].upperBound - 1
    #expect(gap >= 3 && gap <= 8, "4 pt between name and letters: \(gap)")
    // the run as a whole is centred in the block (0.5 ... 399.5), the name having moved left
    let mid = Double(both[0].lowerBound + both[1].upperBound) / 2
    #expect(abs(mid - 200) < 3, "centred: \(mid)")
    #expect(both[0].lowerBound < bare[0].lowerBound - 8, "the name made room for the letters")
    savePNG(
      SectionTimelineView(timeline: t), width: 400, height: 30, name: "structure-strip-phrases")
  }

  @Test func theLettersGiveWayWhenTheLabelWouldNotFit() throws {
    // 50 pt: the name alone fits, name + gap + letters does not
    let t = timeline(
      ["verse", "intro"], widths: [0.125, 0.875], phrases: [0: (4, ["A", "B", "A", "C"])])
    let px = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    let runs = textRuns(px, xs: 1..<49)
    #expect(runs.count == 1, "only the name: \(runs)")
    // and the name is centred in its block (0.5 ... 49.5)
    if let r = runs.first { #expect(abs(Double(r.lowerBound + r.upperBound) / 2 - 25) < 3) }
  }

  /// A label wider than its block is cut at the block's edge, not spilled over its neighbours.
  /// The narrow blocks around it have no label of their own (28 pt or less) and must stay one
  /// flat colour. (A later block is painted over an earlier one's spill, so it is the block
  /// *before* the long label that shows whether the label is clipped.)
  @Test func aLabelNeverLeavesItsBlock() throws {
    // 400 pt: a 35 pt block holding "pre-chorus" (48 pt wide), between blocks of 20 pt
    let names = ["chorus", "x", "pre-chorus", "y", "intro", "z", "chorus"]
    let widths = [0.2, 0.05, 0.09, 0.05, 0.3, 0.05, 0.26]
    let t = timeline(
      names, widths: widths, phrases: [2: (4, ["A", "B", "A", "B"]), 6: (2, ["A", "A"])])
    let px = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    var start = 0.0
    var edges: [(Int, Int)] = []
    for w in widths {
      edges.append((Int(start * 400 + 0.5), Int((start + w) * 400 - 0.5)))
      start += w
    }
    // the long label is there: light pixels well inside its own block
    let own = edges[2]
    let lit = px.count(inX: (own.0 + 4)..<(own.1 - 4), y: 8..<22) { r, g, b in
      min(r, g, b) > 140
    }
    #expect(lit > 12, "the name is drawn inside its block (\(lit))")
    // the narrow neighbours carry no text: every pixel of their middle rows is their own block
    // colour, right up to the edge next to the long label
    for i in [1, 3, 5] {
      let c = SectionTimeline.color(names[i], isCurrent: false).rgb8
      let want = (c.r, c.g, c.b)
      var off: [String] = []
      for x in (edges[i].0 + 1)..<(edges[i].1 - 1) {
        for y in 9..<21 where !px.near(x, y, want, tol: 8) {
          off.append("(\(x), \(y)) \(px.color(x, y))")
        }
      }
      #expect(off.isEmpty, "\(names[i]) should be flat \(want): \(off.prefix(4))")
    }
  }

  @Test func dividersOfALaterBlockSitInThatBlock() throws {
    // two blocks, the second with 2 phrases: its divider is at 200 + 0.5 * 200 = 300 (less the
    // 1 pt gap), not at 0.5 * 200 as it would be if the block's own left edge were forgotten
    let t = timeline(["intro", "verse"], widths: [0.5, 0.5], phrases: [1: (2, ["A", "B"])])
    let plain = timeline(["intro", "verse"], widths: [0.5, 0.5])
    let with = try #require(renderPixels(SectionTimelineView(timeline: t), width: 400, height: 30))
    let without = try #require(
      renderPixels(SectionTimelineView(timeline: plain), width: 400, height: 30))
    // block 2 is x 200.5 ... 399.5; its divider at 200.5 + 0.5 * 199 = 300
    let x = Int(200.5 + 0.5 * 199)
    let lit = brightness(with.color(x, 27)) - brightness(without.color(x, 27))
    #expect(lit > 30, "divider at x = \(x): +\(lit)")
    let wrong = Int(0.5 + 0.5 * 199)
    #expect(brightness(with.color(wrong, 27)) == brightness(without.color(wrong, 27)))
    #expect(brightness(with.color(100, 27)) == brightness(without.color(100, 27)))
  }

  @Test func clickingStillPicksTheSection() {
    // the hit-testing the view uses is untouched by the new fields
    let t = timeline(["intro", "verse"], widths: [0.5, 0.5], current: 0)
    #expect(t.index(atFraction: 0.25) == 0 && t.index(atFraction: 0.75) == 1)
  }
}
