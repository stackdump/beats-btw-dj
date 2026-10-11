import AppKit
import CoreText
import DJCore

// The static layer of the raster (scope.js `drawRaster`'s offscreen canvas `s.rCan`): background,
// bar lines and numbers, lane separators and names, every event, the loop marker and the section
// markers. It depends on the scene and the size only, never on playback, so it is drawn once into
// a bitmap at device resolution and blitted every frame; the playhead goes on top.
//
// Drawn with Core Graphics straight into a bitmap (not with a SwiftUI Canvas through an
// ImageRenderer, which cannot be run from inside a draw). All geometry comes from `RasterLayout`
// (DJCore, unit-tested); this file only executes it. Every event is its own anti-aliased `fill`,
// in the order the events were fired, exactly like the JS's one `fillRect` per event: marks that
// overlap in a pixel compound their partial coverage, which one `fill([CGRect])` over a lane
// would not (it paints the union once; a probe of three 1 px marks a quarter pixel apart gave 192
// against 230 of 255). Done this way it is also the faster of the two.

extension ScopeColor {
  var cgColor: CGColor {
    CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      components: [r, g, b, a].map { CGFloat($0) }
    )!
  }
}

@MainActor
enum RasterImage {
  /// The scope's 10 px monospaced face (scope.js `FONT`).
  static let font: CTFont =
    CTFontCreateUIFontForLanguage(.userFixedPitch, 10, nil)
    ?? CTFontCreateWithName("Menlo" as CFString, 10, nil)

  /// Render the static layer for `scene` at `size` points and `scale` device pixels per point.
  /// Nil only if the bitmap cannot be made (a zero size).
  static func make(scene: RasterScene, size: CGSize, scale: CGFloat) -> CGImage? {
    let wPx = Int((size.width * scale).rounded())
    let hPx = Int((size.height * scale).rounded())
    guard wPx > 0, hPx > 0, scale > 0,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // y grows downward, in points
    ctx.translateBy(x: 0, y: CGFloat(hPx))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)
    ctx.setShouldSmoothFonts(false)
    ctx.interpolationQuality = .none

    let r = scene.result
    let lanes = scene.lanes
    let layout = RasterLayout(
      width: Double(size.width), height: Double(size.height), laneCount: lanes.count,
      steps: r.steps)

    ctx.setFillColor(ScopeColors.background.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

    // bar lines, then the bar numbers
    for line in layout.barLines() {
      ctx.setFillColor((line.major ? ScopeColors.barLine : ScopeColors.grid).cgColor)
      ctx.fill(line.rect.cg)
    }
    for label in layout.axisLabels() { text(label, ScopeColors.text, in: ctx) }

    // lane separators and names
    for (l, lane) in lanes.enumerated() {
      ctx.setFillColor(ScopeColors.grid.cgColor)
      ctx.fill(layout.laneSeparator(l).cg)
      text(layout.laneLabel(l, key: lane.key), lane.color, in: ctx)
    }

    // events, one fill each, in firing order; the colour is set only when the lane changes
    let laneColors = lanes.map { $0.color.cgColor }
    var colored = -1
    for i in 0..<r.count {
      let l = Int(r.lane[i])
      guard l < lanes.count else { continue }
      let lane = lanes[l]
      guard
        let e = layout.eventRect(
          step: Int(r.step[i]), lane: l, note: Int(r.note[i]), vel: Int(r.vel[i]),
          dur: Double(r.dur[i]), drum: lane.drum, lo: lane.lo, hi: lane.hi)
      else { continue }
      if l != colored {
        ctx.setFillColor(laneColors[l])
        colored = l
      }
      ctx.fill(e.cg)
    }

    // loop marker, section markers (all in the section colour)
    ctx.setFillColor(ScopeColors.sectionLine.cgColor)
    if r.loop && !r.failed {
      ctx.fill(layout.loopMarker().cg)
      text(layout.loopLabel(cycle: r.cycle), ScopeColors.sectionLine, in: ctx)
    }
    for mark in layout.sectionMarks(scene.sections) {
      ctx.setFillColor(ScopeColors.sectionLine.cgColor)
      ctx.fill(mark.rect.cg)
      text(mark.label, ScopeColors.sectionLine, in: ctx)
    }
    if lanes.isEmpty || r.failed {
      text(layout.emptyLabel(failed: r.failed), ScopeColors.text, in: ctx)
    }
    return ctx.makeImage()
  }

  /// Draw `label` with its top-left corner at (x, y) (the JS draws with `textBaseline = 'top'`).
  private static func text(_ label: RasterLabel, _ color: ScopeColor, in ctx: CGContext) {
    guard !label.text.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: label.text, attributes: attributes))
    ctx.saveGState()
    // the context is y-down: flip the glyphs upright again and put the baseline an ascent below
    // the top
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: label.x, y: label.y + CTFontGetAscent(font))
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

extension RasterRect {
  var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// The bitmap of the static layer, kept until the scene or the size changes (scope.js `s.rKey`).
@MainActor
final class RasterImageCache {
  struct Key: Hashable {
    var scene: Int
    var widthPx: Int
    var heightPx: Int
    var scale: Double
  }

  private var key: Key?
  private var image: CGImage?
  /// Bitmaps drawn so far (tests watch that a steady scene is drawn once).
  private(set) var builds = 0

  init() {}

  func image(for scene: RasterScene, size: CGSize, scale: CGFloat) -> CGImage? {
    let k = Key(
      scene: scene.id, widthPx: Int((size.width * scale).rounded()),
      heightPx: Int((size.height * scale).rounded()), scale: Double(scale))
    if k == key { return image }
    builds += 1
    key = k
    image = RasterImage.make(scene: scene, size: size, scale: scale)
    return image
  }
}
