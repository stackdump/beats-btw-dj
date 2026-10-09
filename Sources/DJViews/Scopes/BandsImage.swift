import AppKit
import CoreText
import DJCore

// The Bands picture as a bitmap (scope.js `drawBands`, as `RasterImage` is for the raster).
//
// Everything on screen depends on the scene and the size only, never on the playback between two
// scenes, and the scene is rebuilt four times a second at most (the 250 ms redraw limit). scope.js
// keeps the finished picture on its canvas for the same reason ("its per-cell text is the priciest
// draw here"). A SwiftUI Canvas repaints from scratch every frame, and the digits are the cost:
// measured through `ImageRenderer` in debug, 720 digits (800 pt) took 3.0 ms and 1440 (1500 pt)
// 5.5 ms per paint on top of 2 ms for everything else, 30 times a second. So the picture is drawn
// once per scene into a bitmap at device resolution and the Canvas only blits it.
//
// Drawn with Core Graphics straight into a bitmap (not with a SwiftUI Canvas through an
// ImageRenderer, which cannot be run from inside a draw). The cells of a block are filled one
// colour at a time (they never overlap), the ten digits are CoreText lines made once (white below
// 6, black from 6, as the JS), everything else is a CoreText line per label.
//
// TEXT. The face is the one the JS gets in Chrome, Menlo 10 px (`FONT` = `ui-monospace, ...,
// monospace`; Chrome has no `ui-monospace` and falls through to `monospace`). With
// `textBaseline = 'top'` Chrome puts the baseline `topBaseline` = 7.59375 px below the y it is
// given (`measureText("E").alphabeticBaseline` of that font in Chrome 10 px is -7.59375): a cap
// letter spans y + 0.3 ... y + 7.6, so the digit printed at `yy + 2` in a 13 px cell sits at
// `yy + 2.3 ... yy + 9.6`, a little above the middle. A SwiftUI `Text` anchored `.topLeading`
// starts its line box at y instead, which puts the glyph about 3 pt lower (this was the Bands
// view's first version; it left the digits bottom-heavy in the cell).
//
// The background is not part of the image: the bitmap is transparent where nothing is drawn and
// goes on top of the scope background that `ScopeCanvas` fills.

extension LiveScopeRect {
  var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

@MainActor
enum BandsImage {
  /// scope.js `FONT`'s face at 10 px, as Chrome resolves it.
  static let font: CTFont =
    CTFontCreateUIFontForLanguage(.userFixedPitch, 10, nil)
    ?? CTFontCreateWithName("Menlo" as CFString, 10, nil)
  /// Chrome's `textBaseline = 'top'` baseline for `font`: this many points below the given y.
  static let topBaseline = 7.59375
  /// A bitmap larger than this many pixels is not made (a zero or absurd canvas).
  static let maxPixels = 1 << 26

  private static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
  private static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

  private static func line(_ text: String, _ color: CGColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
  }

  /// The ten digits, each in the colour the JS prints it in.
  private static let digitLines: [CTLine] = (0..<10).map {
    line(String($0), $0 >= BandsScene.darkDigitFrom ? black : white)
  }

  /// Render `scene` at `size` points and `scale` device pixels per point. Nil only if the bitmap
  /// cannot be made (a zero or absurd size).
  static func make(scene: BandsScene, size: CGSize, scale: CGFloat) -> CGImage? {
    let wPx = Int((size.width * scale).rounded())
    let hPx = Int((size.height * scale).rounded())
    guard wPx > 0, hPx > 0, scale > 0, wPx * hPx <= maxPixels,
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

    let textColor = ScopeColors.text.cgColor
    let put = { (t: LiveScopeText) in text(t, textColor, scale: scale, in: ctx) }
    if let m = scene.message { put(m) }

    for block in scene.blocks {
      // the cells, one colour at a time (they do not overlap)
      var order: [ScopeColor] = []
      var byColor: [ScopeColor: [CGRect]] = [:]
      for c in block.cells {
        if byColor[c.color] == nil { order.append(c.color) }
        byColor[c.color, default: []].append(c.rect.cgRect)
      }
      for color in order {
        ctx.setFillColor(color.cgColor)
        ctx.fill(byColor[color] ?? [])
      }
      // the digits, then the labels and the title
      for d in block.digits where d.digit >= 0 && d.digit < 10 {
        draw(digitLines[d.digit], x: d.x, y: d.y, scale: scale, in: ctx)
      }
      for l in block.labels { put(l) }
      put(block.title)
      // section strips over the rows
      ctx.setFillColor(ScopeColors.sectionLine.cgColor)
      ctx.fill(block.sections.map(\.cgRect))
    }
    for a in scene.axis { put(a) }
    if let t = scene.tilt { put(t) }
    return ctx.makeImage()
  }

  /// Draw `t` with the JS's `textBaseline = 'top'` at (x, y).
  private static func text(_ t: LiveScopeText, _ color: CGColor, scale: CGFloat, in ctx: CGContext)
  {
    guard !t.text.isEmpty else { return }
    draw(line(t.text, color), x: t.x, y: t.y, scale: scale, in: ctx)
  }

  /// The baseline goes on a whole device pixel, as Chrome's (Skia) does for upright text.
  private static func draw(
    _ line: CTLine, x: Double, y: Double, scale: CGFloat, in ctx: CGContext
  ) {
    ctx.saveGState()
    // the context is y-down: flip the glyphs upright again, baseline `topBaseline` below y
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: ((y + topBaseline) * scale).rounded() / scale)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

/// The bitmap of the last scene painted, kept until the scene or the size changes. A scene with
/// revision 0 (one that is not from a controller) is never kept.
@MainActor
final class BandsImageCache {
  struct Key: Hashable {
    var revision: Int
    var widthPx: Int
    var heightPx: Int
    var scale: Double
  }

  private var key: Key?
  private var image: CGImage?
  /// Bitmaps drawn so far (tests watch that a held scene is drawn once).
  private(set) var builds = 0

  init() {}

  func image(for scene: BandsScene, size: CGSize, scale: CGFloat) -> CGImage? {
    let k = Key(
      revision: scene.revision, widthPx: Int((size.width * scale).rounded()),
      heightPx: Int((size.height * scale).rounded()), scale: Double(scale))
    if scene.revision != 0, k == key { return image }
    builds += 1
    key = scene.revision != 0 ? k : nil
    image = BandsImage.make(scene: scene, size: size, scale: scale)
    return image
  }
}
