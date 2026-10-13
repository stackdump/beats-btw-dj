import SwiftUI

/// Platter geometry, kept free of drawing so it can be asserted on.
public enum PlatterGeometry {
  /// One revolution = 1.8 s of audio (33⅓ rpm).
  public static let secondsPerRevolution = 1.8

  /// Degrees clockwise from 12 o'clock for an unwrapped platter position.
  public static func angle(platterSeconds s: Double) -> Double {
    (s / secondsPerRevolution * 360).truncatingRemainder(dividingBy: 360)
  }

  /// Centre of rim dot `i` of `count`, from 12 o'clock clockwise, in a square of `size`.
  public static func rimDot(_ i: Int, of count: Int, size: CGFloat, inset: CGFloat) -> CGPoint {
    let a = Double(i) / Double(count) * 2 * .pi
    let r = size / 2 - inset
    return CGPoint(x: size / 2 + CGFloat(sin(a)) * r, y: size / 2 - CGFloat(cos(a)) * r)
  }
}

/// A turntable: label, a marker that turns with the platter, a ring that lights when the
/// platter is touched, and four rim dots for the beat in the bar.
public struct PlatterView: View {
  public var seconds: Double
  public var touching: Bool
  public var tint: Color
  /// 0…3, or nil for no beat display.
  public var beatInBar: Int?

  public init(seconds: Double, touching: Bool, tint: Color, beatInBar: Int? = nil) {
    self.seconds = seconds
    self.touching = touching
    self.tint = tint
    self.beatInBar = beatInBar
  }

  public var body: some View {
    GeometryReader { g in
      let size = min(g.size.width, g.size.height)
      ZStack {
        Circle().fill(.black.opacity(0.85))
        Circle().strokeBorder(touching ? tint : .gray.opacity(0.5), lineWidth: touching ? 5 : 2)
        Circle().fill(tint.opacity(0.8)).frame(width: size * 0.24, height: size * 0.24)
        Rectangle().fill(.white).frame(width: 3, height: size * 0.4).offset(y: -size * 0.25)
          .rotationEffect(.degrees(PlatterGeometry.angle(platterSeconds: seconds)))
        if let beat = beatInBar {
          ForEach(0..<4, id: \.self) { i in
            let p = PlatterGeometry.rimDot(i, of: 4, size: size, inset: 12)
            Circle().fill(i == beat ? tint : .gray.opacity(0.35))
              .frame(width: i == 0 ? 10 : 7, height: i == 0 ? 10 : 7)
              .scaleEffect(i == beat ? 1.25 : 1)
              .animation(.easeOut(duration: 0.12), value: beat)
              .position(p)
          }
        }
      }
      .frame(width: size, height: size)
      .position(x: g.size.width / 2, y: g.size.height / 2)
    }
  }
}

/// Tempo readout with the beat-in-bar dots.
public struct BeatStripView: View {
  public var bpm: Double?
  public var beatInBar: Int
  public var scrubbing: Bool
  public var tint: Color

  public init(bpm: Double?, beatInBar: Int, scrubbing: Bool, tint: Color) {
    self.bpm = bpm
    self.beatInBar = beatInBar
    self.scrubbing = scrubbing
    self.tint = tint
  }

  public var body: some View {
    HStack(spacing: 6) {
      if let bpm {
        Text(String(format: "%.1f BPM", bpm)).font(.caption.monospacedDigit())
        ForEach(0..<4, id: \.self) { i in
          Circle()
            .fill(i == beatInBar ? tint : .gray.opacity(0.35))
            .frame(width: i == 0 ? 10 : 7, height: i == 0 ? 10 : 7)
        }
      } else {
        Text("no tempo").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if scrubbing { Text("SCRATCH").font(.caption.bold()).foregroundStyle(tint) }
    }
  }
}
