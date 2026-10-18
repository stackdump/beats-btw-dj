import DJCore
import SwiftUI

// The FX unit panel (FxUnit.swift): hands-on, live control of a target's master chain — deck A, deck
// B or the loops' L — and a net deck's room and echo sends. One panel, under the deck row, aimed by
// its target buttons (it follows the focus deck until one is picked). It lives there rather than in
// each deck's sections or the mixer column because it needs width (a big filter knob, an XY pad,
// eleven knobs and the macros side by side) that the 160–220 pt mixer and the 260 pt deck columns
// don't have, and one full-width card lays out the same in the wide and the stacked window.
//
// Every move is a poke through `DJEngine.perform` (`DeckAction.fx`, `.fxReset`, `.fxKill`); a
// dragged knob is recorded at most 30 times a second (`FxUnitCoalescer`), its last value always.

/// One target's FX unit, for SwiftUI.
struct FxUnitState: Equatable {
  var settings = FxUnitSettings()
  var controls: Set<FxParam> = Set(FxParam.chain)
  /// Why each missing control is missing.
  var missing: [FxParam: String] = [:]
  var running: Set<MasterMacro> = []
  /// "net deck", "sample deck", "loops".
  var kind = "sample deck"
}

extension AppModel {
  /// The targets the panel offers, in order.
  static let fxTargets = ["A", "B", "L"]

  /// Where the panel aims: the picked target, else the focus.
  var fxTargetName: String {
    let t = fxTarget ?? fxFocus
    return Self.fxTargets.contains(t) ? t : "A"
  }

  static func fxTint(_ name: String) -> Color {
    switch name {
    case "A": DJStyle.deckA
    case "B": DJStyle.deckB
    default: LoopRowView.tint
    }
  }

  var fxTint: Color { Self.fxTint(fxTargetName) }

  func setShowFxUnit(_ on: Bool) {
    showFxUnit = on
    defaults.set(on, forKey: Self.showFxUnitKey)
  }

  /// Aim the panel (nil: follow the focus).
  func setFxTarget(_ name: String?) { fxTarget = name }

  func pollFxUnit(_ dj: DJEngine, now: Double) {
    if dj.focus != fxFocus { fxFocus = dj.focus }
    for (key, v) in fxCoalescer.due(now: now) { performFx(key, v) }
    var out: [String: FxUnitState] = [:]
    for name in Self.fxTargets {
      guard let d = dj[name] else { continue }
      var missing: [FxParam: String] = [:]
      for p in FxParam.allCases { if let why = d.fxUnitMissing(p) { missing[p] = why } }
      out[name] = FxUnitState(
        settings: d.fxUnit, controls: d.fxUnitControls, missing: missing,
        running: Set(d.activeMasterMacros),
        kind: name == dj.loopChannel.name ? "loops" : (d.mode == .net ? "net deck" : "sample deck"))
    }
    if out != fxUnits { fxUnits = out }
  }

  private static func fxKey(_ deck: String, _ p: FxParam) -> String { "\(deck)|\(p.id)" }

  private func performFx(_ key: String, _ v: Double) {
    let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return }
    engine?.perform(.fx(deck: parts[0], param: parts[1], value: v))
  }

  /// A knob or the pad being dragged (`ended`: let go): sent at once, then at most 30 times a
  /// second, and its last value when the hand comes off.
  func fxMove(_ deck: String, _ p: FxParam, _ v: Double, ended: Bool) {
    let key = Self.fxKey(deck, p)
    let v = p.clamp(v)
    if ended {
      _ = fxCoalescer.finish(key)
      if engine?[deck]?.fxUnit[p] != v { performFx(key, v) }
    } else if fxCoalescer.offer(key, v, now: uptime()) {
      performFx(key, v)
    }
    if let dj = engine { pollFxUnit(dj, now: uptime()) }
  }

  /// One control to `v` at once (a double-click's reset to neutral).
  func fxSet(_ deck: String, _ p: FxParam, _ v: Double) { fxMove(deck, p, v, ended: true) }

  /// Every control to neutral and the kill off (on the next beat with `fxOnBeat`).
  func fxReset(_ deck: String) {
    for p in FxParam.allCases { _ = fxCoalescer.finish(Self.fxKey(deck, p)) }
    engine?.perform(.fxReset(deck: deck, onBeat: fxOnBeat))
    if let dj = engine { pollFxUnit(dj, now: uptime()) }
  }

  func fxKill(_ deck: String, _ on: Bool) {
    engine?.perform(.fxKill(deck: deck, on: on, onBeat: fxOnBeat))
    if let dj = engine { pollFxUnit(dj, now: uptime()) }
  }
}

/// The panel: target, kill / reset, the big bipolar filter, the XY pad, the knobs and the macros.
struct FxUnitPanel: View {
  let model: AppModel

  static let help =
    "FX unit: live filter, phaser, crush, drive, pitch and a net deck's room and echo, "
    + "on deck A, B or the loops"

  /// What the pad's vertical axis can move.
  static let yChoices: [FxParam] = [.crush, .drive, .phaserMix, .room, .echo]
  /// The small knobs, two rows.
  static let rows: [[FxParam]] = [
    [.hp, .lp, .phaserMix, .phaserDepth, .phaserRate, .pitch],
    [.crush, .drive, .room, .echo, .feedback],
  ]

  var body: some View {
    let name = model.fxTargetName
    let state = model.fxUnits[name] ?? FxUnitState()
    let tint = model.fxTint
    let s = state.settings
    VStack(alignment: .leading, spacing: DJStyle.m) {
      header(name, state, tint)
      HStack(alignment: .top, spacing: DJStyle.l) {
        VStack(spacing: DJStyle.xs) {
          knob(.filter, name, state, tint, size: 96)
        }
        .frame(width: 112)
        VStack(alignment: .leading, spacing: DJStyle.xs) {
          FxXYPad(
            x: s[.filter], y: s[model.fxY], yParam: model.fxY, tint: tint,
            yEnabled: state.controls.contains(model.fxY), killed: s.killed
          ) { x, y, ended in
            model.fxMove(name, .filter, x, ended: ended)
            if state.controls.contains(model.fxY) { model.fxMove(name, model.fxY, y, ended: ended) }
          } reset: {
            model.fxSet(name, .filter, FxParam.filter.neutral)
            model.fxSet(name, model.fxY, model.fxY.neutral)
          }
          .frame(width: 150, height: 150)
          FlowRow(spacing: 2) {
            ForEach(Self.yChoices, id: \.self) { p in
              ChoiceButton(label: p.label, selected: model.fxY == p, tint: tint) { model.fxY = p }
                .disabled(!state.controls.contains(p))
            }
          }
          .frame(width: 150, alignment: .leading)
        }
        Grid(alignment: .top, horizontalSpacing: DJStyle.s, verticalSpacing: DJStyle.s) {
          ForEach(Self.rows.indices, id: \.self) { r in
            GridRow {
              ForEach(Self.rows[r], id: \.self) { p in knob(p, name, state, tint, size: 44) }
            }
          }
        }
        Spacer(minLength: 0)
      }
      // the master macros, one flowing row (they ride on top of the unit and return to it)
      FlowRow(spacing: 4) {
        Text("MACROS").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.secondary)
          .padding(.trailing, DJStyle.xs)
        ForEach(["FX", "Pitch", "Feel"], id: \.self) { group in
          Text(group).font(.caption2).foregroundStyle(.secondary).padding(.leading, DJStyle.s)
          ForEach(MasterFxPanel.macros(group, isNet: true), id: \.rawValue) { m in
            ChoiceButton(label: m.label, selected: state.running.contains(m), tint: tint) {
              model.fire(name, m)
            }
            .lockable(DJActionKind.lockKey(deck: name, .macro, param: m.id), model)
          }
        }
      }
      footer(state)
    }
  }

  private func header(_ name: String, _ state: FxUnitState, _ tint: Color) -> some View {
    HStack(spacing: DJStyle.m) {
      Text(state.settings.isActive ? "FX UNIT ●" : "FX UNIT").font(DJStyle.sectionLabel)
        .tracking(1.2).foregroundStyle(state.settings.isActive ? tint : .secondary)
      if state.settings.killed {
        Text("KILLED").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.red)
      }
      HStack(spacing: 3) {
        ForEach(AppModel.fxTargets, id: \.self) { t in
          let on = model.fxUnits[t]?.settings.isActive == true
          ChoiceButton(
            label: on ? "\(t) ●" : t, selected: t == name, tint: AppModel.fxTint(t), live: true
          ) { model.setFxTarget(t) }
          .help(t == "L" ? "The loops, after they are mixed" : "Deck \(t)")
        }
      }
      Text(model.fxTarget == nil ? "\(state.kind) · follows focus" : state.kind)
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: DJStyle.s)
      Toggle("On beat", isOn: Binding(get: { model.fxOnBeat }, set: { model.fxOnBeat = $0 }))
        .toggleStyle(.button).controlSize(.small).tint(tint)
        .help("Kill and Reset land on the target's next beat")
      Toggle(
        "Kill",
        isOn: Binding(get: { state.settings.killed }, set: { model.fxKill(name, $0) })
      )
      .toggleStyle(.button).liveButton().tint(.red)
      .help("Bypass the FX unit (its knobs stay where they are); again to bring it back")
      Button("Reset") { model.fxReset(name) }
        .liveButton().disabled(state.settings.isNeutral && !state.settings.killed)
        .help("Every knob back to neutral")
    }
  }

  private func footer(_ state: FxUnitState) -> some View {
    let missing = FxParam.sends.compactMap { state.missing[$0] }
    let note =
      "Live: each move glides over ~30 ms, not quantised. Drag a knob up or down; double-click "
      + "resets it. Macros ride on top of the unit and return to it."
    return Text(missing.isEmpty ? note : note + " Room / echo: " + (missing.first ?? "") + ".")
      .font(.caption2).foregroundStyle(.secondary)
  }

  private func knob(
    _ p: FxParam, _ name: String, _ state: FxUnitState, _ tint: Color, size: CGFloat
  ) -> some View {
    FxKnob(
      param: p, value: state.settings[p], tint: tint, size: size,
      enabled: state.controls.contains(p), dimmed: state.settings.killed
    ) { v, ended in model.fxMove(name, p, v, ended: ended) }
    .help(state.missing[p].map { "\(p.label): \($0)" } ?? "\(p.label) · double-click resets")
  }
}

/// A knob: drag up or down (its whole travel in `travel` points), double-click for neutral. The arc
/// runs from the neutral to the value (a bipolar knob from its top), the value under the label.
struct FxKnob: View {
  let param: FxParam
  let value: Double
  let tint: Color
  var size: CGFloat = 44
  var enabled = true
  /// The unit is killed: drawn faded, still movable.
  var dimmed = false
  let onMove: (Double, Bool) -> Void

  @State private var dragFrom: Double?
  @State private var dragValue: Double?

  private var travel: CGFloat { max(140, size * 2) }

  /// 0…1 along the arc.
  static func fraction(_ p: FxParam, _ v: Double) -> Double {
    let r = p.range
    return (p.clamp(v) - r.lowerBound) / (r.upperBound - r.lowerBound)
  }

  var body: some View {
    let v = dragValue ?? value
    let t = Self.fraction(param, v)
    let n = Self.fraction(param, param.neutral)
    let moved = v != param.neutral
    let line = max(3, size * 0.09)
    VStack(spacing: 2) {
      ZStack {
        Circle().fill(Color.primary.opacity(0.06))
        Circle().trim(from: 0, to: 0.75)
          .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: line, lineCap: .round))
          .rotationEffect(.degrees(135))
        if moved {
          Circle().trim(from: 0.75 * min(t, n), to: 0.75 * max(t, n))
            .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .rotationEffect(.degrees(135))
        }
        // the pointer
        Capsule().fill(moved ? tint : Color.primary.opacity(0.7))
          .frame(width: max(2, size * 0.06), height: size * 0.32)
          .offset(y: -size * 0.2)
          .rotationEffect(.degrees(-135 + 270 * t))
        if param.range.lowerBound < 0 {
          // the centre detent of a bipolar knob
          Circle().fill(Color.primary.opacity(0.5)).frame(width: 3, height: 3)
            .offset(y: -size / 2 - line)
        }
      }
      .padding(line / 2)
      .frame(width: size, height: size)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { g in
            let from = dragFrom ?? value
            if dragFrom == nil { dragFrom = from }
            let span = param.range.upperBound - param.range.lowerBound
            let nv = param.clamp(from - Double(g.translation.height / travel) * span)
            dragValue = nv
            onMove(nv, false)
          }
          .onEnded { _ in
            if let v = dragValue { onMove(v, true) }
            dragFrom = nil
            dragValue = nil
          }
      )
      .onTapGesture(count: 2) { onMove(param.neutral, true) }
      Text(param.label.uppercased()).font(.system(size: size > 60 ? 11 : 9, weight: .semibold))
        .tracking(0.8).foregroundStyle(.secondary).lineLimit(1)
      Text(param.readout(v)).font(.system(size: size > 60 ? 12 : 10).monospacedDigit())
        .foregroundStyle(moved ? tint : .secondary).lineLimit(1).fixedSize()
    }
    .frame(minWidth: max(size + 8, 60))
    .opacity(enabled ? (dimmed ? 0.55 : 1) : 0.3)
    .allowsHitTesting(enabled)
    .accessibilityElement()
    .accessibilityLabel(param.label)
    .accessibilityValue(param.readout(v))
  }
}

/// The XY pad: across, the filter (left LP, centre off, right HP); up, `yParam`. Drag the puck;
/// double-click puts both back.
struct FxXYPad: View {
  let x: Double
  let y: Double
  let yParam: FxParam
  let tint: Color
  var yEnabled = true
  var killed = false
  let onMove: (Double, Double, Bool) -> Void
  let reset: () -> Void

  @State private var drag: CGPoint?

  /// A point in the pad (0…1 each, y up) for the values.
  static func point(x: Double, y: Double, yParam: FxParam) -> (Double, Double) {
    ((FxParam.filter.clamp(x) + 1) / 2, FxKnob.fraction(yParam, y))
  }

  /// The values at a point (0…1 each, y up).
  static func values(_ px: Double, _ py: Double, yParam: FxParam) -> (Double, Double) {
    let r = yParam.range
    let fx = max(0, min(1, px)) * 2 - 1
    // the centre snaps to off within 3 % so the filter can be let go in the middle
    return (abs(fx) < 0.03 ? 0 : fx, r.lowerBound + max(0, min(1, py)) * (r.upperBound - r.lowerBound))
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      let (px, py) = Self.point(x: x, y: y, yParam: yParam)
      let puck = drag ?? CGPoint(x: px * w, y: (1 - py) * h)
      let moved = x != 0 || y != yParam.neutral
      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 8).fill(tint.opacity(moved && !killed ? 0.12 : 0.05))
        // the filter's centre and the quarter lines
        Path { p in
          p.move(to: CGPoint(x: w / 2, y: 0))
          p.addLine(to: CGPoint(x: w / 2, y: h))
        }
        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
        Path { p in
          for f in [0.25, 0.75] {
            p.move(to: CGPoint(x: w * f, y: 0))
            p.addLine(to: CGPoint(x: w * f, y: h))
            p.move(to: CGPoint(x: 0, y: h * f))
            p.addLine(to: CGPoint(x: w, y: h * f))
          }
        }
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        // crosshair and puck
        Path { p in
          p.move(to: CGPoint(x: puck.x, y: 0))
          p.addLine(to: CGPoint(x: puck.x, y: h))
          p.move(to: CGPoint(x: 0, y: puck.y))
          p.addLine(to: CGPoint(x: w, y: puck.y))
        }
        .stroke(tint.opacity(0.35), lineWidth: 1)
        Circle().fill(moved ? tint : Color.primary.opacity(0.55)).frame(width: 16, height: 16)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
          .position(puck)
        Text(yEnabled ? "↑ \(yParam.label.uppercased())" : "↑ \(yParam.label.uppercased()) —")
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(5)
        HStack {
          Text("◀ LP")
          Spacer()
          Text("HP ▶")
        }
        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(5)
        .frame(width: w, height: h, alignment: .bottom)
      }
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.5), lineWidth: 1))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in
            let p = CGPoint(x: max(0, min(w, g.location.x)), y: max(0, min(h, g.location.y)))
            drag = p
            let (vx, vy) = Self.values(Double(p.x / w), Double(1 - p.y / h), yParam: yParam)
            onMove(vx, vy, false)
          }
          .onEnded { g in
            let p = CGPoint(x: max(0, min(w, g.location.x)), y: max(0, min(h, g.location.y)))
            let (vx, vy) = Self.values(Double(p.x / w), Double(1 - p.y / h), yParam: yParam)
            onMove(vx, vy, true)
            drag = nil
          }
      )
      .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
    }
    .help("Across: the filter (left LP, right HP). Up: \(yParam.label). Double-click: both off")
  }
}
