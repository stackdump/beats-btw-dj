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
  /// How far through the loop it is (0…1), while it plays under the mixer.
  var playhead: Double?
  /// The deck (A/B) holding it: the one playing it, else one holding it paused.
  var onDeck: String?
  /// A sequence's steps (nil for a take).
  var steps: [StepState]?
  /// Where it came from, as lines to read (`ClipState.describe`).
  var provenance: [String] = []
  /// The same, as the JSON the library keeps.
  var provenanceJSON: String?
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
    var at = "From bar \(p["bar"]?.int ?? 0)"
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
        Spacer(minLength: 0)
        Text("tap a loop to bring it in or out on the next downbeat").font(.caption)
          .foregroundStyle(.secondary)
      }
      if model.clips.isEmpty {
        Text("No loops yet")
          .font(.caption).foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, minHeight: 64)
      } else {
        // wraps onto more rows as takes pile up (no scroll view: the window already scrolls)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 210, maximum: 210), spacing: DJStyle.s)],
          alignment: .leading, spacing: DJStyle.s
        ) {
          ForEach(model.clips) { clip in ClipTile(clip: clip, model: model) }
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

  var body: some View {
    let on = clip.loop == .on || clip.loop == .stopping
    let color = clip.onDeck.map { deckTint($0) } ?? LoopRowView.tint
    let pending = clip.loop == .starting || clip.loop == .stopping
    VStack(alignment: .leading, spacing: DJStyle.xs) {
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
        if let i = model.clips.firstIndex(where: { $0.id == clip.id }), i < 8 {
          // the Inpulse pad (LOOP pad mode) that switches it
          Text(i < 4 ? "A\(i + 1)" : "B\(i - 3)").font(.caption2.monospaced())
            .padding(.horizontal, 4).background(Capsule().fill(Color.secondary.opacity(0.2)))
            .help(
              "Inpulse pad \(i < 4 ? i + 1 : i - 3) on deck \(i < 4 ? "A" : "B"), in LOOP pad mode")
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
        .help(on ? "Out on the next downbeat" : "In on the next downbeat")
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
        .buttonStyle(.borderless).help("Take it off the row (and out of the library)")
      }
      .controlSize(.small)
    }
    .padding(DJStyle.s)
    .frame(width: 210)
    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(on ? 0.16 : 0.06)))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        color.opacity(on ? 0.8 : (pending ? 0.5 : 0.25)),
        style: StrokeStyle(lineWidth: 1, dash: pending ? [4, 3] : []))
    )
    .draggable(clip.id)
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

  private var provenanceView: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(clip.title).font(.headline)
      if clip.provenance.isEmpty {
        Text("No record of where it came from").foregroundStyle(.secondary)
      }
      ForEach(Array(clip.provenance.enumerated()), id: \.offset) { _, line in
        Text(line).font(.caption).monospacedDigit()
      }
      if let json = clip.provenanceJSON {
        Button("Copy as JSON") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(json, forType: .string)
        }
        .controlSize(.small).padding(.top, 4)
      }
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
    .help("Tap: in/out on the next downbeat. Drag an edge to crop it to the beat")
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

/// A deck's LOOP record button: hold to take the deck's bars, let go to drop them on the row.
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
    .help("Hold to record this deck's bars; let go and they loop on the row under the mixer")
    .accessibilityLabel("Loop record")
  }
}
