import DJRust
import SwiftUI

// The effects (djandroid ui/FxPage.kt), aimed at Deck A, Deck B, the Wheel or the Master by one
// switch that the pads and the inserts share. First the throws: every trick and macro in the one
// category the engine puts it in (a Transition card of one-shots, then Filter & tone, Space,
// Rhythm, Arrange, Pitch, Stereo & shape, Feel, and the Sweeps). Nothing fires at once: a pad
// lands on the target's next bar (the Wheel's and the Master's: the lead deck's) and runs for the
// length picked (1–4 bars, or latched until pressed again). A transition is held; a sweep has
// bars and no latch. The filter knob is a hand, not a trigger, and answers at once. On the Wheel
// and the Master the pads that work a deck's track are dimmed. On an Acid Bass loop the deck's
// own Acid Bass tricks show too. Then the held effects after the Vox tap (the Inserts tab before
// it folded in here): filter, bitcrush, delay and reverb, each switched on in its card's header;
// they answer at once and glide, and a delay or reverb switched off lets its tail ring out. The
// delay follows the tempo shown (its own deck's; the lead deck's on the Wheel and the Master).
// Their knobs are kept across launches; the switches are not. PANIC ends this target's throws
// and switches its inserts off.

private func targetLabel(_ t: String) -> String { t.count == 1 ? "Deck \(t)" : t }

/// An Acid Bass loop (groups 1–8, "1A" … "8B"), the ones the Acid Bass tricks reshape; 9 is
/// Floor & Sub.
func isAcidLoop(_ id: String?) -> Bool {
  guard let id, id.count >= 2, let g = Int(id.dropLast()) else { return false }
  return (1...8).contains(g)
}

struct FxPage: View {
  let model: RustDJModel
  @State private var length: FxMode = .bars(bars: 1)
  @State private var sweepBars: UInt8 = 2

  var body: some View {
    // the target the pads and the inserts act on; until one is picked, the lead deck
    let d = model.fxTarget ?? leadDeck(model.mix?.crossfader)
    let onDeck = d.count == 1
    let chain = model.inserts.chains[d]
    let active = Dictionary((model.fxActive[d] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    VStack(spacing: 16) {
      Card(
        "Effects on",
        trailing: {
          Button("PANIC") { model.fxPanic(d) }
            .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(DJTheme.danger)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(DJTheme.danger.opacity(0.6)))
            .accessibilityLabel("Panic: end \(targetLabel(d))'s effects now and switch its inserts off")
        }
      ) {
        TargetSwitch(selected: d, model: model) { model.selectFxTarget($0) }
        // the dimmed pads' reason, once for the page
        if !onDeck { Caption("Dimmed: they work a deck's track") }
      }
      Card("Length", trailing: { Caption(onDeck ? "lands on the next bar" : "lands on the lead deck's bar") }) {
        LengthChips(selected: length, latch: true) { length = $0 }
      }
      ForEach(model.fxCategories, id: \.id) { cat in
        let pads = model.fxCatalogue.filter { $0.category == cat.id }
        if !pads.isEmpty {
          Card(
            cat.label,
            trailing: {
              if cat.transition {
                Caption("hold · one-shot")
              } else if !cat.latchable {
                LengthChips(selected: .bars(bars: sweepBars), latch: false) {
                  if case let .bars(n) = $0 { sweepBars = n }
                }
              }
            }
          ) {
            FlowLayout(spacing: 8) {
              ForEach(pads, id: \.id) { p in
                if !onDeck && p.decksOnly {
                  DimPad(label: p.label)
                } else if cat.transition {
                  HoldPad(
                    label: p.label, active: active[p.id],
                    onPress: { model.engage(d, p.id, .momentary) }, onRelease: { model.fxRelease(d, p.id) })
                } else {
                  let mode = cat.latchable ? length : .bars(bars: sweepBars)
                  FxPad(label: p.label, active: active[p.id]) {
                    if active[p.id] != nil { model.fxUnlatch(d, p.id) } else { model.engage(d, p.id, mode) }
                  }
                }
              }
            }
            if cat.id == "filter-tone" { FilterKnob(model: model, deck: d) }
          }
        }
      }
      // the engine's own Acid Bass tricks (djmobile `fx::ACID_TRICKS`): held pads, on this deck's loop
      let acid = model.fxCatalogue.filter { $0.family == "acid" }
      if onDeck && !acid.isEmpty && isAcidLoop(model.decks[d]?.deck?.td3) {
        Card("Acid Bass", trailing: { Caption("on this deck's loop") }) {
          FlowLayout(spacing: 8) {
            ForEach(acid, id: \.id) { p in
              HoldPad(
                label: p.label, active: active[p.id],
                onPress: { model.fxAcid(d, p.id, true) }, onRelease: { model.fxAcid(d, p.id, false) })
            }
          }
          Caption("Accents, slides on the bar; cutoff opens over 2 bars")
        }
      }
      // the held effects, after the Vox tap (djandroid InsertFx.kt)
      Caption("After the Vox tap: held effects")
      if let chain {
        TempoLine(chain: chain)
        if let e = model.inserts.error { Text(e).font(.system(size: 12)).foregroundStyle(DJTheme.danger) }
        ForEach(chain.effects, id: \.id) { e in InsertCard(model: model, target: d, effect: e) }
      } else {
        Caption("starting…")
      }
      Spacer(minLength: 24)
    }
    // the page's poll while it shows (the tempos the delays follow, inserts changed elsewhere)
    .task {
      while !Task.isCancelled {
        model.refreshInserts()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}

/// A, B, Wheel, Master: big segments, a dot on any target with a throw or an insert on.
private struct TargetSwitch: View {
  let selected: String
  let model: RustDJModel
  let onPick: (String) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(InsertsUI.targets, id: \.self) { t in
        let on =
          model.fxActive[t]?.isEmpty == false || model.inserts.chains[t]?.effects.contains(where: \.on) == true
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

/// A pad the target can't take (it works a deck's track): dimmed, no tap, the reason read out.
struct DimPad: View {
  let label: String
  var body: some View {
    Text(label).font(.system(size: 14)).foregroundStyle(DJTheme.dim)
      .padding(12).frame(minWidth: 96, minHeight: 56)
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(DJTheme.surface2, lineWidth: 1))
      .accessibilityElement()
      .accessibilityLabel("\(label), unavailable here: it works a deck's track")
  }
}

/// The delay's tempo: whose it follows, the BPM and the division in ms.
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

/// An insert: its switch in the header; its first knob (filter sweep, bits, delay time, reverb
/// size) and its Mix always shown, the rest under More.
private struct InsertCard: View {
  let model: RustDJModel
  let target: String
  let effect: InsertEffect
  @State private var more = false

  var body: some View {
    let first = effect.knobs.first { insertLeadKnobs.contains($0.id) }?.id ?? effect.knobs.first?.id
    let shown: (InsertKnob) -> Bool = { $0.id == first || $0.id.hasSuffix(".mix") }
    let main = effect.knobs.filter(shown)
    let rest = effect.knobs.filter { !shown($0) }
    Card(
      effect.label,
      trailing: {
        HStack(spacing: 12) {
          if !rest.isEmpty { MoreButton(more: $more) }
          DJToggle(
            label: "\(effect.label) on \(targetLabel(target))",
            isOn: Binding(get: { effect.on }, set: { model.setInsertOn(target, effect.id, $0) }))
        }
      }
    ) {
      ForEach(main, id: \.id) { k in KnobRow(model: model, target: target, knob: k, live: effect.on) }
      if more { ForEach(rest, id: \.id) { k in KnobRow(model: model, target: target, knob: k, live: effect.on) } }
    }
  }
}

/// Each insert's first knob, shown with its Mix without More (any other effect: its first knob).
private let insertLeadKnobs: Set<String> = ["filter.sweep", "crush.bits", "delay.time", "reverb.size"]

/// A Dim caption (12 pt).
struct Caption: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(DJTheme.dim) }
}

/// 1 2 3 4 bars, and (where the category allows it) Latch.
struct LengthChips: View {
  let selected: FxMode
  let latch: Bool
  let onSelect: (FxMode) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(1...4, id: \.self) { n in
        Chip(label: "\(n)", selected: selected == .bars(bars: UInt8(n))) { onSelect(.bars(bars: UInt8(n))) }
          .accessibilityLabel("\(n) bar\(n == 1 ? "" : "s")")
      }
      if latch { Chip(label: "Latch", selected: selected == .latch) { onSelect(.latch) } }
    }
  }
}

private func padState(_ a: FxActive?) -> String {
  guard let a else { return "" }
  return a.pending ? ", waiting for the bar" : a.latched ? ", latched" : ", on"
}

/// A pad: a tap engages it for the length picked, on the next bar; a tap while it is on (or
/// waiting, or latched) lets it go on the next bar. Lit once its bar has come, outlined while it
/// waits, ringed white while latched.
struct FxPad: View {
  let label: String
  let active: FxActive?
  let onTap: () -> Void

  var body: some View {
    let on = active.map { !$0.pending } ?? false
    Button(action: onTap) {
      Text(label).font(.system(size: 14)).foregroundStyle(on ? Color.black : Color.white)
        .padding(12).frame(minWidth: 96, minHeight: 56)
        .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          if active?.pending == true {
            RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent, lineWidth: 2)
          } else if active?.latched == true {
            RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 2)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label + padState(active))
    .accessibilityHint(active != nil ? "let go on the bar" : "engage on the bar")
  }
}

/// A transition: on at the press (landing on the next bar), off at the release. Tape stop and
/// the freeze hold until the finger lifts; a riser runs its bars; a cut ends by itself. Each pad
/// is its own gesture, so two hands hold two pads.
struct HoldPad: View {
  let label: String
  let active: FxActive?
  let onPress: () -> Void
  let onRelease: () -> Void
  @State private var down = false

  var body: some View {
    let on = down || (active.map { !$0.pending } ?? false)
    Text(label).font(.system(size: 14)).foregroundStyle(on ? Color.black : Color.white)
      .padding(12).frame(minWidth: 96, minHeight: 56)
      .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        if active?.pending == true { RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent, lineWidth: 2) }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !down {
              down = true
              onPress()
            }
          }
          .onEnded { _ in
            down = false
            onRelease()
          }
      )
      .accessibilityElement()
      .accessibilityLabel(label + ", hold" + padState(active))
      .accessibilityAddTraits(.isButton)
      // VoiceOver can't hold: a double-tap fires it for a second
      .accessibilityAction(named: "fire") {
        onPress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onRelease() }
      }
  }
}

/// The one-knob filter under a hand: left low-pass, right high-pass, and back to open on release.
struct FilterKnob: View {
  let model: RustDJModel
  let deck: String
  @State private var v = 0.5

  var body: some View {
    HStack(spacing: 8) {
      Text("Filter").font(.system(size: 14)).frame(minWidth: 56, alignment: .leading)
      Text("low").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
      Slider(
        value: Binding(
          get: { v },
          set: {
            v = $0
            model.trickKnob(deck, $0)
          }),
        in: 0...1,
        onEditingChanged: { editing in
          if !editing {
            v = 0.5
            model.trickKnob(deck, 0.5)
          }
        }
      )
      .accessibilityLabel("Filter, low-pass to high-pass, springs back open")
      Text("high").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
    }
  }
}

/// An insert knob: its label and the engine's reading, a slider (stepped for the delay's
/// divisions) and, for the bitcrush's bits, the fine slider.
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
