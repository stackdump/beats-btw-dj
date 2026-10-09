import Foundation

/// A guided check of one device's controls: the target is each control of the profile in
/// turn; the user moves it and the walk records whether that control (and not another) fired.
public struct ControlWalk: Sendable {
  public enum Outcome: Equatable, Sendable {
    case ok
    /// Skipped with nothing heard: the control sends nothing the app sees.
    case skipped
    /// Skipped after a different control fired, e.g. "mixer.faders[0]".
    case heardInstead(String)
  }

  public let device: String
  public let rows: [DeviceMapRow]
  public private(set) var position = 0
  public private(set) var outcomes: [String: Outcome] = [:]
  /// The last other control heard while waiting for the current target.
  public private(set) var heard: String?
  private var lastDone: String?

  public init(device: String, rows: [DeviceMapRow]) {
    self.device = device
    self.rows = rows
  }

  public static func key(_ group: String, _ index: Int) -> String { "\(group)[\(index)]" }

  public var current: DeviceMapRow? { rows.indices.contains(position) ? rows[position] : nil }
  public var isDone: Bool { position >= rows.count }

  /// A control fired. Returns true when it was the target (the walk advances).
  @discardableResult
  public mutating func feed(group: String, index: Int) -> Bool {
    guard let row = current else { return false }
    let k = Self.key(group, index)
    if group == row.group && index == row.index {
      outcomes[k] = .ok
      lastDone = k
      heard = nil
      position += 1
      return true
    }
    // A fader that was just finished keeps streaming for a moment; that is not news.
    if k != lastDone { heard = k }
    return false
  }

  /// Give up on the current target (it sends nothing, or the user can't find it).
  public mutating func skip() {
    guard let row = current else { return }
    outcomes[Self.key(row.group, row.index)] = heard.map { .heardInstead($0) } ?? .skipped
    heard = nil
    lastDone = nil
    position += 1
  }

  public mutating func back() {
    guard position > 0 else { return }
    position -= 1
    let r = rows[position]
    outcomes[Self.key(r.group, r.index)] = nil
    heard = nil
    lastDone = nil
  }

  public func outcome(group: String, index: Int) -> Outcome? {
    outcomes[Self.key(group, index)]
  }

  public var counts: (ok: Int, skipped: Int, wrong: Int) {
    var c = (ok: 0, skipped: 0, wrong: 0)
    for o in outcomes.values {
      switch o {
      case .ok: c.ok += 1
      case .skipped: c.skipped += 1
      case .heardInstead: c.wrong += 1
      }
    }
    return c
  }

  /// One line per control that did not check out, then the totals.
  public var report: String {
    var lines = ["control walk · \(device)"]
    for r in rows {
      let k = Self.key(r.group, r.index)
      let num = r.number.map { " (\($0))" } ?? ""
      switch outcomes[k] {
      case .ok: lines.append("ok       \(k) \(r.control)\(num) — \(r.action)")
      case .skipped: lines.append("SILENT   \(k) \(r.control)\(num) — \(r.action)")
      case .heardInstead(let other):
        lines.append("WRONG    \(k) \(r.control)\(num) — \(r.action) · heard \(other) instead")
      case nil: lines.append("not run  \(k) \(r.control)\(num)")
      }
    }
    let c = counts
    lines.append("ok \(c.ok) · silent \(c.skipped) · wrong \(c.wrong) of \(rows.count)")
    return lines.joined(separator: "\n")
  }
}
