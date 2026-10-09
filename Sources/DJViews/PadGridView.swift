import DJCore
import SwiftUI

/// The APC mini mk2's colour for a palette index: device-map.js's `PALETTE` for the indices
/// beats draws (`APCPalette`, in DJCore, pinned there), and a hue guess for any other so a
/// stray index still shows something rather than nothing.
public enum AkaiPalette {
  public static func rgb(_ index: UInt8) -> (r: Double, g: Double, b: Double) {
    let c = APCPalette.color(index)
    return (c.r, c.g, c.b)
  }
}

/// Where the parts of the mirror sit, so a click can be turned back into a control.
public struct PadGridGeometry: Equatable, Sendable {
  public var size: CGSize
  /// 8 pad columns + the scene column, 8 pad rows + the track row.
  public var cell: CGFloat { min(size.width / 9, size.height / 9) }

  public init(size: CGSize) { self.size = size }

  /// Frame of pad `i` (0 = bottom-left, +1 right, +8 up).
  public func padRect(_ i: Int) -> CGRect {
    let col = i % 8
    let row = i / 8  // 0 = bottom
    return CGRect(x: CGFloat(col) * cell, y: CGFloat(7 - row) * cell, width: cell, height: cell)
  }
  /// Track buttons sit under the grid.
  public func trackRect(_ i: Int) -> CGRect {
    CGRect(x: CGFloat(i) * cell, y: 8 * cell, width: cell, height: cell)
  }
  /// Scene buttons right of the grid, index 0 at the top.
  public func sceneRect(_ i: Int) -> CGRect {
    CGRect(x: 8 * cell, y: CGFloat(i) * cell, width: cell, height: cell)
  }

  /// The control under a point: ("pads" | "track" | "scene", index).
  public func control(at p: CGPoint) -> (group: String, index: Int)? {
    for i in 0..<64 where padRect(i).contains(p) { return ("pads", i) }
    for i in 0..<8 where trackRect(i).contains(p) { return ("track", i) }
    for i in 0..<8 where sceneRect(i).contains(p) { return ("scene", i) }
    return nil
  }
}

/// A live copy of the APC's LEDs. Click a pad to press it.
public struct PadGridView: View {
  public var pads: [PadLight]
  public var tracks: [PadLight]
  public var scenes: [PadLight]
  public var onPress: (String, Int) -> Void

  public init(
    pads: [PadLight], tracks: [PadLight], scenes: [PadLight],
    onPress: @escaping (String, Int) -> Void = { _, _ in }
  ) {
    self.pads = pads
    self.tracks = tracks
    self.scenes = scenes
    self.onPress = onPress
  }

  public var body: some View {
    GeometryReader { g in
      let geo = PadGridGeometry(size: g.size)
      Canvas { ctx, _ in
        func rgb(_ l: PadLight) -> Color {
          let c = AkaiPalette.rgb(l.colorIndex)
          let k: Double = l.level == .full ? 1 : (l.level == .dim ? 0.28 : 0)
          return Color(red: c.r * k, green: c.g * k, blue: c.b * k)
        }
        func single(_ l: PadLight, _ on: Color) -> Color {
          switch l.level {
          case .off: return .gray.opacity(0.18)
          case .dim: return on.opacity(0.4)
          case .full, .blink: return on
          }
        }
        for i in 0..<min(64, pads.count) {
          let r = geo.padRect(i).insetBy(dx: 2, dy: 2)
          let base = pads[i].level == .off ? Color.gray.opacity(0.18) : rgb(pads[i])
          ctx.fill(
            Path(roundedRect: r, cornerRadius: 4),
            with: .color(pads[i].colorIndex == 0 ? Color.gray.opacity(0.18) : base))
        }
        for i in 0..<min(8, tracks.count) {
          ctx.fill(
            Path(roundedRect: geo.trackRect(i).insetBy(dx: 4, dy: 8), cornerRadius: 3),
            with: .color(single(tracks[i], .red)))
        }
        for i in 0..<min(8, scenes.count) {
          ctx.fill(
            Path(roundedRect: geo.sceneRect(i).insetBy(dx: 8, dy: 4), cornerRadius: 3),
            with: .color(single(scenes[i], .green)))
        }
      }
      .contentShape(Rectangle())
      .gesture(
        SpatialTapGesture().onEnded { tap in
          if let c = geo.control(at: tap.location) { onPress(c.group, c.index) }
        })
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityLabel("APC mini grid")
  }
}
