// Colours and colour maps shared by every scope mode.
//
// Values only: no SwiftUI here (DJCore never imports it). The views in DJViews/Scopes turn a
// `ScopeColor` into a `Color`. Everything is ported from the pinned beats sources (095d030):
//   * the 256-entry RGB LUTs and the digit / residual tables: scope.js `lut`, MAGMA, VIRIDIS,
//     RDBU, DIGIT_CSS, RES_CSS;
//   * the lane colours: lib/backend/audio-io.js `VIZ_COLORS` / `vizColorForNet`, and scope.js
//     `FALLBACK_COLORS`;
//   * `channelHue`: stage.js (it knows channels 20...23 as well, which SPEC.md omits);
//   * the section colours: lib/ui/canvas.js `renderTimeline`;
//   * the scope chrome: scope.js BG / GRID / BARLINE / SECTION / TEXT.

/// An RGBA colour, each component 0...1.
public struct ScopeColor: Equatable, Hashable, Sendable {
  public var r: Double
  public var g: Double
  public var b: Double
  public var a: Double

  public init(r: Double, g: Double, b: Double, a: Double = 1) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  /// 8-bit components, as the canvas would store them.
  public init(r8: Int, g8: Int, b8: Int, a: Double = 1) {
    self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255, a: a)
  }

  /// `"#rrggbb"` or `"#rgb"` (each digit doubled, as CSS does); nil for anything else.
  public init?(hex: String) {
    var s = Substring(hex)
    guard s.first == "#" else { return nil }
    s = s.dropFirst()
    guard s.count == 6 || s.count == 3 else { return nil }
    var digits: [Int] = []
    for c in s {
      guard let v = c.hexDigitValue else { return nil }
      digits.append(v)
    }
    if digits.count == 3 { digits = digits.flatMap { [$0, $0] } }
    self.init(
      r8: digits[0] * 16 + digits[1], g8: digits[2] * 16 + digits[3],
      b8: digits[4] * 16 + digits[5])
  }

  /// CSS `hsla(h, s%, l%, a)`: `hue` in degrees (any value, wrapped), `saturation` and
  /// `lightness` in PERCENT (so `hsla(200, 90%, 60%, .35)` is `ScopeColor.hsla(200, 90, 60, 0.35)`),
  /// `alpha` 0...1. The algorithm is the one in the CSS Color spec.
  public static func hsla(
    _ hue: Double, _ saturation: Double, _ lightness: Double, _ alpha: Double = 1
  )
    -> ScopeColor
  {
    var h = hue.truncatingRemainder(dividingBy: 360)
    if h < 0 { h += 360 }
    let s = min(max(saturation, 0), 100) / 100
    let l = min(max(lightness, 0), 100) / 100
    func channel(_ n: Double) -> Double {
      let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
      let a = s * min(l, 1 - l)
      return l - a * max(-1, min(k - 3, 9 - k, 1))
    }
    return ScopeColor(r: channel(0), g: channel(8), b: channel(4), a: alpha)
  }

  /// The same colour with another alpha.
  public func withAlpha(_ alpha: Double) -> ScopeColor {
    ScopeColor(r: r, g: g, b: b, a: alpha)
  }

  /// 0...255 components rounded as a canvas would store them (ties up, like `Math.round`).
  public var rgb8: (r: Int, g: Int, b: Int) {
    (Self.byte(r), Self.byte(g), Self.byte(b))
  }

  /// CSS text: `rgb(r,g,b)` when opaque, else `rgba(r,g,b,a)`.
  public var css: String {
    let c = rgb8
    if a >= 1 { return "rgb(\(c.r),\(c.g),\(c.b))" }
    return "rgba(\(c.r),\(c.g),\(c.b),\(Self.alphaText(a)))"
  }

  private static func byte(_ v: Double) -> Int { Int(jsRound(min(max(v, 0), 1) * 255)) }

  private static func alphaText(_ a: Double) -> String {
    let t = (a * 1000).rounded() / 1000
    if t == t.rounded() { return String(Int(t)) }
    var s = String(t)
    while s.hasSuffix("0") { s.removeLast() }
    return s
  }
}

/// A 256-entry RGB lookup table built from colour stops: scope.js `lut(stops)`, rounding and all.
public struct ScopeLUT: Sendable {
  /// 768 bytes: r, g, b for index 0...255.
  public let bytes: [UInt8]

  /// Linear interpolation between `stops` (each `[r, g, b]` 0...255, at least two), then rounded
  /// to the nearest integer with ties up (`Math.round`).
  public init(stops: [[Double]]) {
    precondition(stops.count >= 2 && stops.allSatisfy { $0.count == 3 })
    var out = [UInt8](repeating: 0, count: 256 * 3)
    for i in 0..<256 {
      let x = Double(i) / 255 * Double(stops.count - 1)
      let a = min(stops.count - 2, Int(x.rounded(.down)))
      let f = x - Double(a)
      for c in 0..<3 {
        out[i * 3 + c] = UInt8(jsRound(stops[a][c] + (stops[a + 1][c] - stops[a][c]) * f))
      }
    }
    bytes = out
  }

  /// The colour at index `i` (clamped to 0...255; fractions truncate like `i | 0`).
  public func rgb(at i: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let k = min(max(i, 0), 255) * 3
    return (bytes[k], bytes[k + 1], bytes[k + 2])
  }

  public func color(at i: Int) -> ScopeColor {
    let c = rgb(at: i)
    return ScopeColor(r8: Int(c.r), g8: Int(c.g), b8: Int(c.b))
  }

  /// scope.js `lutCss`: `rgb(r,g,b)` for index `i | 0`.
  public func css(at i: Int) -> String { color(at: i).css }
}

/// The scope palette. A namespace of constants; nothing here changes at run time.
public enum ScopeColors {
  // MARK: colour maps

  /// Spectrograms (modes 2, 3): black → purple → red → orange → pale yellow.
  public static let magma = ScopeLUT(stops: [
    [0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99], [212, 72, 66], [245, 125, 21],
    [250, 193, 39], [252, 253, 191],
  ])

  /// Band-energy digits (mode 5).
  public static let viridis = ScopeLUT(stops: [
    [68, 1, 84], [72, 40, 120], [62, 74, 137], [49, 104, 142], [38, 130, 142], [31, 158, 137],
    [53, 183, 121], [110, 206, 88], [181, 222, 43], [253, 231, 37],
  ])

  /// Measured − model residual (mode 5): blue (measured quieter) → white → red (louder).
  public static let rdbu = ScopeLUT(stops: [
    [33, 102, 172], [103, 169, 207], [209, 229, 240], [247, 247, 247], [253, 219, 199],
    [239, 138, 98], [178, 24, 43],
  ])

  /// scope.js `DIGIT_CSS`: the 10 band-energy digit colours, `viridis` at `d / 9 · 255`.
  public static let digitColors: [ScopeColor] = (0..<10).map { d in
    viridis.color(at: Int(Double(d) / 9 * 255))
  }

  /// scope.js `RES_CSS`: the 33 residual colours, `rdbu` at `i / 32 · 255`.
  public static let residualColors: [ScopeColor] = (0..<33).map { i in
    rdbu.color(at: Int(Double(i) / 32 * 255))
  }

  // MARK: scope chrome (scope.js BG, GRID, BARLINE, SECTION, TEXT)

  /// Canvas background `#050a14`.
  public static let background = ScopeColor(hex: "#050a14")!
  /// Beat grid line `#1a2a3a`.
  public static let grid = ScopeColor(hex: "#1a2a3a")!
  /// Bar line `#2f4a6a`.
  public static let barLine = ScopeColor(hex: "#2f4a6a")!
  /// Section start line `#e94560`.
  public static let sectionLine = ScopeColor(hex: "#e94560")!
  /// Axis and caption text `#8899aa`.
  public static let text = ScopeColor(hex: "#8899aa")!
  /// Waveform envelope `rgba(74,144,217,0.6)` (mode 1).
  public static let envelope = ScopeColor(r8: 74, g8: 144, b8: 217, a: 0.6)
  /// Waveform RMS `#f5a623` (mode 1).
  public static let rms = ScopeColor(hex: "#f5a623")!

  // MARK: lanes

  /// audio-io.js `VIZ_COLORS`: the colour of a part by its net id (or riff group).
  public static let laneColors: [String: ScopeColor] = [
    "kick": ScopeColor(hex: "#e94560")!,
    "snare": ScopeColor(hex: "#f5a623")!,
    "hihat": ScopeColor(hex: "#f8e71c")!,
    "clap": ScopeColor(hex: "#ff6b6b")!,
    "bass": ScopeColor(hex: "#4a90d9")!,
    "melody": ScopeColor(hex: "#2ecc71")!,
    "harmony": ScopeColor(hex: "#9b59b6")!,
    "arp": ScopeColor(hex: "#00d2ff")!,
  ]

  /// audio-io.js `VIZ_DEFAULT_COLOR` `#888`: what `vizColorForNet` answers for a part it does
  /// not know. `buildLanes` swaps it for the next `fallbackLaneColors` entry.
  public static let defaultLaneColor = ScopeColor(hex: "#888")!

  /// scope.js `FALLBACK_COLORS`, handed out in turn to lanes with no colour of their own.
  public static let fallbackLaneColors: [ScopeColor] = [
    "#00d2ff", "#2ecc71", "#9b59b6", "#f5a623", "#4a90d9", "#ff6b6b", "#1abc9c", "#e67e22",
  ].map { ScopeColor(hex: $0)! }

  /// audio-io.js `vizColorForNet`: the table entry for the net id, else for the id without a
  /// trailing `-<digits>` ("kick-0" → "kick"), else `defaultLaneColor`.
  public static func laneColor(forNet id: String) -> ScopeColor {
    if let c = laneColors[id] { return c }
    return laneColors[stripTrailingDashDigits(id)] ?? defaultLaneColor
  }

  /// `id.replace(/-\d+$/, '')`: drops one trailing dash plus ASCII digits.
  public static func stripTrailingDashDigits(_ id: String) -> String {
    let u = Array(id.unicodeScalars)
    var i = u.count
    while i > 0, u[i - 1].value >= 0x30, u[i - 1].value <= 0x39 { i -= 1 }
    guard i < u.count, i > 0, u[i - 1] == "-" else { return id }
    var s = String.UnicodeScalarView()
    s.append(contentsOf: u[0..<(i - 1)])
    return String(s)
  }

  // MARK: channels

  /// stage.js `channelHue`: a hue in degrees per MIDI channel (drums warm, bass cool, ...). A
  /// channel the table does not know hashes to `ch · 47 mod 360`; no channel (nil) is 200.
  ///
  /// A plain `switch`, not a dictionary: the stage modes call this once per fire per frame, and
  /// a dictionary literal in the body would be built and freed on every call.
  public static func channelHue(_ ch: Int?) -> Double {
    guard let ch else { return 200 }
    switch ch {
    case 1: return 50
    case 2: return 220
    case 3: return 200
    case 4: return 280
    case 5: return 320
    case 6: return 180
    case 7: return 140
    case 8: return 30
    case 9: return 100
    case 10: return 0
    case 11: return 12
    case 12: return 24
    case 13: return 35
    case 14: return 350
    case 20: return 50
    case 21: return 60
    case 22: return 40
    case 23: return 30
    default: return Double((ch * 47) % 360)
    }
  }

  // MARK: sections

  /// canvas.js section colours: intro `#4a90d9`, verse `#2ecc71`, chorus `#e94560`,
  /// bridge `#9b59b6`, outro `#f5a623`, anything else `#888`.
  public static func section(_ name: String) -> ScopeColor {
    switch name {
    case "intro": ScopeColor(hex: "#4a90d9")!
    case "verse": ScopeColor(hex: "#2ecc71")!
    case "chorus": ScopeColor(hex: "#e94560")!
    case "bridge": ScopeColor(hex: "#9b59b6")!
    case "outro": ScopeColor(hex: "#f5a623")!
    default: defaultLaneColor
    }
  }
}
