import DJCore
import SwiftUI

// "Loops master FX": the decks' master FX panel (MasterFxPanel) aimed at the loop channel "L", as
// a strip that folds open under the Loops row's header. It lives there because the Loops row is
// the loop channel's strip (its volume, mute, reverb and fade are in that header); the Soundboard
// is a launch surface. Kept apart in wording from "Loop FX", each clip's own after effects
// (ClipFxEditor). Every button is the deck's poke with deck "L" (`DeckAction.macro`, `.panic`).

/// The header's fold button: "Master FX", with a dot while a macro runs on the loops.
struct LoopMasterFxToggle: View {
  let model: AppModel

  var body: some View {
    Toggle(
      model.loopChannel.masterRunning.isEmpty ? "Master FX" : "Master FX ●",
      isOn: Binding(get: { model.showLoopMasterFx }, set: { model.showLoopMasterFx = $0 })
    )
    .toggleStyle(.button).controlSize(.small)
    .help(
      "Loops master FX: sweeps, riser, crush, pitch, vinyl brake… on all the loops together, "
        + "after they are mixed (each loop's own Loop FX are in its settings)")
  }
}

/// The strip: the master macros by group, panic, and the link to the decks' master FX.
struct LoopMasterFxStrip: View {
  let model: AppModel

  var body: some View {
    let tint = LoopRowView.tint
    let state = model.loopChannel
    VStack(alignment: .leading, spacing: DJStyle.s) {
      HStack(spacing: DJStyle.m) {
        Text("LOOPS MASTER FX").font(DJStyle.sectionLabel).tracking(1.2)
          .foregroundStyle(.secondary)
        Toggle(
          "Link to decks",
          isOn: Binding(get: { state.fxLink }, set: { model.setLoopFxLink($0) })
        )
        .toggleStyle(.button).controlSize(.small).tint(tint)
        .help("A master macro fired on deck A or B fires on the loops too, at once")
        Button("Panic") { model.panic("L") }
          .controlSize(.small).disabled(state.masterRunning.isEmpty)
          .help("Stop every master macro on the loops and put the sliders back")
        Spacer(minLength: 0)
        Text("all loops after the mix · lands on the next \(Self.boundary(model.loopQuantum))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      MasterFxPanel(name: "L", running: state.masterRunning, model: model, tint: tint)
    }
    .padding(DJStyle.s)
    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
  }

  /// What a fire on the loops waits for: the launch quantum, at most a bar.
  static func boundary(_ quantum: Int) -> String { quantum >= 4 ? "bar" : "beat" }
}
