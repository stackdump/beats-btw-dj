import DJCore
import SwiftUI

/// Every controller drawn as it looks (`ControllerLayout`), each control labelled with what it
/// is bound to, in its LED colour, outlined while just touched. Hover a control for all its
/// bindings (one per pad mode / shift layer). Dashed: parked on purpose; "?": a binding not
/// yet seen on a real unit (`[MIXXX]` / `[UNVERIFIED]`).
struct ControllersView: View {
  let model: AppModel
  /// Points per layout unit.
  var unit: CGFloat = 30

  var body: some View {
    FlowRow(spacing: DJStyle.l) {
      ForEach(ControllerLayout.all, id: \.profileName) { layout in
        ControllerCard(
          layout: layout, unit: unit,
          attached: model.devices.contains { $0.profile == layout.profileName },
          lights: model.deviceLights[layout.profileName],
          touched: model.lastControl.flatMap {
            $0.device == layout.profileName && Date().timeIntervalSince($0.at) < 1.5
              ? ($0.group, $0.index) : nil
          })
      }
    }
  }
}

struct ControllerCard: View {
  let layout: ControllerLayout
  let unit: CGFloat
  let attached: Bool
  let lights: DeviceLights?
  let touched: (group: String, index: Int)?

  private var profile: SurfaceProfile? {
    SurfaceProfile.all.first { $0.name == layout.profileName }
  }

  var body: some View {
    let rows = Dictionary(
      (profile?.deviceMap() ?? []).map { ("\($0.group)/\($0.index)", $0) },
      uniquingKeysWith: { a, _ in a })
    VStack(alignment: .leading, spacing: DJStyle.s) {
      HStack(spacing: DJStyle.s) {
        Circle().fill(attached ? Color.green : Color.secondary.opacity(0.4)).frame(
          width: 8, height: 8)
        Text(layout.title).font(.headline)
        Text(attached ? "connected" : "not connected").font(.caption).foregroundStyle(.secondary)
      }
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.11))
        ForEach(Array(layout.spots.enumerated()), id: \.offset) { _, spot in
          SpotView(
            spot: spot, unit: unit, rows: rows, profile: profile, lights: lights,
            touched: touched.map { t in
              spot.bindings.contains { $0.group == t.group && $0.index == t.index }
            }
              ?? false)
        }
      }
      .frame(width: layout.width * unit + unit * 0.4, height: layout.height * unit + unit * 0.4)
    }
    .padding(DJStyle.s)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
  }
}

/// One control: its shape, its LED, its binding.
struct SpotView: View {
  let spot: ControlSpot
  let unit: CGFloat
  let rows: [String: DeviceMapRow]
  let profile: SurfaceProfile?
  let lights: DeviceLights?
  let touched: Bool

  /// The bindings this control has, with a row each (modes that have no control in the
  /// profile are left out).
  private var bound: [(mode: String?, row: DeviceMapRow, group: String, index: Int)] {
    spot.bindings.compactMap { b in
      rows["\(b.group)/\(b.index)"].map { (b.mode, $0, b.group, b.index) }
    }
  }

  var body: some View {
    let first = bound.first
    let swatch = first.flatMap { lights?.swatch(group: $0.group, index: $0.index) }
    let lit = swatch?.lit == true
    let parked = first?.row.parked ?? spot.bindings.isEmpty
    let unverified =
      first.map { profile?.isUnverified(group: $0.group, index: $0.index) ?? false } ?? false
    let w = spot.w * unit
    let h = spot.h * unit
    ZStack {
      shape
        .fill(lit ? swatch!.color.color.opacity(max(0.35, swatch!.opacity)) : Color(white: 0.2))
      shape
        .stroke(
          touched ? Color.white : Color.white.opacity(parked ? 0.25 : 0.4),
          style: StrokeStyle(lineWidth: touched ? 2.5 : 1, dash: parked && !touched ? [3, 2] : []))
      if spot.kind == .keyboard { keys }
      VStack(spacing: 0) {
        if let c = spot.caption, spot.kind != .pad || first == nil {
          Text(c).font(.system(size: max(6, unit * 0.2), weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
        }
        if let first, spot.kind != .jog {
          Text(label(first.row.action) + (unverified ? "?" : ""))
            .font(.system(size: max(7, unit * 0.24), weight: .medium))
            .foregroundStyle(lit ? Color.black : (parked ? Color.white.opacity(0.4) : Color.white))
          // a pad with more than one mode: the next one too (Inpulse LOOP mode, MPK NOTE mode)
          if spot.kind == .pad, let second = bound.dropFirst().first(where: { !$0.row.parked }) {
            Text("\(second.mode ?? ""): \(label(second.row.action))")
              .font(.system(size: max(6, unit * 0.18)))
              .foregroundStyle(lit ? Color.black.opacity(0.7) : Color.white.opacity(0.6))
          }
        }
      }
      .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.5)
      .padding(2)
      .frame(maxHeight: .infinity, alignment: spot.kind == .keyboard ? .top : .center)
    }
    .frame(width: w, height: h)
    .contentShape(Rectangle())
    .help(helpText)
    .offset(x: spot.x * unit + unit * 0.2, y: spot.y * unit + unit * 0.2)
  }

  /// The short binding, without its deck letter on a control that belongs to one deck (an
  /// Inpulse deck's own buttons: the side says which).
  private func label(_ action: String) -> String {
    let s = Self.short(action)
    let ownDeck = spot.bindings.allSatisfy {
      $0.group.hasPrefix("deckA.") || $0.group.hasPrefix("deckB.")
    }
    return ownDeck && (s.hasPrefix("A ") || s.hasPrefix("B ")) ? String(s.dropFirst(2)) : s
  }

  private var shape: AnyShape {
    switch spot.kind {
    case .knob, .jog, .joystick, .encoder: AnyShape(Circle())
    case .fader: AnyShape(Capsule())
    default: AnyShape(RoundedRectangle(cornerRadius: unit * 0.12))
    }
  }

  /// 25 keys from C: white keys, black keys over them.
  private var keys: some View {
    GeometryReader { g in
      let whites = 15
      let ww = g.size.width / CGFloat(whites)
      ZStack(alignment: .topLeading) {
        ForEach(0..<whites, id: \.self) { i in
          Rectangle().fill(Color.white.opacity(0.85)).frame(
            width: ww - 1, height: g.size.height * 0.62
          )
          .offset(x: CGFloat(i) * ww, y: g.size.height * 0.38)
        }
        ForEach((0..<whites - 1).filter { [0, 1, 3, 4, 5].contains($0 % 7) }, id: \.self) { i in
          Rectangle().fill(Color.black).frame(width: ww * 0.6, height: g.size.height * 0.38)
            .offset(x: CGFloat(i) * ww + ww * 0.7, y: g.size.height * 0.38)
        }
      }
    }
    .allowsHitTesting(false)
  }

  private var helpText: String {
    let lines = bound.map { b in
      var s = (b.mode.map { "\($0): " } ?? "") + b.row.action
      if let sh = b.row.shiftedAction { s += " (SHIFT: \(sh))" }
      if profile?.isUnverified(group: b.group, index: b.index) == true { s += " — unverified" }
      return s + "  [\(b.group) \(b.row.control)]"
    }
    return ([spot.caption].compactMap { $0 } + lines).joined(separator: "\n")
  }

  /// A binding in a few characters: "section 3 · deck A" → "A sec 3".
  static func short(_ action: String) -> String {
    if action.hasPrefix("unbound") { return "—" }
    if action == "unmapped" { return "?" }
    var s = action
    var deck = ""
    if let r = s.range(of: " · deck ") {
      deck = String(s[r.upperBound...])
      s = String(s[..<r.lowerBound])
    }
    let swaps: [(String, String)] = [
      ("hot cue ", "cue "), ("clear cue ", "clr "), ("section ", "sec "), ("macro ", ""),
      ("mute ", "✕ "), ("previous section", "sec ◀"), ("next section", "sec ▶"),
      ("headphone cue", "🎧"), ("loop record (hold)", "LOOP rec"), (" in/out", ""),
      ("STEMS music (mute group)", "−music"), ("STEMS mic (mute group)", "−lead"),
      ("live keys (focus deck)", "live keys"), ("tempo nudge (focus deck)", "nudge"),
      ("loop seed ± (playing loop)", "seed ±"), ("stinger ", "sting "),
    ]
    for (a, b) in swaps { s = s.replacingOccurrences(of: a, with: b) }
    return deck.isEmpty ? s : "\(deck) \(s)"
  }
}
