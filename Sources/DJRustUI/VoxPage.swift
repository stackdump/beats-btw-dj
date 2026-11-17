import DJRust
import SwiftUI

// The vocoder (djandroid ui/VocoderPage.kt): by default the three-oscillator synth is the
// carrier and a deck (or the Wheel tab's instrument) the modulator, so its rhythm and sound shape
// the chord ("talking drums", or a talking wheel). The routing row picks either side from the
// desktop Vocoder window's list (inputs, decks, the synth, captures, row clips, library loops:
// djmobile `vocoder_sources`, voc_routing.rs) and ⇄ swaps them.
//
// Made to be played without reading a manual: pick a sound, hold a pad (it switches the vocoder
// on), and "Only the vocoder" pulls the deck out of the mix while it still shapes the synth. Auto
// level keeps it as loud as the decks; the five knobs that matter are up front, the rest under
// More. On an iPad the pads are multi-touch: two hands hold two chords, and they sound together.

struct VoxPage: View {
  let model: RustDJModel

  var body: some View {
    let v = model.vox
    let s = v.state
    let on = s?.on == true
    // the deck or the wheel that shapes, for "only the vocoder" (nil: something else shapes)
    let mod = s?.modulator
    let modName = s?.modulatorSource.id == "none" ? nil : s?.modulatorSource.label
    let carName = s?.carrierSource.id == "none" ? nil : s?.carrierSource.label
    let routed = modName != nil || carName != nil
    VStack(spacing: 16) {
      ChordsCard(model: model, silent: routed && s?.usesSynth == false)
      Card("Vocoder", trailing: {
        DJToggle(label: "Vocoder", isOn: Binding(get: { on }, set: { model.setVocoderOn($0) }))
      }) {
        Caption(
          on && modName != nil && carName != nil ? "\(modName!) shapes \(inSentence(carName!))"
            : on ? "Pick both sides to hear it"
            : !routed || s?.usesSynth == true ? "Hold a chord: it switches on by itself"
            : "Off: the switch above turns it on"
        ).lineLimit(1)
        RoutingRow(model: model, state: s)
        // always laid out (greyed while off): the card keeps its height when the vocoder comes on
        ToggleRow(
          title: "Only the vocoder",
          sub: !on ? "Turn the vocoder on first"
            : mod == nil ? "Needs a deck or the Wheel as the modulator"
            : "\(sourceName(mod!, start: true)) leaves the mix but still shapes the sound",
          isOn: v.onlyVocoder, enabled: on && (mod != nil || v.onlyVocoder)
        ) { model.setOnlyVocoder($0) }
        ToggleRow(
          title: "Auto level",
          sub: s?.autoLevel == true ? "As loud as the decks, whatever the sound" : "Off: the Level knob alone sets it.",
          isOn: s?.autoLevel ?? true
        ) { model.setVocoderAutoLevel($0) }
        Meter(label: "mod (\(modName.map(inSentence) ?? "none"))", level: on ? s?.modulatorLevel ?? 0 : 0)
        Meter(label: "car (\(carName.map(inSentence) ?? "none"))", level: on ? s?.carrierLevel ?? 0 : 0)
        Meter(
          label: "out" + (on && s?.autoLevel == true ? String(format: " %+.1f dB", s?.autoGainDb ?? 0) : ""),
          level: on ? s?.outLevel ?? 0 : 0)
      }
      if !v.presets.isEmpty { SoundsCard(model: model) }
      if let st = s {
        TweakCard(model: model, state: st)
        SynthCard(model: model, knobs: st.knobs)
      }
      Spacer(minLength: 24)
    }
  }
}

/// What shapes the chord, in words: "Deck A", "The wheel" (or "deck A", "wheel" mid-sentence).
private func sourceName(_ mod: String, start: Bool) -> String {
  if mod == wheelModulator { return start ? "The wheel" : "wheel" }
  return start ? "Deck \(mod)" : "deck \(mod)"
}

/// A source's name mid-sentence: "deck A", "the synth", "the wheel"; others as they are.
private func inSentence(_ label: String) -> String {
  if label.hasPrefix("Deck ") { return "deck " + label.dropFirst(5) }
  if label == "Synth" { return "the synth" }
  if label == wheelModulator { return "the wheel" }
  return label
}

/// The pickers' section titles, as the desktop menu separates them.
private let groupTitles = ["capture": "Capture", "clip": "Loop row", "library": "Library"]

/// What a live source plays now: a deck's track or genre, the Wheel's instrument.
@MainActor private func sourceDetail(_ src: VocoderSource?, _ model: RustDJModel) -> String? {
  guard let src else { return nil }
  let id = src.id
  if id.hasPrefix("deck:") {
    guard let d = model.decks[String(id.dropFirst(5))]?.deck else { return nil }
    return d.td3 != nil ? (d.title ?? d.td3) : d.genre
  }
  if id.hasPrefix("input:") && src.label == wheelModulator { return model.wheel.layout?.name }
  if id.hasPrefix("clip:") || id.hasPrefix("library:") || id == "loop" { return "loop" }
  if id.hasPrefix("input:") { return "live input" }
  return nil
}

/// The vocoder's routing, as the desktop's Vocoder window has it: the modulator (what shapes),
/// ⇄ swap, the carrier (what is shaped). Each picker opens the same list (a popover on an iPad);
/// a deck or the synth already on the other side is greyed with the reason.
private struct RoutingRow: View {
  let model: RustDJModel
  let state: VocoderState?

  var body: some View {
    HStack(spacing: 8) {
      SourcePicker(
        model: model, title: "Modulator", side: "modulator", now: state?.modulatorSource,
        other: state?.carrierSource, otherSide: "carrier")
      Button { model.vocoderSwap() } label: {
        VStack(spacing: 0) {
          Text("⇄").font(.system(size: 22)).foregroundStyle(DJTheme.accent)
          Text("Swap").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
        }
        .frame(width: 56, height: 64)
        .background(DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).disabled(state == nil)
      .accessibilityLabel("Swap carrier and modulator")
      SourcePicker(
        model: model, title: "Carrier", side: "carrier", now: state?.carrierSource,
        other: state?.modulatorSource, otherSide: "modulator")
    }
  }
}

/// One side's picker: its name, what it is now (and what that plays), and the list.
private struct SourcePicker: View {
  let model: RustDJModel
  let title: String
  let side: String
  let now: VocoderSource?
  let other: VocoderSource?
  let otherSide: String
  @State private var open = false
  @State private var choices: [VocoderSource] = []

  var body: some View {
    Button { open = true } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(title.uppercased()).font(.system(size: 11)).tracking(1.2).foregroundStyle(DJTheme.dim)
        Text((now?.label ?? "None") + " ▾").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white)
        if let d = sourceDetail(now, model) { Text(d).font(.system(size: 11)).foregroundStyle(DJTheme.dim) }
      }
      .lineLimit(1)
      .padding(.horizontal, 12).padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
      .background(DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title): \(now?.label ?? "none")")
    .popover(isPresented: $open) {
      list.task { choices = await model.vocoderSources() }
        .presentationCompactAdaptation(.popover)
    }
  }

  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
          let first = i == 0 || choices[i - 1].group != c.group
          if first && i > 0 { Divider().overlay(DJTheme.surface2) }
          if first && c.group != "live" {
            Caption(groupTitles[c.group] ?? c.group).padding(.horizontal, 12).padding(.vertical, 4)
          }
          let taken = c.exclusive && c.id == other?.id
          Button {
            open = false
            model.vocoderRoute(side, c.id)
          } label: {
            VStack(alignment: .leading, spacing: 1) {
              Text(c.label).font(.system(size: 15))
                .foregroundStyle(c.id == now?.id ? DJTheme.accent : taken ? DJTheme.dim : Color.white)
              if let sub = taken ? "is the \(otherSide)" : sourceDetail(c, model) { Caption(sub) }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain).disabled(taken)
        }
      }
      .padding(.vertical, 8)
    }
    .frame(minWidth: 280, idealWidth: 320, maxHeight: 520)
    .background(DJTheme.surface1)
  }
}

/// The seven chord pads in the key of the deck that shapes the synth: i–iv on top, v–vii below,
/// big pads for a thumb. Each pad is its own touch, so pads held together sound together.
struct ChordsCard: View {
  let model: RustDJModel
  /// Routed with no synth on either side: the pads play nothing.
  var silent = false

  var body: some View {
    let v = model.vox
    let on = v.state?.on == true
    Card(
      "Chords" + (v.pads.map { " · \($0.key)" } ?? ""),
      trailing: {
        HStack(spacing: 6) {
          Caption("latch")
          DJToggle(label: "Latch chords", isOn: Binding(get: { v.latch }, set: { model.setLatch($0) }))
        }
      }
    ) {
      if let pads = v.pads, pads.pads.count >= 7 {
        Caption(
          silent ? "Silent: route the Synth below to play chords"
          : v.latch
            ? "Tap: keeps sounding · tap again: stops · press several together for a bigger chord"
            : "Hold a chord to play it · hold two for both")
        // four columns: i–iv on top, v–vii below
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
          ForEach(0..<7, id: \.self) { i in
            ChordPadView(pad: pads.pads[i], down: v.sounding.contains(i), vocoderOn: on) {
              model.padDown(i)
            } onUp: {
              model.padUp(i)
            }
          }
        }
      } else {
        Caption("waiting for a track (the pads take its key)")
      }
    }
  }
}

struct ChordPadView: View {
  let pad: ChordPad
  let down: Bool
  let vocoderOn: Bool
  let onDown: () -> Void
  let onUp: () -> Void
  @State private var touching = false

  var body: some View {
    VStack(spacing: 2) {
      Text(pad.name).font(.system(size: 22, weight: .medium)).foregroundStyle(down ? Color.black : Color.white)
        .lineLimit(1).minimumScaleFactor(0.6)
      Text(pad.degree).font(.system(size: 12, design: .monospaced)).foregroundStyle(down ? Color.black : DJTheme.dim)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).aspectRatio(1, contentMode: .fit)
    .background(down ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DJTheme.accent.opacity(vocoderOn ? 0.5 : 0.25), lineWidth: 1))
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if !touching {
            touching = true
            onDown()
          }
        }
        .onEnded { _ in
          touching = false
          onUp()
        }
    )
    .accessibilityElement()
    .accessibilityLabel("\(pad.name) chord, \(pad.degree)" + (down ? ", playing" : ""))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: down ? "stop" : "play") {
      // VoiceOver can't hold: a double-tap toggles it
      if down {
        onUp()
      } else {
        onDown()
      }
    }
  }
}

/// A switch with a title and a one-line explanation; the whole row toggles it.
struct ToggleRow: View {
  let title: String
  let sub: String
  let isOn: Bool
  var enabled = true
  let onChange: (Bool) -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 14)).foregroundStyle(enabled ? Color.white : DJTheme.dim)
        Caption(sub).lineLimit(1)
      }
      Spacer()
      DJToggle(label: title, isOn: Binding(get: { isOn }, set: onChange)).disabled(!enabled)
    }
    .frame(minHeight: 48)
    .contentShape(Rectangle())
    .onTapGesture { if enabled { onChange(!isOn) } }
  }
}

struct Meter: View {
  let label: String
  let level: Float
  var body: some View {
    HStack(spacing: 8) {
      Text(label).font(.system(size: 11)).foregroundStyle(DJTheme.dim).frame(width: 92, alignment: .leading)
      GeometryReader { g in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(DJTheme.surface2)
          RoundedRectangle(cornerRadius: 3).fill(DJTheme.accent)
            .frame(width: g.size.width * CGFloat(min(max(level, 0), 1)))
        }
      }
      .frame(height: 6)
    }
    .accessibilityElement().accessibilityLabel(label).accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
  }
}

/// The sounds: classic patches, then more; a tap loads the synth and the vocoder's knobs.
struct SoundsCard: View {
  let model: RustDJModel

  var body: some View {
    let s = model.vox.state
    let groups = Dictionary(grouping: model.vox.presets, by: \.group)
    let order = model.vox.presets.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    Card("Sound" + (s?.edited == true && s?.preset != nil ? " · tweaked" : "")) {
      ForEach(order, id: \.self) { g in
        Caption(g == "Desktop" ? "Classic patches" : "More sounds")
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
          ForEach(groups[g] ?? [], id: \.id) { p in
            PresetTile(preset: p, selected: p.id == s?.preset) { model.vocoderPreset(p.id) }
          }
        }
      }
    }
  }
}

struct PresetTile: View {
  let preset: VocoderPreset
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        Text(preset.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
          .foregroundStyle(selected ? Color.black : Color.white)
        Text(preset.description).font(.system(size: 11)).lineLimit(3).multilineTextAlignment(.leading)
          .foregroundStyle(selected ? Color.black : DJTheme.dim)
        Spacer(minLength: 0)
      }
      .padding(10).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
      .background(selected ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent.opacity(selected ? 1 : 0.3), lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

// MARK: knobs

/// The synth's knobs: the three oscillators, then its mix, filter envelope and gate.
private let synthKnobs: Set<String> = Set((1...3).flatMap { n in ["wave", "oct", "fine", "level"].map { "osc\(n)_\($0)" } })
  .union(["synth_level", "pwm", "sync", "ring", "env_amount", "env_decay", "synth_attack", "synth_release"])
/// The knobs shown without More.
private let mainKnobs: Set<String> = ["mix", "volume", "cutoff", "shift", "release"]
private let waves = ["saw", "square", "tri", "sine", "noise"]

/// What each knob is called here.
private let knobLabels: [String: String] = [
  "mix": "Effect (vocoded ↔ plain synth)", "volume": "Level", "cutoff": "Brightness",
  "shift": "Voice size (formant)", "release": "Smoothness (release)", "resonance": "Resonance",
  "synth_detune": "Detune", "drift": "Analog drift", "bands": "Bands (detail)", "attack": "Attack",
  "noise": "Breath (noise)", "vowel": "Vowel", "vowel_mix": "Vowel amount", "synth_level": "Synth level",
  "osc1_level": "Level", "osc2_level": "Level", "osc3_level": "Level",
  "osc1_fine": "Fine tune", "osc2_fine": "Fine tune", "osc3_fine": "Fine tune",
  "pwm": "Pulse width (square)", "ring": "Ring mod (osc 2 × osc 1)", "env_amount": "Filter envelope",
  "env_decay": "Envelope decay", "synth_attack": "Gate attack", "synth_release": "Gate release",
]
private let logKnobs: Set<String> = ["cutoff", "release", "attack", "env_decay", "synth_attack", "synth_release"]
private let steppedKnobs: Set<String> = ["bands"]
/// Detune: the chorus lives in the first 15 ct of 50; a mild curve gives it more travel.
private let powKnobs: [String: Double] = ["synth_detune": 1.5]
/// Levels that are linear gains in the engine: square-law, as the deck faders.
private let faderKnobs: Set<String> = ["volume", "synth_level", "osc1_level", "osc2_level", "osc3_level"]

private func taper(_ k: VocoderKnob) -> Taper {
  if logKnobs.contains(k.name) && k.min > 0 { return LogTaper(lo: k.min, hi: k.max) }
  if let e = powKnobs[k.name], k.min == 0 { return PowTaper(max: k.max, k: e) }
  if faderKnobs.contains(k.name) && k.min == 0 && k.max == 1 { return FaderTaper() }
  return LinearTaper(lo: k.min, hi: k.max)
}

private func fmt(_ name: String, _ v: Double) -> String {
  switch name {
  case "cutoff": return v >= 1000 ? String(format: "%.1f kHz", v / 1000) : String(format: "%.0f Hz", v)
  case "release", "attack", "env_decay", "synth_attack", "synth_release":
    return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
  case "synth_detune": return String(format: "%.0f ct", v)
  case "shift": return String(format: "%+.1f st", v)
  case "bands": return String(format: "%.0f", v)
  case "vowel":
    let r = Int(v.rounded())
    return ["a", "e", "i", "o", "u"][min(max(r, 0), 4)] + (abs(v - Double(r)) > 0.05 ? "~" : "")
  case "mix", "volume", "noise", "vowel_mix", "drift", "resonance", "synth_level", "ring", "osc1_level",
    "osc2_level", "osc3_level":
    return String(format: "%.0f%%", v * 100)
  case "osc1_fine", "osc2_fine", "osc3_fine": return String(format: "%+.0f ct", v)
  case "env_amount": return String(format: "%+.0f%%", v * 100)
  default: return String(format: "%.2f", v)
  }
}

/// A knob as a slider on its taper, labelled in its own units. While the thumb moves it shows
/// the finger's value (the engine's comes back on the next poll).
struct KnobSlider: View {
  let knob: VocoderKnob
  let onChange: (Double) -> Void
  @State private var dragging = false
  @State private var local = 0.0

  var body: some View {
    let t = taper(knob)
    let pos = dragging ? local : t.toPos(knob.value)
    let value: (Double) -> Double = { p in
      let v = t.fromPos(p)
      return steppedKnobs.contains(knob.name) ? v.rounded() : v
    }
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(knobLabels[knob.name] ?? knob.name).font(.system(size: 14))
        Spacer()
        Text(fmt(knob.name, value(pos))).font(.system(size: 12, design: .monospaced)).foregroundStyle(DJTheme.dim)
      }
      Slider(
        value: Binding(
          get: { min(max(pos, 0), 1) },
          set: { p in
            dragging = true
            local = p
            onChange(value(p))
          }),
        in: 0...1,
        onEditingChanged: { if !$0 { dragging = false } }
      )
      .accessibilityLabel(knobLabels[knob.name] ?? knob.name)
      .accessibilityValue(fmt(knob.name, knob.value))
    }
  }
}

/// The vocoder's own knobs: five up front, the rest under More, and "Back to <sound>" once moved.
struct TweakCard: View {
  let model: RustDJModel
  let state: VocoderState
  @State private var more = false

  var body: some View {
    let voc = state.knobs.filter { !synthKnobs.contains($0.name) }
    let main = voc.filter { mainKnobs.contains($0.name) }
    let rest = voc.filter { !mainKnobs.contains($0.name) }
    Card("Tweak", trailing: { MoreButton(more: $more) }) {
      ForEach(main, id: \.name) { k in KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } }
      if more { ForEach(rest, id: \.name) { k in KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } } }
      if let id = state.preset, state.edited {
        Button("Back to \(model.vox.presets.first { $0.id == id }?.name ?? "the sound")") { model.vocoderPreset(id) }
          .buttonStyle(.plain).foregroundStyle(DJTheme.accent).frame(minHeight: 44)
      }
    }
  }
}

struct MoreButton: View {
  @Binding var more: Bool
  var body: some View {
    Button(more ? "Fewer" : "More") { more.toggle() }.buttonStyle(.plain).foregroundStyle(DJTheme.accent)
      .frame(minHeight: 44)
  }
}

/// The carrier synth as the desktop's Vocoder window has it: three oscillators (wave, octave,
/// fine, level), pulse width, sync, ring, the filter's envelope and the gate.
struct SynthCard: View {
  let model: RustDJModel
  let knobs: [VocoderKnob]
  @State private var more = false

  var body: some View {
    let by = Dictionary(knobs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    Card("Synth · three oscillators", trailing: { MoreButton(more: $more) }) {
      ForEach(1...3, id: \.self) { n in
        if let wave = by["osc\(n)_wave"], let oct = by["osc\(n)_oct"] {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
              Text("Osc \(n)").font(.system(size: 14, weight: .medium))
              Spacer()
              Caption("octave")
              Button("−") { model.vocoderSet(oct.name, max(oct.value - 1, oct.min)) }
                .buttonStyle(.plain).foregroundStyle(DJTheme.accent).frame(width: 44, height: 44)
                .accessibilityLabel("Osc \(n) octave down")
              Text(String(format: "%+d", Int(oct.value.rounded()))).font(.system(size: 14, design: .monospaced))
              Button("+") { model.vocoderSet(oct.name, min(oct.value + 1, oct.max)) }
                .buttonStyle(.plain).foregroundStyle(DJTheme.accent).frame(width: 44, height: 44)
                .accessibilityLabel("Osc \(n) octave up")
            }
            HStack(spacing: 4) {
              ForEach(Array(waves.enumerated()), id: \.offset) { i, w in
                let lit = Int(wave.value.rounded()) == i
                Button {
                  model.vocoderSet(wave.name, Double(i))
                } label: {
                  Text(w).font(.system(size: 12)).lineLimit(1).foregroundStyle(lit ? Color.black : Color.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(lit ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Osc \(n) \(w)").accessibilityAddTraits(lit ? .isSelected : [])
              }
            }
            if let k = by["osc\(n)_level"] { KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } }
            if more, let k = by["osc\(n)_fine"] { KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } }
          }
        }
      }
      if let k = by["sync"] {
        ToggleRow(title: "Sync", sub: "Osc 2 hard-synced to osc 1.", isOn: k.value > 0.5) {
          model.vocoderSet(k.name, $0 ? 1 : 0)
        }
      }
      ForEach(["synth_level", "ring", "env_amount", "env_decay"], id: \.self) { name in
        if let k = by[name] { KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } }
      }
      if more {
        ForEach(["pwm", "synth_attack", "synth_release"], id: \.self) { name in
          if let k = by[name] { KnobSlider(knob: k) { model.vocoderSet(k.name, $0) } }
        }
      }
    }
  }
}
