import DJCore
import SwiftUI

/// A device's controls and what they do, one row each, grouped. The control that was just
/// touched is highlighted.
public struct DeviceMapList: View {
  public var title: String
  public var rows: [DeviceMapRow]
  public var highlight: (group: String, index: Int)?
  public var tint: Color
  /// A leading mark per control, keyed `group[index]` (the control walk's ✓ / ✗).
  public var marks: [String: String]
  /// What the controller's LEDs show right now (SPEC 25, device-map.js `paint`): a dot per
  /// control that has an LED, in its colour and brightness, blinking where it blinks. Nil for a
  /// controller that is not attached or has no LEDs: the list is as it was.
  public var lights: DeviceLights?
  /// Seconds on a steady clock, for the blink; the host animates it.
  public var blinkTime: Double

  public init(
    title: String, rows: [DeviceMapRow], highlight: (group: String, index: Int)? = nil,
    tint: Color = .orange, marks: [String: String] = [:], lights: DeviceLights? = nil,
    blinkTime: Double = 0
  ) {
    self.title = title
    self.rows = rows
    self.highlight = highlight
    self.tint = tint
    self.marks = marks
    self.lights = lights
    self.blinkTime = blinkTime
  }

  /// Rows by group, in the order the profile lists the groups.
  var grouped: [(group: String, rows: [DeviceMapRow])] {
    var order: [String] = []
    var by: [String: [DeviceMapRow]] = [:]
    for r in rows {
      if by[r.group] == nil { order.append(r.group) }
      by[r.group, default: []].append(r)
    }
    return order.map { ($0, by[$0]!) }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.headline)
      ForEach(grouped, id: \.group) { g in
        Text(g.group).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
        ForEach(g.rows, id: \.index) { r in
          let hot = highlight?.group == r.group && highlight?.index == r.index
          HStack(spacing: 6) {
            Text(marks[ControlWalk.key(r.group, r.index)] ?? " ").frame(width: 14)
            if let lights {
              LEDDot(swatch: lights.swatch(group: r.group, index: r.index), time: blinkTime)
            }
            Text(r.control).frame(width: 90, alignment: .leading)
            Text(r.number.map(String.init) ?? "").foregroundStyle(.secondary).frame(
              width: 28, alignment: .trailing)
            Text(r.action).foregroundStyle(r.parked ? .secondary : .primary)
            if let s = r.shiftedAction {
              Text("⇧ " + s).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(.horizontal, 4)
          .background(hot ? tint.opacity(0.8) : Color.clear)
          .id(ControlWalk.key(r.group, r.index))
        }
      }
    }
    .padding(8)
  }
}

/// One LED of a controller as a small dot: its colour at its brightness, a faint dark dot when
/// off, nothing (just the space) for a control that has no LED.
struct LEDDot: View {
  var swatch: LEDSwatch?
  var time: Double

  static let size: CGFloat = 10

  var body: some View {
    ZStack {
      if let s = swatch {
        Circle().fill(s.color.color).opacity(s.opacity(at: time))
        Circle().strokeBorder(Color.primary.opacity(s.lit ? 0.3 : 0.25), lineWidth: 0.5)
      }
    }
    .frame(width: Self.size, height: Self.size)
  }
}

/// Scrollable device map with a picker for the device. With `lights`, every control that has an
/// LED shows what that LED is doing, live.
public struct DeviceMapView: View {
  public var maps: [(name: String, rows: [DeviceMapRow])]
  public var highlight: (device: String, group: String, index: Int)?
  /// The LEDs of each attached controller, by profile name.
  public var lights: [String: DeviceLights]
  @State private var selected: String

  public init(
    maps: [(name: String, rows: [DeviceMapRow])],
    highlight: (device: String, group: String, index: Int)?,
    lights: [String: DeviceLights] = [:]
  ) {
    self.maps = maps
    self.highlight = highlight
    self.lights = lights
    _selected = State(initialValue: maps.first?.name ?? "")
  }

  public var body: some View {
    VStack(alignment: .leading) {
      Picker("Device", selection: $selected) {
        ForEach(maps, id: \.name) { Text($0.name).tag($0.name) }
      }
      .pickerStyle(.segmented)
      if let m = maps.first(where: { $0.name == selected }) {
        let mine = lights[m.name]
        // the clock only runs while an LED blinks
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !(mine?.anyBlinking ?? false))) {
          timeline in
          ScrollView {
            DeviceMapList(
              title: m.name, rows: m.rows,
              highlight: highlight?.device == m.name ? (highlight!.group, highlight!.index) : nil,
              lights: mine, blinkTime: timeline.date.timeIntervalSinceReferenceDate)
          }
        }
      }
    }
    .padding(8)
  }
}
