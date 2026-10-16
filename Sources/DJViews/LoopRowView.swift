import DJCore
import SwiftUI

/// One clip on the row, for SwiftUI.
struct ClipState: Equatable, Identifiable {
  var id: String
  var title: String
  var source: String
  var bars: Int
  var bpm: Double
  var overview: WaveformOverview
  /// Where it is: the deck playing it ("L" is the loop channel), else "A"/"B" holding it paused.
  var playingOn: String?
}

/// A take in progress on a deck: bars so far, and whether LOOP was let go (its last bar is
/// finishing).
struct RecordingState: Equatable {
  var bars: Int
  var released: Bool
}

/// The loop channel's strip.
struct LoopChannelState: Equatable {
  var clipID: String?
  var playing = false
  var volume = 0.8
  var mute = false
  var overlay: WaveformOverlay?
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
        Button {
          model.toggleLoopChannel()
        } label: {
          Image(systemName: model.loopChannel.playing ? "stop.fill" : "play.fill")
        }
        .buttonStyle(
          TransportButtonStyle(tint: Self.tint, active: model.loopChannel.playing, size: 26)
        )
        .disabled(model.loopChannel.clipID == nil)
        .help(model.loopChannel.playing ? "Stop the loop channel" : "Play the loop channel")
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
        Spacer(minLength: 0)
        Text("hold a deck's LOOP to record its bars").font(.caption).foregroundStyle(.secondary)
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
          ForEach(model.clips) { clip in tile(clip) }
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

  private func tint(_ deck: String?) -> Color {
    switch deck {
    case "A": DJStyle.deckA
    case "B": DJStyle.deckB
    default: Self.tint
    }
  }

  private func tile(_ clip: ClipState) -> some View {
    let onLoop = clip.playingOn == "L"
    let color = tint(clip.playingOn ?? clip.source)
    return VStack(alignment: .leading, spacing: DJStyle.xs) {
      WaveformStrip(
        overview: clip.overview, overlay: onLoop ? model.loopChannel.overlay : nil, tint: color
      )
      .frame(height: 40)
      HStack(spacing: DJStyle.xs) {
        DeckBadge(name: clip.source, tint: tint(clip.source)).scaleEffect(0.7).frame(
          width: 20, height: 20)
        Text("\(clip.bars) bar\(clip.bars == 1 ? "" : "s") · \(String(format: "%.1f", clip.bpm))")
          .font(.caption).monospacedDigit()
        Spacer(minLength: 0)
        if let on = clip.playingOn, on != "L" {
          Text("on \(on)").font(.caption2.bold()).foregroundStyle(tint(on))
        }
      }
      HStack(spacing: DJStyle.xs) {
        Button(onLoop ? "Looping" : "Loop") { model.playClip(clip.id, on: "L") }
          .tint(onLoop ? Self.tint : nil).buttonStyle(.borderedProminent)
          .help("Loop it on the loop channel, in time with its deck")
        Button("→A") { model.playClip(clip.id, on: "A") }
          .tint(clip.playingOn == "A" ? DJStyle.deckA : nil).buttonStyle(.borderedProminent)
          .help("Move it onto deck A")
        Button("→B") { model.playClip(clip.id, on: "B") }
          .tint(clip.playingOn == "B" ? DJStyle.deckB : nil).buttonStyle(.borderedProminent)
          .help("Move it onto deck B")
        Spacer(minLength: 0)
        Button {
          model.removeClip(clip.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless).help("Take it off the row")
      }
      .controlSize(.small)
    }
    .padding(DJStyle.s)
    .frame(width: 210)
    .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(onLoop ? 0.16 : 0.06)))
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(onLoop ? 0.8 : 0.25))
    )
    .draggable(clip.id)
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
