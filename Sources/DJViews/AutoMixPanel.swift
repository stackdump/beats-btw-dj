import DJCore
import SwiftUI

/// Auto-mix as the mixer's foot shows it (AutoMix.swift): a value, so `poll` only republishes it
/// when something changed.
struct AutoMixDisplay: Equatable {
  var on = false
  var bars = AutoMixSettings.defaultBars
  var every = 0
  var phase = AutoMixPhase.off
  /// The deck coming in during a hand-off (its header says NEXT · auto).
  var incoming: String?
  var status = "auto-mix off"

  init() {}

  init(_ dj: DJEngine) {
    let s = dj.autoMix
    on = s.settings.on
    bars = s.settings.bars
    every = s.settings.every
    phase = s.phase
    incoming = s.incoming
    status = dj.autoMixStatus
  }

  /// A hand-off is running (from the prep point to its last bar): the AUTO button pulses.
  var handingOff: Bool { [.preparing, .armed, .mixing].contains(phase) }
}

/// AUTO, Mix now, the hand-off length, how long a track plays, and one status line, under the
/// crossfader. Everything goes through `AppModel` (recorded pokes); the hand-offs themselves are
/// derived and never recorded.
struct AutoMixPanel: View {
  let model: AppModel
  @State private var pulse = false

  var body: some View {
    let a = model.autoMix
    let tint = Color.accentColor
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        ChoiceButton(label: "AUTO", selected: a.on, tint: tint) { model.toggleAutoMix() }
          .opacity(a.handingOff && pulse ? 0.55 : 1)
          .help("Auto-mix: the decks hand over by themselves, a phrase-long walk across the set")
        Button("Mix now") { model.autoMixNow() }
          .controlSize(.small)
          .disabled(!a.on || a.handingOff)
          .help("Hand off at the next phrase boundary at least 4 bars away")
      }
      HStack(spacing: 2) {
        Text("mix").font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        ForEach(AutoMixSettings.lengths, id: \.self) { b in
          ChoiceButton(label: "\(b)", selected: a.bars == b, tint: tint) { model.setAutoMixBars(b) }
        }
      }
      .help("Hand-off length in bars")
      HStack(spacing: 2) {
        Text("play").font(.caption2).foregroundStyle(.secondary)
          .frame(width: 30, alignment: .leading)
        ForEach(AutoMixSettings.everies, id: \.self) { e in
          ChoiceButton(label: e == 0 ? "outro" : "\(e)", selected: a.every == e, tint: tint) {
            model.setAutoMixEvery(e)
          }
        }
      }
      .help("How long a track plays: a song to its outro (a loop 8 phrases), or 4 / 8 / 16 phrases")
      Text(a.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { pulse = false }
    .onChange(of: a.handingOff) { _, on in
      if on {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
      } else {
        pulse = false
      }
    }
  }
}
