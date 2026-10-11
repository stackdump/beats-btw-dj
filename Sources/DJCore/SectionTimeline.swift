import Foundation

/// A song's sections laid out along a bar, as fractions of its length.
public struct SectionTimeline: Equatable, Sendable {
  public struct Segment: Equatable, Sendable {
    public var name: String
    public var start: Double
    public var width: Double
    public var isCurrent: Bool
    /// How many phrases the section is cut into (1: not shown). See `Deck.SectionInfo`.
    public var phraseCount: Int
    /// The phrase letters of the first role, e.g. ["A", "B", "A", "B"].
    public var phrasePattern: [String]

    public init(
      name: String, start: Double, width: Double, isCurrent: Bool, phraseCount: Int = 1,
      phrasePattern: [String] = []
    ) {
      self.name = name
      self.start = start
      self.width = width
      self.isCurrent = isCurrent
      self.phraseCount = phraseCount
      self.phrasePattern = phrasePattern
    }

    /// `renderTimeline`: phrase marks appear only when the section has more than one phrase.
    public var hasPhrases: Bool { phraseCount > 1 }

    /// The text printed after the name: the phrase letters run together ("ABAB"); nil when
    /// the section shows no phrases or has no letters.
    public var phraseLabel: String? {
      hasPhrases && !phrasePattern.isEmpty ? phrasePattern.joined() : nil
    }

    /// Where the phrase dividers fall, as fractions of the block's own width:
    /// `pi / phraseCount` for `pi` in `1..<phraseCount`.
    public var dividers: [Double] {
      hasPhrases ? (1..<phraseCount).map { Double($0) / Double(phraseCount) } : []
    }
  }

  /// Where a block's label goes (`.pn-timeline-section`: centred, `overflow: hidden`;
  /// `.pn-timeline-phrases { margin-left: 4px }`). The name and the phrase letters are one run,
  /// centred in the block; the letters go only if the whole run fits with a little air, else
  /// the name stands alone (and, if it is wider than its block, overflows both sides: the view
  /// clips it, as the CSS does). Numbers in points from the block's left edge.
  public enum LabelLayout {
    /// `margin-left: 4px` of the phrase letters.
    public static let phraseGap = 4.0
    /// Air kept on each side of a run that carries the letters.
    public static let margin = 2.0

    public struct Run: Equatable, Sendable {
      /// Left edge of the name.
      public var nameX: Double
      /// Left edge of the letters; nil when they are dropped.
      public var lettersX: Double?
    }

    public static func run(blockWidth: Double, nameWidth: Double, lettersWidth: Double?) -> Run {
      if let lettersWidth {
        let whole = nameWidth + phraseGap + lettersWidth
        if whole <= blockWidth - 2 * margin {
          let x = (blockWidth - whole) / 2
          return Run(nameX: x, lettersX: x + nameWidth + phraseGap)
        }
      }
      return Run(nameX: (blockWidth - nameWidth) / 2, lettersX: nil)
    }
  }

  public var segments: [Segment]
  /// 0…1 along the song (clamped; 1 once it has ended).
  public var playhead: Double
  public var totalTicks: Int

  public init(segments: [Segment], playhead: Double, totalTicks: Int) {
    self.segments = segments
    self.playhead = playhead
    self.totalTicks = totalTicks
  }

  /// The section a click at fraction `f` lands on.
  public func index(atFraction f: Double) -> Int? {
    guard !segments.isEmpty else { return nil }
    let x = min(max(f, 0), 1)
    return segments.lastIndex { $0.start <= x + 1e-12 } ?? 0
  }

  /// The section whose name colours it: stable across songs (a drop is always the same hue).
  public static func hue(_ name: String) -> Double {
    var h: UInt32 = 2_166_136_261
    for u in name.utf8 { h = (h ^ UInt32(u)) &* 16_777_619 }
    return Double(h % 360) / 360
  }

  /// The names beats' structure strip colours (canvas.js `renderTimeline`): intro `#4a90d9`,
  /// verse `#2ecc71`, chorus `#e94560`, bridge `#9b59b6`, outro `#f5a623`.
  public static let beatsNames = ["intro", "verse", "chorus", "bridge", "outro"]

  /// Saturation of the name-hash colours, and the brightness of a block that is / is not the
  /// section being played (what the strip always did).
  public static let hashSaturation = 0.55
  public static let currentBrightness = 0.95
  public static let restingBrightness = 0.45

  /// A section's colour. The five names beats colours keep beats' colours (the current block
  /// at full strength, the others dimmed by the same ratio the strip always dimmed by); any
  /// other name (drop, breakdown, buildup, pre-chorus, solo: the composer's own) keeps the
  /// stable per-name hue it had, where beats would paint them all `#888`.
  public static func color(_ name: String, isCurrent: Bool) -> ScopeColor {
    if beatsNames.contains(name) {
      let c = ScopeColors.section(name)
      let k = isCurrent ? 1 : restingBrightness / currentBrightness
      return ScopeColor(r: c.r * k, g: c.g * k, b: c.b * k)
    }
    return hsb(
      hue(name), hashSaturation, isCurrent ? currentBrightness : restingBrightness)
  }

  /// HSB to RGB (the colour model `Color(hue:saturation:brightness:)` uses).
  static func hsb(_ h: Double, _ s: Double, _ v: Double) -> ScopeColor {
    let i = Int(h * 6) % 6
    let f = h * 6 - Double(Int(h * 6))
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return ScopeColor(r: v, g: t, b: p)
    case 1: return ScopeColor(r: q, g: v, b: p)
    case 2: return ScopeColor(r: p, g: v, b: t)
    case 3: return ScopeColor(r: p, g: q, b: v)
    case 4: return ScopeColor(r: t, g: p, b: v)
    default: return ScopeColor(r: v, g: p, b: q)
    }
  }
}

extension Deck {
  /// The section bar for a song deck (nil for a loop or a sample deck).
  public var sectionTimeline: SectionTimeline? {
    let secs = sections
    let total = secs.reduce(0) { $0 + $1.steps }
    guard total > 0 else { return nil }
    let tick = wave.tick
    let current = secs.lastIndex { $0.startTick <= tick && tick < $0.startTick + $0.steps }
    let segments = secs.enumerated().map { i, s in
      SectionTimeline.Segment(
        name: s.name, start: Double(s.startTick) / Double(total),
        width: Double(s.steps) / Double(total), isCurrent: i == current,
        phraseCount: s.phraseCount, phrasePattern: s.phrasePattern)
    }
    return SectionTimeline(
      segments: segments,
      playhead: min(1, max(0, (Double(tick) + wave.tickPhase) / Double(total))), totalTicks: total)
  }
}
