import Foundation

/// A song's sections laid out along a bar, as fractions of its length.
public struct SectionTimeline: Equatable, Sendable {
  public struct Segment: Equatable, Sendable {
    public var name: String
    public var start: Double
    public var width: Double
    public var isCurrent: Bool

    public init(name: String, start: Double, width: Double, isCurrent: Bool) {
      self.name = name
      self.start = start
      self.width = width
      self.isCurrent = isCurrent
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
        width: Double(s.steps) / Double(total), isCurrent: i == current)
    }
    return SectionTimeline(
      segments: segments,
      playhead: min(1, max(0, (Double(tick) + wave.tickPhase) / Double(total))), totalTicks: total)
  }
}
