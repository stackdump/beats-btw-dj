import AppKit
import DJCore
import SwiftUI

/// One clip on the row, for SwiftUI.
struct ClipState: Equatable, Identifiable {
  var id: String
  var title: String
  var source: String
  var bars: Int
  var beats: Int
  /// "2 bars", "6 beats".
  var lengthLabel: String
  var bpm: Double
  var overview: WaveformOverview
  /// Under the mixer: off, coming in, looping, going out.
  var loop: DJEngine.LoopState = .off
  /// Its level under the mixer.
  var gain = 1.0
  /// Muted / soloed under the mixer (it plays on, silent, while muted or soloed out).
  var muted = false
  var soloed = false
  /// Key lock: on (its own setting or the row's); and whether a time-stretched copy is
  /// playing, or being made.
  var keyLock = false
  var stretched = false
  var stretching = false
  /// How far through the loop it is (0…1), while it plays under the mixer.
  var playhead: Double?
  /// While it waits to come in or go out: how long until it switches.
  var countdown: LoopCountdown?
  /// The deck (A/B) holding it: the one playing it, else one holding it paused.
  var onDeck: String?
  /// A sequence's steps (nil for a take).
  var steps: [StepState]?
  /// Where it came from, as lines to read (`ClipState.describe`).
  var provenance: [String] = []
  /// The same, as the JSON the library keeps.
  var provenanceJSON: String?
  /// Its colour, one of `LoopClip.palette` (nil: the row's violet).
  var color: String?
  /// The genre of the net it was taken from (searched by the row's filter).
  var genre: String?
  /// What the deck was playing when it was taken.
  var originTitle: String?
  /// Whether "Load source on A/B" can load that again (`DJEngine.clipOrigin`).
  var canLoadOrigin = false
  /// Its after effects (`LoopClip.fx`).
  var fx = LoopFX()
}

extension ClipState {
  /// Where a clip came from, in a few lines: the track, the bars, the tempo and what was set.
  static func describe(_ p: JSONValue?) -> [String] {
    guard let p else { return [] }
    switch p["op"]?.string {
    case "crop":
      let b = p["beats"]?.array?.compactMap(\.int) ?? []
      let range = b.count == 2 ? "beats \(b[0] + 1)–\(b[1])" : "a crop"
      return ["Cropped to \(range) of:"] + describe(p["parent"]).map { "  " + $0 }
    case "sequence":
      let steps = p["steps"]?.array ?? []
      return ["Sequence of \(steps.count) step\(steps.count == 1 ? "" : "s"):"]
        + steps.map { s in
          let r = s["repeats"]?.int ?? 1
          return "  \(s["title"]?.string ?? "?")\(r > 1 ? " ×\(r)" : "")"
        }
    default: break
    }
    var lines: [String] = []
    let deck = p["deck"]?.string ?? "?"
    lines.append("Deck \(deck): \(p["title"]?.string ?? "—")")
    if let src = p["source"], src["kind"]?.string == "net", let share = src["share"] {
      var s = [share["genre"]?.string, share["seed"]?.double.map { "seed \(Int($0))" }]
        .compactMap { $0 }.joined(separator: " ")
      if let st = share["structure"]?.string { s += " (\(st))" }
      lines.append("Track: \(s)")
    } else if let src = p["source"], src["kind"]?.string == "sample" {
      lines.append("Sample: \(src["title"]?.string ?? "audio")")
    }
    var at =
      (p["grabbed"]?.bool == true ? "Grabbed after the fact, from bar " : "From bar ")
      + "\(p["bar"]?.int ?? 0)"
    if let sec = p["section"]?["name"]?.string { at += ", in \(sec)" }
    if let bars = p["bars"]?.int { at += ", \(bars) bar\(bars == 1 ? "" : "s")" }
    lines.append(at)
    if let t = p["tempo"] {
      var s = String(format: "%.1f bpm", t["bpm"]?.double ?? 0)
      if let pitch = t["pitch"]?.double, abs(pitch) > 1e-6 {
        s += String(format: " (tempo fader %+.1f%%)", pitch * Deck.pitchRange * 100)
      }
      lines.append(s)
    }
    if let k = p["params"] {
      var set: [String] = []
      func knob(_ name: String, _ key: String, centre: Double) {
        if let v = k[key]?.double, abs(v - centre) > 0.02 {
          set.append(String(format: "\(name) %.2f", v))
        }
      }
      knob("gain", "gain", centre: 0.5)
      knob("filter", "filter", centre: 0.5)
      knob("low", "eqLow", centre: 0.5)
      knob("mid", "eqMid", centre: 0.5)
      knob("high", "eqHigh", centre: 0.5)
      lines.append(set.isEmpty ? "EQ and filter flat" : set.joined(separator: " · "))
    }
    if let off = p["rolesOff"]?.array?.compactMap(\.string), !off.isEmpty {
      lines.append("Muted: " + off.joined(separator: ", "))
    }
    if let st = p["stemsMuted"]?.array?.compactMap(\.string), !st.isEmpty {
      lines.append("STEMS held: " + st.joined(separator: ", "))
    }
    if let m = p["macros"]?.array?.compactMap(\.string), !m.isEmpty {
      lines.append("Macros: " + m.joined(separator: ", "))
    }
    if let r = p["recorded"]?.string {
      lines.append("Recorded \(r) · build \(p["build"]?.string ?? "?")")
    }
    return lines
  }
}

/// How long a waiting clip has until it switches (`DJEngine.loopCountdown`), for its tile.
struct LoopCountdown: Equatable {
  /// Beats to go, rounded up (1 on the last beat).
  var beats: Int
  /// How much of the wait has gone by, 0…1 (the ring), in hundredths.
  var progress: Double
  /// "in 3" (beats), "in 4 bars" once it is more than two bars off.
  var label: String
  /// Beats to go, unrounded (the control socket's).
  var beatsLeft: Double

  init(beats left: Double, of total: Double) {
    beatsLeft = left
    beats = max(1, Int((left - 1e-6).rounded(.up)))
    progress = total > 0 ? ((1 - left / total) * 100).rounded() / 100 : 1
    label = beats > 8 ? "in \((beats + 3) / 4) bars" : "in \(beats)"
  }

  init(_ c: (beats: Double, of: Double)) { self.init(beats: c.beats, of: c.of) }
}

/// A saved scene, as its chip.
struct SceneState: Equatable, Identifiable {
  var name: String
  var id: String { name }
  /// Its clips still on the row, of all it was saved with.
  var count: Int
  var missing: Int
  /// Exactly its clips are looping now (and none waiting to switch). Never a scene with none
  /// on the row: nothing looping is not that scene playing.
  var active: Bool

  /// The engine's scenes, in order.
  @MainActor static func row(_ dj: DJEngine) -> [SceneState] {
    let looping = Set(dj.loopingClips)
    let settled = dj.clips.allSatisfy { dj.loopSwitchFrame($0.id) == nil }
    return dj.scenes.map { s in
      let ids = s.clips.map(\.clipID).filter { dj.clip($0) != nil }
      return SceneState(
        name: s.name, count: ids.count, missing: s.clips.count - ids.count,
        active: settled && !ids.isEmpty && Set(ids) == looping)
    }
  }
}

/// One step of a sequence, for its chip.
struct StepState: Equatable {
  var clipID: String
  /// The clip's short name ("loop 3"), or "missing" if it is no longer on the row.
  var name: String
  var repeats: Int
}

/// A take in progress on a deck: bars so far, and whether LOOP was let go (its last bar is
/// finishing).
struct RecordingState: Equatable {
  var bars: Int
  var released: Bool
}

/// The loop channel's strip.
struct LoopChannelState: Equatable {
  /// How many clips are looping (or on their way in).
  var looping = 0
  var volume = 0.8
  var mute = false
  var reverb = ReverbState()
  /// How loops come in and go out.
  var fade = LoopFade.declick
  /// The row's key lock, for clips without their own.
  var keyLock = false
}

/// The row under the decks: every LOOP-record take as a clip, and the loop channel that plays
/// them. A clip goes onto deck A or B (its buttons, or drag it onto a deck) and back (drop it
/// here, or the deck's ↩).
struct LoopRowView: View {
  let model: AppModel
  static let tint = Color(red: 0.72, green: 0.55, blue: 1.0)

  var body: some View {
    VStack(alignment: .leading, spacing: DJStyle.s) {
      HStack(spacing: DJStyle.m) {
        Text("LOOPS").font(DJStyle.sectionLabel).tracking(1.2).foregroundStyle(.secondary)
        Button(model.selectedClips.isEmpty ? "Join" : "Join \(model.selectedClips.count)") {
          model.joinSelected()
        }
        .controlSize(.small).disabled(model.selectedClips.isEmpty)
        .help("Select loops (○ on each), then join them into a sequence, in row order")
        Button("Stop all") { model.stopAllLoops() }
          .controlSize(.small).disabled(model.loopChannel.looping == 0)
          .help("Every loop out on the next downbeat")
        Toggle(
          "Mute",
          isOn: Binding(get: { model.loopChannel.mute }, set: { model.setLoopMute($0) })
        )
        .toggleStyle(.button).controlSize(.small)
        LabeledSlider(
          label: "Loop vol",
          value: Binding(get: { model.loopChannel.volume }, set: { model.setVolume("L", $0) }),
          range: 0...1
        )
        .frame(width: 220)
        LabeledSlider(
          label: String(format: "Reverb %.0f%%", model.loopChannel.reverb.wet * 100),
          value: Binding(
            get: { model.loopChannel.reverb.wet }, set: { model.setReverb("L", "reverbWet", $0) }),
          range: 0...1
        )
        .frame(width: 220)
        .help("The loops' reverb (the takes themselves are dry)")
        fadeChoices
        Toggle(
          "🔒 key",
          isOn: Binding(get: { model.loopChannel.keyLock }, set: { model.setLoopKeyLock($0) })
        )
        .toggleStyle(.button).controlSize(.small)
        .help("Key lock for every loop without its own: at another tempo a loop keeps its pitch")
        Spacer(minLength: 0)
        Text(
          "tap a loop to bring it in or out on the next \(DJEngine.quantumLabel(model.loopQuantum))"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      LaunchBar(model: model)
      if !model.clips.isEmpty || !model.removedLoops.isEmpty { LoopLibraryBar(model: model) }
      let shown = model.visibleClips
      if shown.isEmpty {
        Text(model.clips.isEmpty ? "No loops yet" : "No loops match")
          .font(.caption).foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 64)
      } else {
        // wraps onto more rows as takes pile up (no scroll view: the window already scrolls)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 210, maximum: 210), spacing: DJStyle.s)],
          alignment: .leading, spacing: DJStyle.s
        ) {
          ForEach(shown) { clip in ClipTile(clip: clip, model: model) }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      model.playClip(id, on: "L")
      return true
    }
  }

  /// "Fade: off | 10 ms | 1 beat | 1 bar": how loops come in and go out on the downbeat.
  private var fadeChoices: some View {
    HStack(spacing: 3) {
      Text("Fade").font(.caption).foregroundStyle(.secondary).fixedSize()
      ForEach(LoopFade.allCases, id: \.self) { f in
        ChoiceButton(label: f.label, selected: model.loopChannel.fade == f, tint: Self.tint) {
          model.setLoopFade(f)
        }
      }
    }
    .help("How a loop comes in and goes out: 10 ms only takes the click off")
  }
}

func deckTint(_ deck: String?) -> Color {
  switch deck {
  case "A": DJStyle.deckA
  case "B": DJStyle.deckB
  default: LoopRowView.tint
  }
}

/// One clip on the row: tap the waveform (or ▶/■) to bring it in or out on the next downbeat;
/// drag its left or right edge to crop it to the beat; drag the tile onto a deck to move it
/// there, or onto another tile to put it before that one.
struct ClipTile: View {
  let clip: ClipState
  let model: AppModel
  /// The crop being dragged, in beats (nil when not cropping).
  @State private var crop: (from: Int, to: Int)?
  @State private var showInfo = false
  @State private var showFx = false

  var body: some View {
    let on = clip.loop == .on || clip.loop == .stopping
    let color = clip.onDeck.map { deckTint($0) } ?? clipTint(clip.color)
    let pending = clip.loop == .starting || clip.loop == .stopping
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      ClipTitleField(clip: clip, model: model)
      waveform(on: on).frame(height: 40)
      if let steps = clip.steps { stepChips(steps) }
      HStack(spacing: DJStyle.xs) {
        let picked = model.selectedClips.contains(clip.id)
        Button {
          model.toggleSelected(clip.id)
        } label: {
          Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(picked ? LoopRowView.tint : .secondary)
        }
        .buttonStyle(.borderless).help(picked ? "Unselect" : "Select, to join into a sequence")
        if clip.steps != nil {
          Image(systemName: "list.bullet").font(.caption).foregroundStyle(LoopRowView.tint)
            .help("A sequence")
        } else {
          DeckBadge(name: clip.source, tint: deckTint(clip.source)).scaleEffect(0.7).frame(
            width: 20, height: 20)
        }
        Text(
          crop.map { "→ \($0.to - $0.from) of \(clip.beats) beats" }
            ?? "\(clip.lengthLabel) · \(String(format: "%.1f", clip.bpm))"
        )
        .font(.caption).monospacedDigit()
        Spacer(minLength: 0)
        ClipNoteMarker(clipID: clip.id, model: model)
        if let slot = model.padSlot(clip.id) {
          // the Inpulse pad (LOOP pad mode) that switches it, by its place on the whole row
          Text(slot).font(.caption2.monospaced())
            .padding(.horizontal, 4).background(Capsule().fill(Color.secondary.opacity(0.2)))
            .help("Inpulse pad \(slot.dropFirst()) on deck \(slot.prefix(1)), in LOOP pad mode")
        }
        if let on = clip.onDeck {
          Text("on \(on)").font(.caption2.bold()).foregroundStyle(deckTint(on))
        }
      }
      HStack(spacing: DJStyle.xs) {
        Button {
          model.toggleLoop(clip.id)
        } label: {
          Image(systemName: clip.loop == .off || clip.loop == .stopping ? "play.fill" : "stop.fill")
        }
        .tint(on || clip.loop == .starting ? LoopRowView.tint : nil).buttonStyle(.borderedProminent)
        .opacity(pending ? 0.6 : 1)
        .help(on ? "Out on the next launch boundary" : "In on the next launch boundary")
        Slider(
          value: Binding(get: { clip.gain }, set: { model.setClipGain(clip.id, $0) }), in: 0...1
        )
        .controlSize(.mini).frame(width: 52).help("This loop's level")
        Button("→A") { model.playClip(clip.id, on: "A") }
          .tint(clip.onDeck == "A" ? DJStyle.deckA : nil).buttonStyle(.borderedProminent)
          .help("Move it onto deck A")
        Button("→B") { model.playClip(clip.id, on: "B") }
          .tint(clip.onDeck == "B" ? DJStyle.deckB : nil).buttonStyle(.borderedProminent)
          .help("Move it onto deck B")
        Spacer(minLength: 0)
        Button {
          showInfo.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless).help("Where this loop came from")
        .popover(isPresented: $showInfo) { provenanceView }
        Button {
          model.removeClip(clip.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Take it off the row (kept under Removed; Undo for a few seconds)")
      }
      .controlSize(.small)
      soundRow
    }
    .padding(DJStyle.s)
    .frame(width: 210)
    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(on ? 0.16 : 0.06)))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        color.opacity(on ? 0.8 : (pending ? 0.5 : 0.25)),
        style: StrokeStyle(lineWidth: 1, dash: pending ? [4, 3] : []))
    )
    .contextMenu { menu }
    // the id for drops in the app; a WAV file for Finder
    .draggable(ClipDrag(id: clip.id, clip: model.engine?.clip(clip.id)))
    // dropped on a sequence: a new last step; on another tile: reordered, just before it
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first, id != clip.id, model.clips.contains(where: { $0.id == id }) else {
        return false
      }
      if let steps = clip.steps {
        model.editSequence(
          clip.id,
          steps.map { SequenceStep(clipID: $0.clipID, repeats: $0.repeats) }
            + [SequenceStep(clipID: id)])
      } else {
        model.moveClip(id, before: clip.id)
      }
      return true
    }
  }

  /// Mute, solo and key lock for this loop under the mixer.
  private var soundRow: some View {
    HStack(spacing: DJStyle.xs) {
      Toggle("M", isOn: Binding(get: { clip.muted }, set: { model.setClipMute(clip.id, $0) }))
        .tint(.orange).help("Mute: it plays on silently, and comes back in time")
      Toggle("S", isOn: Binding(get: { clip.soloed }, set: { model.setClipSolo(clip.id, $0) }))
        .tint(.yellow).help("Solo: only soloed loops are heard under the mixer")
      Toggle(
        "🔒 key", isOn: Binding(get: { clip.keyLock }, set: { model.setClipKeyLock(clip.id, $0) })
      )
      .tint(LoopRowView.tint)
      .help("Key lock: at another tempo it keeps its pitch (time-stretched, not sped up)")
      Toggle("FX", isOn: $showFx)
        .tint(clip.fx.isActive ? ClipFxBadge.tint : nil)
        .help(clip.fx.isActive ? "FX: \(clip.fx.summary)" : "Drive, distortion and tone")
        .popover(isPresented: $showFx) {
          ClipFxEditor(clip: clip, model: model).padding(12).frame(width: 360)
        }
      Spacer(minLength: 0)
      if clip.stretching {
        Text("stretching…").font(.caption2).foregroundStyle(.secondary)
      } else if clip.stretched {
        Text("stretched").font(.caption2).foregroundStyle(LoopRowView.tint)
          .help("Playing a time-stretched copy at the tempo it is following")
      }
    }
    .toggleStyle(.button).controlSize(.mini)
  }

  /// A sequence's steps: tap a chip for ×1 → ×2 → ×4; right-click to move or remove it.
  private func stepChips(_ steps: [StepState]) -> some View {
    func edited(_ change: (inout [SequenceStep]) -> Void) {
      var s = steps.map { SequenceStep(clipID: $0.clipID, repeats: $0.repeats) }
      change(&s)
      model.editSequence(clip.id, s)
    }
    return FlowRow(spacing: 3) {
      ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
        Button("\(step.name)\(step.repeats > 1 ? " ×\(step.repeats)" : "")") {
          edited { $0[i].repeats = $0[i].repeats >= 4 ? 1 : $0[i].repeats * 2 }
        }
        .buttonStyle(.bordered).controlSize(.mini)
        .foregroundStyle(step.name == "missing" ? Color.red : Color.primary)
        .contextMenu {
          if i > 0 { Button("Move earlier") { edited { $0.swapAt(i, i - 1) } } }
          if i < steps.count - 1 { Button("Move later") { edited { $0.swapAt(i, i + 1) } } }
          if steps.count > 1 { Button("Remove") { edited { $0.remove(at: i) } } }
        }
        .help("×1 → ×2 → ×4 (right-click: move or remove)")
      }
    }
  }

  /// Right-click on a tile.
  @ViewBuilder private var menu: some View {
    Button("Rename…") { showInfo = true }
    Menu("Colour") {
      Button("None") { model.setClipColor(clip.id, nil) }
      ForEach(LoopClip.palette, id: \.self) { name in
        Button(name.capitalized) { model.setClipColor(clip.id, name) }
      }
    }
    ClipFxMenu(fx: clip.fx) { model.setClipFx(clip.id, $0) }
    Divider()
    Button("Load source on A") { Task { await model.loadOrigin(clip.id, on: "A") } }
      .disabled(!clip.canLoadOrigin)
    Button("Load source on B") { Task { await model.loadOrigin(clip.id, on: "B") } }
      .disabled(!clip.canLoadOrigin)
    Button("Export WAV…") { model.exportClip(clip.id) }
    Divider()
    Button("Remove") { model.removeClip(clip.id) }
  }

  private var provenanceView: some View {
    VStack(alignment: .leading, spacing: 4) {
      ClipNameEditor(clip: clip, model: model)
      ClipColorSwatches(current: clip.color) { model.setClipColor(clip.id, $0) }
        .padding(.bottom, 4)
      ClipProvenanceDetails(clip: clip, model: model)
    }
    .padding(12).frame(minWidth: 280, alignment: .leading)
  }

  /// The waveform with the playhead, the beat lines, and a crop handle on each edge.
  private func waveform(on: Bool) -> some View {
    WaveformStrip(
      overview: clip.overview, overlay: clip.playhead.map { WaveformOverlay(playhead: $0) },
      tint: on ? LoopRowView.tint : LoopRowView.tint.opacity(0.45)
    )
    .contentShape(Rectangle())
    .onTapGesture { model.toggleLoop(clip.id) }
    .overlay(alignment: .topTrailing) {
      if let c = clip.countdown {
        LoopCountdownBadge(countdown: c, stopping: clip.loop == .stopping).padding(2)
          .allowsHitTesting(false)
      }
    }
    .overlay {
      GeometryReader { geo in
        let w = geo.size.width
        let beats = max(1, clip.beats)
        let x = { (b: Int) in w * CGFloat(b) / CGFloat(beats) }
        let span = crop ?? (0, beats)
        ZStack(alignment: .topLeading) {
          // beat lines, bars stronger
          if beats <= 64 {
            ForEach(1..<beats, id: \.self) { b in
              Rectangle().fill(Color.white.opacity(b % 4 == 0 ? 0.35 : 0.12))
                .frame(width: 1, height: geo.size.height).offset(x: x(b))
            }
          }
          // what the crop leaves out
          Rectangle().fill(Color.black.opacity(0.6)).frame(width: x(span.from))
          Rectangle().fill(Color.black.opacity(0.6))
            .frame(width: w - x(span.to)).offset(x: x(span.to))
          handle(height: geo.size.height).offset(x: x(span.from))
            .gesture(edgeDrag(width: w, beats: beats, left: true))
          handle(height: geo.size.height).offset(x: x(span.to) - 8)
            .gesture(edgeDrag(width: w, beats: beats, left: false))
        }
        .allowsHitTesting(true)
      }
    }
    .help("Tap: in/out on the next launch boundary. Drag an edge to crop it to the beat")
  }

  private func handle(height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 2).fill(LoopRowView.tint.opacity(0.9))
      .frame(width: 8, height: height)
      .overlay(Capsule().fill(Color.black.opacity(0.5)).frame(width: 2, height: height * 0.4))
      .contentShape(Rectangle())
  }

  private func edgeDrag(width: CGFloat, beats: Int, left: Bool) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .local)
      .onChanged { g in
        let cur = crop ?? (0, beats)
        let edge = left ? 0 : width
        let b = Int(((edge + g.translation.width) / width * CGFloat(beats)).rounded())
        crop =
          left
          ? (min(max(0, b), cur.to - 1), cur.to) : (cur.from, max(min(beats, b), cur.from + 1))
      }
      .onEnded { _ in
        if let c = crop, c.from > 0 || c.to < beats {
          model.cropClip(clip.id, from: c.from, to: c.to)
        }
        crop = nil
      }
  }
}

/// A deck's ways to take a loop, in one group: LOOP record, the tap length beside it, and the
/// grab buttons for what was just played.
struct LoopCaptureControls: View {
  let name: String
  let model: AppModel

  var body: some View {
    HStack(spacing: 4) {
      LoopRecordButton(name: name, model: model)
      TapLengthChip(model: model)
      GrabBarsControl(name: name, model: model)
    }
  }
}

/// How many bars a tap of LOOP records (`AppModel.tapBars`, kept in the app's defaults): a
/// click steps through 1, 2, 4, 8; right-click picks one. No dropdowns on the deck.
struct TapLengthChip: View {
  let model: AppModel

  var body: some View {
    Text("tap \(model.tapBars)").monospacedDigit()
      .font(.caption2.bold())
      .padding(.horizontal, 5).padding(.vertical, 4)
      .foregroundStyle(Color.red.opacity(0.9))
      .background(Capsule().fill(Color.red.opacity(0.08)))
      .overlay(Capsule().strokeBorder(Color.red.opacity(0.35)))
      .contentShape(Capsule())
      .onTapGesture { model.stepTapBars() }
      .contextMenu {
        ForEach(AppModel.tapBarChoices, id: \.self) { n in
          Button("Tap records \(n) bar\(n == 1 ? "" : "s")") { model.setTapBars(n) }
        }
      }
      .help(
        "A quick tap of LOOP records exactly \(model.tapBars) bar\(model.tapBars == 1 ? "" : "s") "
          + "from the downbeat. Click to change (1, 2, 4, 8); hold LOOP to record freely"
      )
      .accessibilityLabel("Tap length \(model.tapBars) bars")
  }
}

/// "⟲ 1 2 4": take the last 1, 2 or 4 whole bars this deck already played, after the fact.
struct GrabBarsControl: View {
  let name: String
  let model: AppModel
  static let choices = [1, 2, 4]

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "arrow.counterclockwise").font(.caption2.bold())
        .foregroundStyle(LoopRowView.tint.opacity(0.8))
      ForEach(Self.choices, id: \.self) { n in
        Text("\(n)").monospacedDigit()
          .font(.caption2.bold())
          .frame(minWidth: 14)
          .padding(.vertical, 4)
          .foregroundStyle(LoopRowView.tint)
          .background(Capsule().fill(LoopRowView.tint.opacity(0.14)))
          .contentShape(Capsule())
          .onTapGesture { model.grabBars(name, bars: n) }
          .help("Grab the last \(n) bar\(n == 1 ? "" : "s") deck \(name) played as a loop")
          .accessibilityLabel("Grab last \(n) bars")
      }
    }
  }
}

/// The row's second line: what loops launch on (a beat, a bar, 2, 4 or 8 bars), and the scenes —
/// "Save scene" keeps the loops playing now; a scene's chip brings exactly those back.
struct LaunchBar: View {
  let model: AppModel

  var body: some View {
    HStack(alignment: .top, spacing: DJStyle.m) {
      HStack(spacing: 3) {
        Text("Launch on").font(.caption).foregroundStyle(.secondary).fixedSize()
        ForEach(DJEngine.launchQuanta, id: \.self) { q in
          ChoiceButton(
            label: DJEngine.quantumLabel(q), selected: model.loopQuantum == q,
            tint: LoopRowView.tint
          ) { model.setLoopQuantum(q) }
          .help("Loops and scenes come in and go out on the next \(DJEngine.quantumLabel(q))")
        }
      }
      Divider().frame(height: 18)
      HStack(spacing: 3) {
        Text("Tempo").font(.caption).foregroundStyle(.secondary).fixedSize()
        ChoiceButton(
          label: "louder deck", selected: model.loopFollow == .louder, tint: LoopRowView.tint
        ) { model.setLoopFollow(.louder) }
        .help("Every loop follows the tempo of whichever playing deck is louder in the mix")
        ChoiceButton(
          label: "own deck", selected: model.loopFollow == .source, tint: LoopRowView.tint
        ) { model.setLoopFollow(.source) }
        .help("Each loop follows the deck it was taken from")
        if let d = model.followingDeck {
          Text("→ \(d)").font(.caption.bold()).foregroundStyle(deckTint(d))
            .help("The loops follow deck \(d) now")
        }
      }
      .arrowKeys([LoopFollow.louder, .source], current: model.loopFollow) {
        model.setLoopFollow($0)
      }
      Divider().frame(height: 18)
      SceneStrip(model: model)
      Spacer(minLength: 0)
    }
  }
}

/// A scene: tap to launch it (its loops in, the others out, on the next launch boundary);
/// right-click to rename, overwrite or delete it. Lit while exactly its loops play.
struct SceneChip: View {
  let scene: SceneState
  let model: AppModel
  let rename: (String) -> Void

  var body: some View {
    Button {
      model.launchScene(scene.name)
    } label: {
      HStack(spacing: 3) {
        Text(scene.name)
        Text("\(scene.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.borderedProminent).controlSize(.small)
    .tint(scene.active ? LoopRowView.tint : Color.secondary.opacity(0.35))
    .contextMenu {
      Button("Rename…") { rename(scene.name) }
      Button("Overwrite with the loops playing now") { model.saveScene(scene.name) }
        .disabled(model.loopChannel.looping == 0)
      Button("Delete", role: .destructive) { model.deleteScene(scene.name) }
    }
    .help(
      "Launch: these \(scene.count) loops in, the others out, on the next "
        + DJEngine.quantumLabel(model.loopQuantum)
        + (scene.missing > 0 ? " (\(scene.missing) no longer on the row)" : "")
        + ". Right-click: rename, overwrite, delete")
  }
}

/// A waiting clip's countdown: a ring that fills as the boundary nears, and "in 3".
struct LoopCountdownBadge: View {
  let countdown: LoopCountdown
  /// Going out (amber) rather than coming in (the loops' violet).
  let stopping: Bool
  static let outTint = Color(red: 1.0, green: 0.7, blue: 0.25)

  var body: some View {
    let tint = stopping ? Self.outTint : LoopRowView.tint
    HStack(spacing: 3) {
      ZStack {
        Circle().stroke(tint.opacity(0.3), lineWidth: 2)
        Circle().trim(from: 0, to: countdown.progress)
          .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
      .frame(width: 11, height: 11)
      Text(countdown.label).font(.caption2.bold().monospacedDigit()).foregroundStyle(tint)
    }
    .padding(.horizontal, 4).padding(.vertical, 1)
    .background(Capsule().fill(Color.black.opacity(0.65)))
    .accessibilityLabel(stopping ? "Out \(countdown.label)" : "In \(countdown.label)")
  }
}

/// A deck's LOOP record button: hold to take the deck's bars, let go to drop them on the row.
/// A quick tap records `AppModel.tapBars` bars instead.
struct LoopRecordButton: View {
  let name: String
  let model: AppModel
  @State private var held = false

  var body: some View {
    let take = model.recording[name]
    let on = take != nil
    HStack(spacing: 3) {
      Image(systemName: "record.circle")
      Text(take.map { "\($0.bars)" } ?? "LOOP").monospacedDigit()
    }
    .font(.caption.bold())
    .padding(.horizontal, 7).padding(.vertical, 4)
    .foregroundStyle(on ? Color.black : Color.red)
    .background(
      Capsule().fill(
        on ? Color.red.opacity(take?.released == true ? 0.55 : 1) : Color.red.opacity(0.12))
    )
    .overlay(Capsule().strokeBorder(Color.red.opacity(0.6)))
    .contentShape(Capsule())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !held else { return }
          held = true
          model.loopRecord(name, on: true)
        }
        .onEnded { _ in
          held = false
          model.loopRecord(name, on: false)
        }
    )
    .help(
      "Hold to record this deck's bars; let go and they loop on the row under the mixer. "
        + "A quick tap records \(model.tapBars) bar\(model.tapBars == 1 ? "" : "s")"
    )
    .accessibilityLabel("Loop record")
  }
}
