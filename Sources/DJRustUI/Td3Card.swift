import DJRust
import SwiftUI

// The loop bank (djandroid ui/Td3Card.kt): one-bar loops — eight Acid Bass lines and Floor & Sub
// — on a deck in place of its track (the deck page's Loops card), or a group's A and B on the
// two decks at once (the Mix page's Loops A / B card).

/// The groups in order, each its loops (A, B).
private func groups(_ loops: [Td3Loop]) -> [[Td3Loop]] {
  Dictionary(grouping: loops, by: \.group).sorted { $0.key < $1.key }.map(\.value)
}

/// The drums switch both loop cards carry.
private struct DrumsSwitch: View {
  let model: RustDJModel
  var body: some View {
    HStack(spacing: 6) {
      Caption("drums")
      DJToggle(label: "Loop drums", isOn: Binding(get: { model.td3Drums }, set: { model.setTd3Drums($0) }))
    }
  }
}

private struct LoopPad: View {
  let label: String
  var sub: String?
  let lit: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 2) {
        Text(label).font(.system(size: 17, weight: .medium)).lineLimit(1)
          .foregroundStyle(lit ? Color.black : Color.white)
        if let sub {
          Text(sub).font(.system(size: 11)).lineLimit(1).foregroundStyle(lit ? Color.black : DJTheme.dim)
        }
      }
      .padding(.vertical, 10).padding(.horizontal, 6).frame(minWidth: 52, maxWidth: .infinity, minHeight: 48)
      .background(lit ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent.opacity(lit ? 1 : 0.35), lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(lit ? .isSelected : [])
  }
}

/// A deck's loops: tap one to play it on this deck in place of the track, on the bar with the
/// other deck. Compose (or ⏮) brings a track back.
struct Td3DeckCard: View {
  let model: RustDJModel
  let deck: String

  var body: some View {
    let on = model.decks[deck]?.deck?.td3
    Card("Loops", trailing: { DrumsSwitch(model: model) }) {
      Caption(
        "One-bar loops: eight acid bass lines and Floor & Sub. Tap one to play it on deck \(deck), synced to the other deck.")
      ForEach(groups(model.td3Loops), id: \.first!.group) { g in
        let first = g[0]
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(first.group) · \(first.name)").font(.system(size: 14)).lineLimit(2)
            Text(String(format: "%.0f BPM", first.bpm)).font(.system(size: 11, design: .monospaced))
              .foregroundStyle(DJTheme.dim)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          ForEach(g, id: \.id) { l in
            LoopPad(label: l.id, lit: on == l.id) { model.loadTd3(deck, l.id) }
              .accessibilityLabel("Loop \(l.id), \(l.name), on deck \(deck)")
          }
        }
      }
    }
  }
}

/// A loop group as two decks: its A on deck A and its B on deck B (in an acid group B answers A:
/// the same first half, a new second), locked on the bar. Ride the crossfader between them.
struct Td3PairCard: View {
  let model: RustDJModel

  var body: some View {
    let a = model.decks["A"]?.deck?.td3
    let b = model.decks["B"]?.deck?.td3
    let gs = groups(model.td3Loops)
    Card("Loops A / B", trailing: { DrumsSwitch(model: model) }) {
      Caption("Pick a group: its A pattern goes on deck A, its B on deck B, on the bar. The crossfader swaps the answer in.")
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(gs, id: \.first!.group) { g in
          let f = g[0]
          LoopPad(
            label: "\(f.group) \(f.name)", sub: String(format: "%.0f BPM", f.bpm),
            lit: a == "\(f.group)A" && b == "\(f.group)B"
          ) { model.loadTd3Pair(f.group) }
          .accessibilityLabel("Loop group \(f.group), \(f.name), A on deck A and B on deck B")
        }
      }
      if let g = gs.first(where: { g in g.contains { $0.id == a || $0.id == b } }) {
        Caption(g[0].description)
      }
    }
  }
}
