import DJCore
import SwiftUI

// A loop's after effects (`LoopFX`, DJCore/Audio/LoopFx.swift), as the Soundboard's Settings…
// and the Loops row tile's FX popover both show them. Every change is the one poke
// `DeckAction.clipFx` with the whole value (`AppModel.setClipFx`), so the journal and a replay
// see exactly what was heard. The clip's audio stays dry.

/// The FX controls: presets, bypass and auto-level, drive, the shaper and its amount (bits and
/// rate for crush), tone, mix and trim.
struct ClipFxEditor: View {
  let clip: ClipState
  let model: AppModel

  private func set(_ change: (inout LoopFX) -> Void) {
    var f = clip.fx
    change(&f)
    model.setClipFx(clip.id, f)
  }

  private func slider(
    _ label: String, _ key: WritableKeyPath<LoopFX, Double>, _ range: ClosedRange<Double>
  ) -> some View {
    LabeledSlider(
      label: label,
      value: Binding(get: { clip.fx[keyPath: key] }, set: { v in set { $0[keyPath: key] = v } }),
      range: range)
  }

  var body: some View {
    let fx = clip.fx
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 3) {
        ForEach(LoopFX.presets, id: \.name) { p in
          ChoiceButton(label: p.name, selected: fx == p.fx, tint: ClipFxBadge.tint) {
            model.setClipFx(clip.id, p.fx)
          }
        }
      }
      HStack(spacing: DJStyle.xs) {
        Toggle("Bypass", isOn: Binding(get: { fx.bypass }, set: { v in set { $0.bypass = v } }))
          .tint(.orange).help("Hear the loop dry, keeping these settings")
        Toggle(
          "Auto-level",
          isOn: Binding(get: { fx.autoLevel }, set: { v in set { $0.autoLevel = v } })
        )
        .tint(ClipFxBadge.tint)
        .help("Keep the loop's level where it was while drive and distortion push it")
        Spacer(minLength: 0)
        Text(fx.summary).font(.caption2).lineLimit(1)
          .foregroundStyle(fx.isActive ? ClipFxBadge.tint : .secondary)
      }
      .toggleStyle(.button).controlSize(.small)
      slider(String(format: "Drive +%.0f dB", fx.drive), \.drive, LoopFX.driveRange)
      HStack(spacing: 3) {
        Text("Shape").font(.caption).foregroundStyle(.secondary)
          .frame(width: 72, alignment: .leading)
        ForEach(LoopFXMode.allCases, id: \.self) { m in
          ChoiceButton(label: m.label, selected: fx.mode == m, tint: ClipFxBadge.tint) {
            set { $0.mode = m }
          }
        }
      }
      if fx.mode != .clean {
        slider(String(format: "Amount %.0f%%", fx.amount * 100), \.amount, 0...1)
      }
      if fx.mode == .crush {
        slider(String(format: "Bits %.0f", fx.bits), \.bits, LoopFX.bitsRange)
        HStack {
          Text("Rate ÷\(fx.downsample)").font(.caption).foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading).monospacedDigit()
          Stepper(
            "", value: Binding(get: { fx.downsample }, set: { v in set { $0.downsample = v } }),
            in: LoopFX.downsampleRange
          )
          .labelsHidden().controlSize(.small)
          Spacer(minLength: 0)
        }
      }
      let tone = fx.tone >= 1 ? "Tone open" : String(format: "Tone %.0f%%", fx.tone * 100)
      slider(tone, \.tone, 0...1)
      slider(String(format: "Mix %.0f%%", fx.mix * 100), \.mix, 0...1)
      slider(String(format: "Trim %+.1f dB", fx.trim), \.trim, LoopFX.trimRange)
      Text(
        "Played on top of the loop, never into it: the recording stays dry. A safety limiter on "
          + "the loop channel keeps extra gain from clipping."
      )
      .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The small "FX" mark on a pad or tile whose loop has FX on.
struct ClipFxBadge: View {
  static let tint = Color(red: 1.0, green: 0.42, blue: 0.2)
  let fx: LoopFX

  var body: some View {
    Text("FX").font(.caption2.bold()).padding(.horizontal, 3)
      .foregroundStyle(Color.black)
      .background(RoundedRectangle(cornerRadius: 3).fill(Self.tint))
      .help(fx.summary)
      .accessibilityLabel("FX: \(fx.summary)")
  }
}

/// The FX presets as a menu (a pad's and a tile's right-click), the current one ticked.
struct ClipFxMenu: View {
  let fx: LoopFX
  let pick: (LoopFX) -> Void

  private func bypassed(_ on: Bool) -> LoopFX {
    var f = fx
    f.bypass = on
    return f
  }

  var body: some View {
    Menu("FX") {
      ForEach(LoopFX.presets, id: \.name) { p in
        Toggle(p.name, isOn: Binding(get: { fx == p.fx }, set: { _ in pick(p.fx) }))
      }
      if fx != LoopFX() {
        Divider()
        Toggle("Bypass", isOn: Binding(get: { fx.bypass }, set: { pick(bypassed($0)) }))
      }
    }
  }
}
