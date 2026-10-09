import DJCore
import SwiftUI

/// The guided control check: the target control blinks in the map; move it on the device.
public struct WalkPanel: View {
  public var walk: ControlWalk
  public var reportPath: String?
  public var skip: () -> Void
  public var back: () -> Void
  public var stop: () -> Void

  public init(
    walk: ControlWalk, reportPath: String? = nil, skip: @escaping () -> Void,
    back: @escaping () -> Void, stop: @escaping () -> Void
  ) {
    self.walk = walk
    self.reportPath = reportPath
    self.skip = skip
    self.back = back
    self.stop = stop
  }

  var marks: [String: String] {
    var m: [String: String] = [:]
    for (k, o) in walk.outcomes {
      switch o {
      case .ok: m[k] = "✓"
      case .skipped: m[k] = "–"
      case .heardInstead: m[k] = "✗"
      }
    }
    return m
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      TimelineView(.periodic(from: .now, by: 0.4)) { ctx in
        let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0
        ScrollViewReader { proxy in
          ScrollView {
            DeviceMapList(
              title: walk.device, rows: walk.rows,
              highlight: on ? walk.current.map { ($0.group, $0.index) } : nil,
              tint: .yellow, marks: marks)
          }
          .onChange(of: walk.position) { _, _ in
            if let c = walk.current {
              proxy.scrollTo(ControlWalk.key(c.group, c.index), anchor: .center)
            }
          }
        }
      }
    }
    .padding(8)
  }

  @ViewBuilder var header: some View {
    if let c = walk.current {
      VStack(alignment: .leading, spacing: 2) {
        Text("Move: \(c.control)  ·  \(c.group)[\(c.index)]\(c.number.map { "  (#\($0))" } ?? "")")
          .font(.headline)
        Text(c.action + (c.shiftedAction.map { "   ⇧ " + $0 } ?? ""))
          .font(.caption).foregroundStyle(.secondary)
        if let h = walk.heard {
          Text("heard \(h) instead — keep looking, or Skip if this one is silent")
            .font(.caption).foregroundStyle(.orange)
        }
      }
    } else {
      let c = walk.counts
      VStack(alignment: .leading, spacing: 2) {
        Text("Done — ok \(c.ok) · silent \(c.skipped) · wrong \(c.wrong)").font(.headline)
        if let reportPath { Text("report: \(reportPath)").font(.caption).textSelection(.enabled) }
      }
    }
    HStack {
      Text("\(min(walk.position + 1, walk.rows.count)) / \(walk.rows.count)").font(.caption)
      Button("Back", action: back).disabled(walk.position == 0)
      Button("Skip (silent)", action: skip).disabled(walk.isDone)
      Button("Stop", action: stop)
    }
  }
}
