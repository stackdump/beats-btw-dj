import DJCore
import SwiftUI

// The sound panel: long press (or right-click ▸ Edit sound…) on an instrument in the
// Instruments panel opens its channel's voice — level, attack, decay, brightness, drive,
// vibrato, a pitch sweep — applied live to the song playing (no reload), for this session;
// "Save as variation…" keeps a setting under a name, offered as a chip beside the instrument.

/// An instrument choice: a click plays it (as `ChoiceButton`); a press held ~0.5 s, or the
/// context menu, opens its sound instead (`edit`), and that press does not also pick it.
struct InstrumentButton: View {
  let label: String
  let selected: Bool
  let tint: Color
  let pick: () -> Void
  let edit: () -> Void
  /// When the long press fired: the click that ends it is swallowed (if it comes soon).
  @State private var heldAt: Date?

  static let holdSeconds = 0.5

  var body: some View {
    Toggle(
      label,
      isOn: Binding(
        get: { selected },
        set: { _ in
          if let t = heldAt, Date().timeIntervalSince(t) < 5 {
            heldAt = nil
            return
          }
          heldAt = nil
          pick()
        })
    )
    .toggleStyle(.button).controlSize(.small).tint(tint)
    .simultaneousGesture(
      LongPressGesture(minimumDuration: Self.holdSeconds).onEnded { _ in
        heldAt = Date()
        edit()
      }
    )
    .contextMenu { Button("Edit sound…", action: edit) }
    .help("Click: play this instrument · hold or right-click: edit the sound")
  }
}

/// What the sound panel shows of each parameter: its slider's position (0…1) for a value and
/// back, and the value with its unit.
enum VoiceParam: String, CaseIterable {
  case gainDB, attack, decayScale, maxDecay, lowpass, distortion, vibratoRate, vibratoDepth
  case pitchFrom, pitchTo, pitchTime

  var isPitch: Bool { [.pitchFrom, .pitchTo, .pitchTime].contains(self) }

  /// The instrument's own value.
  func base(_ v: DJCore.VoiceSpec) -> Double {
    switch self {
    case .gainDB: return 0
    case .attack: return v.attack
    case .decayScale: return v.decayScale
    case .maxDecay: return v.maxDecay
    case .lowpass: return v.lowpass
    case .distortion: return v.distortion
    case .vibratoRate: return v.vibratoRate
    case .vibratoDepth: return v.vibratoDepth
    case .pitchFrom: return v.pitchFrom
    case .pitchTo: return v.pitchTo
    case .pitchTime: return v.pitchTime
    }
  }

  /// (low, high, logarithmic) of the slider.
  private var span: (Double, Double, Bool) {
    switch self {
    case .gainDB: return (-24, 12, false)
    case .attack: return (0.001, 2, true)
    case .decayScale: return (0.1, 10, true)
    case .maxDecay: return (0.05, 8, true)
    case .lowpass: return (200, 20_000, true)
    case .distortion: return (0, 1, false)
    case .vibratoRate: return (0, 12, false)
    case .vibratoDepth: return (0, 0.05, false)
    case .pitchFrom: return (0.25, 16, true)
    case .pitchTo: return (0.25, 4, true)
    case .pitchTime: return (0, 2, false)
    }
  }

  func position(_ value: Double) -> Double {
    if self == .lowpass && value <= 0 { return 0 }  // off
    let (lo, hi, log) = span
    let x =
      log ? Foundation.log(max(lo, value) / lo) / Foundation.log(hi / lo) : (value - lo) / (hi - lo)
    return min(1, max(self == .lowpass ? 0.01 : 0, x))
  }

  func value(_ position: Double) -> Double {
    if self == .lowpass && position < 0.01 { return 0 }
    let (lo, hi, log) = span
    return log ? lo * pow(hi / lo, position) : lo + (hi - lo) * position
  }

  func label(_ x: Double) -> String {
    func seconds(_ s: Double) -> String {
      s < 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.2f s", s)
    }
    switch self {
    case .gainDB: return String(format: "Level %+.1f dB", x)
    case .attack: return "Attack " + seconds(x)
    case .decayScale: return String(format: "Decay ×%.2f note", x)
    case .maxDecay: return "Decay max " + seconds(x)
    case .lowpass:
      return x <= 0
        ? "Brightness off"
        : x < 1000
          ? String(format: "Brightness %.0f Hz", x)
          : String(format: "Brightness %.1f kHz", x / 1000)
    case .distortion: return x <= 0 ? "Drive off" : String(format: "Drive %.0f%%", x * 100)
    case .vibratoRate: return x <= 0 ? "Vibrato off" : String(format: "Vibrato %.1f Hz", x)
    case .vibratoDepth: return String(format: "Depth %.0f ¢", 1200 * log2(1 + x))
    case .pitchFrom: return String(format: "From ×%.2f", x)
    case .pitchTo: return String(format: "To ×%.2f", x)
    case .pitchTime: return x <= 0 ? "Sweep off" : "Sweep " + seconds(x)
    }
  }
}

/// "Sound — melody: laser": one channel's voice on a deck.
struct VoiceEditor: View {
  let deck: String
  let role: String
  let channel: Int
  let model: AppModel
  let tint: Color
  @State private var naming = false
  @State private var draft = ""
  @State private var renaming: String?
  @State private var advanced = false

  private var state: DeckState { model.decks[deck] ?? .init() }

  var body: some View {
    let s = state
    VStack(alignment: .leading, spacing: 6) {
      if let cv = s.channelVoices[channel] {
        content(cv, s.voiceSettings[channel])
      } else {
        Text("Sound — \(role)").font(.headline)
        Text("Nothing plays on this channel now.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(12).frame(width: 320)
  }

  @ViewBuilder private func content(_ cv: ChannelVoice, _ setting: VoiceSetting?) -> some View {
    let mine = setting?.instrument == cv.instrument ? setting : nil
    let tweak = mine?.tweak ?? VoiceTweak()
    let synth = mine?.useSynth ?? false
    Text("Sound — \(role): \(cv.instrument)").font(.headline)
    if cv.sampled {
      Text(
        synth
          ? "Playing its synth voice instead of the sampled sound."
          : "This plays a sampled sound (EXS / SoundFont): these controls shape its synth voice."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button(synth ? "Use sample" : "Use synth voice") {
        model.setSynthVoice(deck, channel: channel, !synth)
      }
      .controlSize(.small)
    }
    Group {
      row(.gainDB, cv, tweak)
      if cv.tonal {
        row(.attack, cv, tweak)
        row(.decayScale, cv, tweak)
        row(.maxDecay, cv, tweak)
        row(.lowpass, cv, tweak)
        row(.distortion, cv, tweak)
        row(.vibratoRate, cv, tweak)
        row(.vibratoDepth, cv, tweak)
        if cv.pluck {
          Text("A plucked string has no pitch sweep.").font(.caption2).foregroundStyle(.tertiary)
        } else {
          DisclosureGroup("Pitch sweep", isExpanded: $advanced) {
            row(.pitchFrom, cv, tweak)
            row(.pitchTo, cv, tweak)
            row(.pitchTime, cv, tweak)
          }
          .font(.caption)
        }
      } else {
        Text("A drum kit: only its level is set here.").font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .opacity(cv.sampled && !synth ? 0.55 : 1)
    HStack {
      Button("Reset") {
        model.setVoiceTweak(deck, channel: channel, VoiceTweak())
        if synth { model.setSynthVoice(deck, channel: channel, false) }
      }
      .disabled(tweak.isEmpty && !synth)
      .help("Back to \(cv.instrument)'s own voice")
      Spacer()
      Button("Save as variation…") { naming = true }
        .disabled(tweak.isEmpty && !synth)
    }
    .controlSize(.small)
    if naming {
      TextField("Name (Return to save)", text: $draft)
        .textFieldStyle(.roundedBorder).controlSize(.small)
        .onSubmit {
          model.saveVariation(
            cv.instrument, name: draft,
            VoiceSetting(tweak: tweak, useSynth: synth, instrument: cv.instrument))
          draft = ""
          naming = false
        }
    }
    variations(cv, mine)
    Text("Live on the song playing, for this session. Saved variations are kept.")
      .font(.caption2).foregroundStyle(.tertiary)
  }

  @ViewBuilder private func variations(_ cv: ChannelVoice, _ setting: VoiceSetting?) -> some View {
    let saved = model.variations[cv.instrument] ?? []
    if !saved.isEmpty {
      Text("Variations").font(.caption2).foregroundStyle(.secondary)
      let current = model.currentVariation(cv.instrument, setting)?.name
      ForEach(saved, id: \.name) { v in
        HStack(spacing: 4) {
          if renaming == v.name {
            TextField("New name", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small)
              .onSubmit {
                model.renameVariation(cv.instrument, v.name, to: draft)
                renaming = nil
                draft = ""
              }
          } else {
            ChoiceButton(label: v.name, selected: current == v.name, tint: tint) {
              Task {
                await model.applyVariation(
                  deck, channel: channel, instrument: cv.instrument, v)
              }
            }
          }
          Spacer()
          Button("Rename") {
            renaming = v.name
            draft = v.name
          }
          Button("Delete") { model.deleteVariation(cv.instrument, v.name) }
        }
        .controlSize(.small)
      }
    }
  }

  private func row(_ p: VoiceParam, _ cv: ChannelVoice, _ tweak: VoiceTweak) -> some View {
    let value = tweak[p.rawValue] ?? p.base(cv.voice)
    return HStack {
      Text(p.label(value)).font(.caption).monospacedDigit().foregroundStyle(
        tweak[p.rawValue] == nil ? .secondary : .primary
      )
      .frame(width: 128, alignment: .leading)
      Slider(
        value: Binding(
          get: { p.position(value) },
          set: { x in
            var t = tweak
            if p.isPitch {
              // the sweep is one shape: set all three, from what the panel shows
              for q in [VoiceParam.pitchFrom, .pitchTo, .pitchTime] where t[q.rawValue] == nil {
                t[q.rawValue] = q.base(cv.voice)
              }
            }
            t[p.rawValue] = p.value(x)
            model.setVoiceTweak(deck, channel: channel, t)
          }),
        in: 0...1)
    }
  }
}
