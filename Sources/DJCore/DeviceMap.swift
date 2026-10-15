import Foundation

/// One control of a device and what it does, in words.
public struct DeviceMapRow: Equatable, Sendable {
  public var group: String
  public var index: Int
  /// The control's name from the profile, or its number.
  public var control: String
  /// MIDI note / CC number (nil for pitch bend, program change).
  public var number: Int?
  /// What it does with the shift layer off, and with it held (nil: same).
  public var action: String
  public var shiftedAction: String?
  public var parked: Bool

  public init(
    group: String, index: Int, control: String, number: Int?, action: String,
    shiftedAction: String?, parked: Bool
  ) {
    self.group = group
    self.index = index
    self.control = control
    self.number = number
    self.action = action
    self.shiftedAction = shiftedAction
    self.parked = parked
  }
}

extension SurfaceProfile.Binding {
  /// A human description: "volume · deck A", "section 3 · deck B", "unbound — needs BPM".
  public var summary: String {
    let on = deck.map { " · deck \($0)" } ?? ""
    switch action {
    case .unbound: return "unbound" + (reason.map { " — \($0)" } ?? "")
    case .hotcue: return "hot cue \((slot ?? 0) + 1)\(on)"
    case .clearcue: return "clear cue \((slot ?? 0) + 1)\(on)"
    case .section: return "section \((slot ?? 0) + 1)\(on)"
    case .sectionPrev: return "previous section\(on)"
    case .sectionNext: return "next section\(on)"
    case .roleMute: return "mute \(role ?? "?")\(on)"
    case .macro: return "macro \(macro ?? "?")\(on)"
    case .stinger: return "stinger \((slot ?? 0) + 1)\(on)"
    case .sync: return (slot == 1 ? "sync to bar" : "sync") + on
    case .pfl: return "headphone cue\(on)"
    case .loopIn: return "loop in\(on)"
    case .loopOut: return "loop out\(on)"
    case .loopHalve: return "loop ÷2\(on)"
    case .loopDouble: return "loop ×2\(on)"
    case .eqLow: return "EQ low\(on)"
    case .eqMid: return "EQ mid\(on)"
    case .eqHigh: return "EQ high\(on)"
    case .headphoneMix: return "headphone mix"
    case .headphoneLevel: return "headphone level"
    case .nextTrack: return "next track\(on)"
    case .keys: return "live keys (focus deck)"
    case .nudge: return "tempo nudge (focus deck)"
    case .seedStep: return "loop seed ± (playing loop)"
    case .shift: return "SHIFT"
    default: return action.rawValue + on
    }
  }
}

extension SurfaceProfile {
  /// Every control of the device with its action(s), grouped in profile order.
  public func deviceMap() -> [DeviceMapRow] {
    var rows: [DeviceMapRow] = []
    for g in groups {
      let nums = g.controlNumbers
      let count = g.type == .pitchbend ? 1 : nums.count
      for i in 0..<count {
        let candidates = layout.filter { $0.group == g.id && ($0.index == i || $0.index == nil) }
        let exactFirst = candidates.sorted { ($0.index != nil ? 0 : 1) < ($1.index != nil ? 0 : 1) }
        let plain = exactFirst.first { $0.shift == nil || $0.shift == false }
        let shifted = exactFirst.first { $0.shift == true }
        let action = plain?.summary ?? shifted?.summary ?? "unmapped"
        let shiftedText =
          (plain?.shift == false || plain?.shift == nil) && shifted != nil ? shifted?.summary : nil
        rows.append(
          DeviceMapRow(
            group: g.id, index: i, control: g.name(i) ?? "#\(i)",
            number: nums.indices.contains(i) ? Int(nums[i]) : nil,
            action: action, shiftedAction: shiftedText,
            parked: (plain ?? shifted)?.action == .unbound))
      }
    }
    return rows
  }
}
