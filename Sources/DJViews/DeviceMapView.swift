import DJCore
import SwiftUI

/// A device's controls and what they do, one row each, grouped. The control that was just
/// touched is highlighted.
public struct DeviceMapList: View {
  public var title: String
  public var rows: [DeviceMapRow]
  public var highlight: (group: String, index: Int)?
  public var tint: Color

  public init(
    title: String, rows: [DeviceMapRow], highlight: (group: String, index: Int)? = nil,
    tint: Color = .orange
  ) {
    self.title = title
    self.rows = rows
    self.highlight = highlight
    self.tint = tint
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
        }
      }
    }
    .padding(8)
  }
}

/// Scrollable device map with a picker for the device.
public struct DeviceMapView: View {
  public var maps: [(name: String, rows: [DeviceMapRow])]
  public var highlight: (device: String, group: String, index: Int)?
  @State private var selected: String

  public init(
    maps: [(name: String, rows: [DeviceMapRow])],
    highlight: (device: String, group: String, index: Int)?
  ) {
    self.maps = maps
    self.highlight = highlight
    _selected = State(initialValue: maps.first?.name ?? "")
  }

  public var body: some View {
    VStack(alignment: .leading) {
      Picker("Device", selection: $selected) {
        ForEach(maps, id: \.name) { Text($0.name).tag($0.name) }
      }
      .pickerStyle(.segmented)
      if let m = maps.first(where: { $0.name == selected }) {
        ScrollView {
          DeviceMapList(
            title: m.name, rows: m.rows,
            highlight: highlight?.device == m.name ? (highlight!.group, highlight!.index) : nil)
        }
      }
    }
    .padding(8)
  }
}
