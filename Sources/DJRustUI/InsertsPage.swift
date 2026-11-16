import DJRust
import SwiftUI

// Insert effects on one target at a time (djandroid ui/InsertsPage.kt): pick Deck A, Deck B, the
// Wheel or the Master, then switch its filter, bitcrush, delay and reverb on and play their
// knobs. Everything answers at once and glides (no clicks); a delay or reverb switched off lets
// its tail ring out. The delay follows the tempo shown (its own deck's; the lead deck's on the
// Wheel and the Master). The knobs are kept across launches; the switches are not.

private func targetLabel(_ t: String) -> String { t.count == 1 ? "Deck \(t)" : t }

struct InsertsPage: View {
  let model: RustDJModel

  var body: some View {
    let ui = model.inserts
    let t = ui.target
    let chain = ui.chains[t]
    VStack(spacing: 16) {
      Card(
        "Insert effects on",
        trailing: {
          Button("ALL OFF") { model.insertsAllOff() }
            .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(DJTheme.accent)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(DJTheme.dim.opacity(0.6)))
            .accessibilityLabel("All insert effects off")
        }
      ) {
        TargetSwitch(selected: t, chains: ui.chains) { model.selectInsertTarget($0) }
        if let chain { TempoLine(chain: chain) }
        if let e = ui.error { Text(e).font(.system(size: 12)).foregroundStyle(DJTheme.danger) }
      }
      if let chain {
        ForEach(chain.effects, id: \.id) { e in EffectCard(model: model, target: t, effect: e) }
      } else {
        Text("starting…").foregroundStyle(DJTheme.dim)
      }
      Spacer(minLength: 24)
    }
    // the page's poll while it shows (the tempos the delays follow)
    .task {
      while !Task.isCancelled {
        model.refreshInserts()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}

/// A, B, Wheel, Master: big segments, a dot on any target with an effect on.
private struct TargetSwitch: View {
  let selected: String
  let chains: [String: InsertChainState]
  let onPick: (String) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(InsertsUI.targets, id: \.self) { t in
        let on = chains[t]?.effects.contains(where: \.on) == true
        let sel = t == selected
        Button {
          onPick(t)
        } label: {
          HStack(spacing: 4) {
            if on { Circle().fill(sel ? Color.black : DJTheme.accent).frame(width: 6, height: 6) }
            Text(targetLabel(t)).font(.system(size: 14, weight: sel ? .semibold : .regular)).lineLimit(1).fixedSize()
              .foregroundStyle(sel ? Color.black : Color.white)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(sel ? DJTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Effects on \(targetLabel(t))" + (on ? ", on" : ""))
        .accessibilityAddTraits(sel ? [.isSelected, .isButton] : .isButton)
      }
    }
    .padding(4)
    .background(DJTheme.surface0, in: RoundedRectangle(cornerRadius: 14))
  }
}

private struct TempoLine: View {
  let chain: InsertChainState
  var body: some View {
    let div = chain.effects.first { $0.id == "delay" }?.knobs.first { $0.id == "delay.time" }?.display ?? ""
    let text: String
    if chain.bpm > 0 {
      let from = chain.target == chain.tempoFrom ? "its tempo" : "Deck \(chain.tempoFrom)"
      text = String(format: "Delay follows \(from) · %.1f BPM · \(div) = %.0f ms", chain.bpm, chain.delayMs)
    } else {
      text = "Delay follows \(chain.target.count == 1 ? "this deck" : "the lead deck") once it plays · \(div)"
    }
    return Caption(text)
  }
}

private struct EffectCard: View {
  let model: RustDJModel
  let target: String
  let effect: InsertEffect

  var body: some View {
    Card(
      effect.label,
      trailing: {
        DJToggle(
          label: "\(effect.label) on \(targetLabel(target))",
          isOn: Binding(get: { effect.on }, set: { model.setInsertOn(target, effect.id, $0) }))
      }
    ) {
      ForEach(effect.knobs, id: \.id) { k in
        KnobRow(model: model, target: target, knob: k, live: effect.on)
      }
    }
  }
}

private struct KnobRow: View {
  let model: RustDJModel
  let target: String
  let knob: InsertKnob
  let live: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(knob.label).font(.system(size: 14)).foregroundStyle(live ? Color.white : DJTheme.dim)
        Spacer()
        Text(knob.display).font(.system(size: 13, design: .monospaced)).foregroundStyle(live ? DJTheme.accent : DJTheme.dim)
      }
      let set: (Double) -> Void = { model.setInsertKnob(target, knob.id, $0) }
      let binding = Binding(get: { min(max(knob.value, 0), 1) }, set: set)
      Group {
        // a discrete knob (the delay's divisions) snaps to its steps
        if knob.steps > 1 {
          Slider(value: binding, in: 0...1, step: 1 / Double(knob.steps - 1))
        } else {
          Slider(value: binding, in: 0...1)
        }
      }
      .tint(live ? DJTheme.accent : DJTheme.dim)
      .accessibilityLabel(knob.label).accessibilityValue(knob.display)
      // 16 to 9 bits barely crunch: the fine slider spans the crushed half
      if knob.id == "crush.bits" {
        FineSlider(description: knob.label, value: knob.value, range: 0.5...1, caption: "9 … 2 bit", enabled: live, onChange: set)
      }
    }
  }
}
