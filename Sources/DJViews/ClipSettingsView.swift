import AppKit
import DJCore
import SwiftUI

/// Where a clip came from, as its tile's info popover shows it: the provenance lines, "Load
/// source on A / B", "Export WAV…" and "Copy as JSON". Shared by the Loops row's tile and the
/// Soundboard's clip settings.
struct ClipProvenanceDetails: View {
  let clip: ClipState
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if clip.provenance.isEmpty {
        Text("No record of where it came from").foregroundStyle(.secondary)
      }
      ForEach(Array(clip.provenance.enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption).monospacedDigit()
      }
      HStack(spacing: DJStyle.s) {
        Button("Load source on A") { Task { await model.loadOrigin(clip.id, on: "A") } }
        Button("on B") { Task { await model.loadOrigin(clip.id, on: "B") } }
      }
      .controlSize(.small).padding(.top, 4).disabled(!clip.canLoadOrigin)
      .help(
        clip.canLoadOrigin
          ? "Load the track it was taken from, at the section it was in"
          : "Its source can't be loaded again (a sample not in memory)")
      HStack(spacing: DJStyle.s) {
        Button("Export WAV…") { model.exportClip(clip.id) }
        if let json = clip.provenanceJSON {
          Button("Copy as JSON") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
          }
        }
      }
      .controlSize(.small)
    }
  }
}

/// A pad's "Settings…": everything about its clip, bound to the same `ClipState` the Loops row
/// shows and changed through the same model calls (so the row and the board never disagree):
/// name and colour, a sequence's steps, a crop to the beat, level, mute / solo / key lock, its
/// FX, its own launch, fade and tempo rules beside the loop channel's (all loops), which deck
/// holds it, where it came from,
/// and — for a loop taken from a net — the instruments of that track, opened in the sound panel
/// for tuning.
struct ClipSettingsView: View {
  /// The clip shown; a crop or a sequence edit replaces the clip (a new id), and this follows it.
  @Binding var id: String
  let model: AppModel
  /// The crop being set, in beats (nil: the whole clip).
  @State private var crop: (from: Int, to: Int)?
  /// The instrument whose sound panel is open: (deck, channel).
  @State private var tuning: Tuning?

  struct Tuning: Equatable {
    var deck: String
    var channel: Int
  }

  /// The clip the editor shows: the Loops row's own `ClipState` for it.
  static func clip(_ id: String, in model: AppModel) -> ClipState? {
    model.clips.first { $0.id == id }
  }

  /// Crop clip `id` to beats `from..<to` (as dragging a tile's edges does); the cropped clip
  /// takes its place on the row under a new id, which `follow` is given.
  static func crop(
    _ id: String, from: Int, to: Int, in model: AppModel, follow: (String) -> Void
  ) {
    let index = model.clips.firstIndex { $0.id == id }
    model.cropClip(id, from: from, to: to)
    if let index, model.clips.indices.contains(index), model.clips[index].id != id {
      follow(model.clips[index].id)
    }
  }

  var body: some View {
    Group {
      if let clip = Self.clip(id, in: model) {
        ScrollView(.vertical) { content(clip).padding(14) }
      } else {
        Text("This loop is no longer on the row").foregroundStyle(.secondary).padding(14)
      }
    }
    .frame(width: 400).frame(maxHeight: 640)
  }

  @ViewBuilder private func content(_ clip: ClipState) -> some View {
    VStack(alignment: .leading, spacing: DJStyle.m) {
      VStack(alignment: .leading, spacing: 4) {
        ClipNameEditor(clip: clip, model: model).id(clip.id)
        ClipColorSwatches(current: clip.color) { model.setClipColor(clip.id, $0) }
        Text(
          "\(clip.lengthLabel) · \(String(format: "%.1f", clip.bpm)) bpm · "
            + (clip.steps != nil
              ? "a sequence of \(clip.steps?.count ?? 0)" : "from \(clip.source)")
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      if let steps = clip.steps {
        section("Steps") { stepsEditor(clip, steps) }
      }
      section("Edges") { cropEditor(clip) }
      section("Sound") { soundEditor(clip) }
      section("FX") { ClipFxEditor(clip: clip, model: model) }
      section("This loop") { clipRules(clip) }
      section("All loops") { channelRules }
      section("Where it plays") { placement(clip) }
      section("Where it came from") { ClipProvenanceDetails(clip: clip, model: model) }
      section("Tune its instruments") { tuningEditor(clip) }
    }
  }

  private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SectionLabel(title)
      body()
    }
  }

  // MARK: steps

  /// A sequence's steps, as its tile's chips, plus "Add a loop". An edit remakes the sequence
  /// under a new id (`SequenceStepsEditor.edit`), which this follows, as a crop does.
  private func stepsEditor(_ clip: ClipState, _ steps: [StepState]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      SequenceStepsEditor(id: clip.id, steps: steps, model: model, addMenu: true) { id = $0 }
      Text("Tap a step for ×1 → ×2 → ×4; right-click to move or remove it.")
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  // MARK: edges

  /// The waveform with the part a crop keeps lit, and the beats to keep. "Crop" makes the
  /// cropped clip (`AppModel.cropClip`, as dragging a tile's edges does).
  private func cropEditor(_ clip: ClipState) -> some View {
    let beats = max(1, clip.beats)
    let span = crop ?? (0, beats)
    return VStack(alignment: .leading, spacing: 6) {
      WaveformStrip(
        overview: clip.overview, overlay: clip.playhead.map { WaveformOverlay(playhead: $0) },
        tint: clipTint(clip.color)
      )
      .frame(height: 44)
      .overlay {
        GeometryReader { geo in
          let w = geo.size.width
          let x = { (b: Int) in w * CGFloat(b) / CGFloat(beats) }
          ZStack(alignment: .topLeading) {
            if beats <= 64 {
              ForEach(1..<beats, id: \.self) { b in
                Rectangle().fill(Color.white.opacity(b % 4 == 0 ? 0.35 : 0.12))
                  .frame(width: 1, height: geo.size.height).offset(x: x(b))
              }
            }
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: x(span.from))
            Rectangle().fill(Color.black.opacity(0.6))
              .frame(width: w - x(span.to)).offset(x: x(span.to))
          }
        }
        .allowsHitTesting(false)
      }
      HStack(spacing: DJStyle.s) {
        Stepper(
          "From beat \(span.from + 1)",
          value: Binding(
            get: { span.from }, set: { crop = (min(max(0, $0), span.to - 1), span.to) }),
          in: 0...(beats - 1))
        Stepper(
          "to \(span.to)",
          value: Binding(
            get: { span.to }, set: { crop = (span.from, max(min(beats, $0), span.from + 1)) }),
          in: 1...beats)
        Spacer(minLength: 0)
        Button("Crop") {
          Self.crop(clip.id, from: span.from, to: span.to, in: model) { id = $0 }
          crop = nil
        }
        .disabled(span.from == 0 && span.to == beats)
      }
      .controlSize(.small).font(.caption).monospacedDigit()
      Text(
        "Keeps \(span.to - span.from) of \(clip.beats) beats; a loop playing carries on in phase."
      )
      .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  // MARK: sound

  private func soundEditor(_ clip: ClipState) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledSlider(
        label: String(format: "Level %.0f%%", clip.gain * 100),
        value: Binding(get: { clip.gain }, set: { model.setClipGain(clip.id, $0) }), range: 0...1)
      HStack(spacing: DJStyle.xs) {
        Toggle("Mute", isOn: Binding(get: { clip.muted }, set: { model.setClipMute(clip.id, $0) }))
          .tint(.orange).help("It plays on silently, and comes back in time")
        Toggle("Solo", isOn: Binding(get: { clip.soloed }, set: { model.setClipSolo(clip.id, $0) }))
          .tint(.yellow).help("Only soloed loops are heard under the mixer")
        Toggle(
          "🔒 Key lock",
          isOn: Binding(get: { clip.keyLock }, set: { model.setClipKeyLock(clip.id, $0) })
        )
        .tint(LoopRowView.tint)
        .help("At another tempo it keeps its pitch (time-stretched, not sped up)")
        Spacer(minLength: 0)
        if clip.stretching {
          Text("stretching…").font(.caption2).foregroundStyle(.secondary)
        } else if clip.stretched {
          Text("stretched").font(.caption2).foregroundStyle(LoopRowView.tint)
        }
      }
      .toggleStyle(.button).controlSize(.small)
    }
  }

  /// This clip's own launch, fade and tempo rules: "row" follows the loop channel's (named in
  /// brackets), a value is this clip's alone (`DJEngine.clipQuantum` / `clipFade` /
  /// `clipFollow`).
  private func clipRules(_ clip: ClipState) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 3) {
        rulesLabel("Launch on")
        ChoiceButton(
          label: "row (\(DJEngine.quantumLabel(model.loopQuantum)))", selected: clip.quantum == nil,
          tint: LoopRowView.tint
        ) { model.setClipQuantum(clip.id, nil) }
        ForEach(DJEngine.launchQuanta, id: \.self) { q in
          ChoiceButton(
            label: DJEngine.quantumLabel(q), selected: clip.quantum == q, tint: LoopRowView.tint
          ) { model.setClipQuantum(clip.id, q) }
        }
      }
      HStack(spacing: 3) {
        rulesLabel("Fade")
        ChoiceButton(
          label: "row (\(model.loopChannel.fade.label))", selected: clip.fade == nil,
          tint: LoopRowView.tint
        ) { model.setClipFade(clip.id, nil) }
        ForEach(LoopFade.allCases, id: \.self) { f in
          ChoiceButton(label: f.label, selected: clip.fade == f, tint: LoopRowView.tint) {
            model.setClipFade(clip.id, f)
          }
        }
      }
      HStack(spacing: 3) {
        rulesLabel("Tempo")
        ChoiceButton(
          label: "row (\(ClipState.followLabel(model.loopFollow)))", selected: clip.follow == nil,
          tint: LoopRowView.tint
        ) { model.setClipFollow(clip.id, nil) }
        ForEach(LoopFollow.allCases, id: \.self) { f in
          ChoiceButton(
            label: ClipState.followLabel(f), selected: clip.follow == f, tint: LoopRowView.tint
          ) { model.setClipFollow(clip.id, f) }
        }
      }
      Text("This loop's own; \"row\" follows the loop channel's. Scenes launch on the row's.")
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  private func rulesLabel(_ s: String) -> some View {
    Text(s).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
  }

  /// The loop channel's rules: they apply to every loop without its own, so they are the Loops
  /// row's own.
  private var channelRules: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 3) {
        Text("Launch on").font(.caption).foregroundStyle(.secondary).frame(
          width: 64, alignment: .leading)
        ForEach(DJEngine.launchQuanta, id: \.self) { q in
          ChoiceButton(
            label: DJEngine.quantumLabel(q), selected: model.loopQuantum == q,
            tint: LoopRowView.tint
          ) { model.setLoopQuantum(q) }
        }
      }
      HStack(spacing: 3) {
        Text("Fade").font(.caption).foregroundStyle(.secondary).frame(
          width: 64, alignment: .leading)
        ForEach(LoopFade.allCases, id: \.self) { f in
          ChoiceButton(
            label: f.label, selected: model.loopChannel.fade == f, tint: LoopRowView.tint
          ) {
            model.setLoopFade(f)
          }
        }
      }
      HStack(spacing: 3) {
        Text("Tempo").font(.caption).foregroundStyle(.secondary).frame(
          width: 64, alignment: .leading)
        ChoiceButton(
          label: "louder deck", selected: model.loopFollow == .louder, tint: LoopRowView.tint
        ) { model.setLoopFollow(.louder) }
        ChoiceButton(
          label: "own deck", selected: model.loopFollow == .source, tint: LoopRowView.tint
        ) { model.setLoopFollow(.source) }
        if let d = model.followingDeck {
          Text("→ \(d)").font(.caption.bold()).foregroundStyle(deckTint(d))
        }
      }
      Text("The loop channel's: every loop without its own follows them.")
        .font(.caption2).foregroundStyle(.tertiary)
    }
  }

  private func placement(_ clip: ClipState) -> some View {
    HStack(spacing: DJStyle.s) {
      Button("Under the mixer") { model.playClip(clip.id, on: "L") }
        .disabled(clip.onDeck == nil)
      Button("→A") { model.playClip(clip.id, on: "A") }
        .tint(clip.onDeck == "A" ? DJStyle.deckA : nil).buttonStyle(.borderedProminent)
      Button("→B") { model.playClip(clip.id, on: "B") }
        .tint(clip.onDeck == "B" ? DJStyle.deckB : nil).buttonStyle(.borderedProminent)
      Spacer(minLength: 0)
      if let d = clip.onDeck {
        Text("on deck \(d)").font(.caption.bold()).foregroundStyle(deckTint(d))
      } else {
        Text(clip.loop == .off ? "off" : "under the mixer").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
  }

  // MARK: tuning

  /// A loop is audio: its sound is tuned on the track it was taken from. With that track on a
  /// deck, each of its instruments opens the sound panel (`VoiceEditor`); otherwise load it.
  @ViewBuilder private func tuningEditor(_ clip: ClipState) -> some View {
    if model.originCID(clip.id) == nil {
      Text(
        clip.steps != nil
          ? "A sequence: tune the loops it is made of."
          : "Taken from a sample, not a net: it has no instruments to tune."
      )
      .font(.caption).foregroundStyle(.secondary)
    } else {
      let decks = model.decksPlayingOrigin(clip.id)
      if decks.isEmpty {
        Text("Load the track it was taken from to tune its instruments.")
          .font(.caption).foregroundStyle(.secondary)
        HStack(spacing: DJStyle.s) {
          Button("Load source on A") { Task { await model.loadOrigin(clip.id, on: "A") } }
          Button("on B") { Task { await model.loadOrigin(clip.id, on: "B") } }
        }
        .controlSize(.small)
      }
      ForEach(decks, id: \.self) { deck in
        let voices = model.decks[deck]?.voices ?? []
        VStack(alignment: .leading, spacing: 3) {
          Text("On deck \(deck)").font(.caption.bold()).foregroundStyle(deckTint(deck))
          FlowRow(spacing: 4) {
            ForEach(voices, id: \.channel) { v in
              let t = Tuning(deck: deck, channel: v.channel)
              Button("\(v.role): \(v.instrument)") { tuning = t }
                .controlSize(.small)
                .popover(
                  isPresented: Binding(get: { tuning == t }, set: { if !$0 { tuning = nil } })
                ) {
                  VoiceEditor(
                    deck: deck, role: v.role, channel: v.channel, model: model, tint: deckTint(deck)
                  )
                }
                .help("Edit \(v.instrument)'s sound on deck \(deck), live")
            }
          }
        }
      }
      if !decks.isEmpty {
        Text(
          "Tuning changes the deck playing the track; take the loop again (LOOP, or ⟲) to keep "
            + "the new sound."
        )
        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
