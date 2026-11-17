import DJRust
import SwiftUI

// The Perform page (djandroid ui/PerformPage.kt): the classic DJ moves on the bar / phrase grid
// (djrust's `djhost::perform`, the desktop's Perform window). One pad per move arms it, or
// cancels it while it is armed or running; its deck and bars sit under it, its light beside its
// name and one caption line says what it is doing. The keys of both decks (read-only) head the
// transitions. Everything on it is played; nothing here is a utility (DESIGN §1).
//
// On an iPad the two cards sit side by side (transitions left, exits right) once the page is
// wide enough for two thumb-sized columns; narrower, they stack as on the phone.

struct PerformPage: View {
  let model: RustDJModel
  /// The width at which the two cards go side by side.
  static let twoColumnsFrom: CGFloat = 860

  var body: some View {
    let p = model.perform
    VStack(alignment: .leading, spacing: 16) {
      if p.catalog.isEmpty {
        Caption("the moves are not ready yet")
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 16) {
          transitions.frame(minWidth: Self.twoColumnsFrom / 2 - 8)
          exits.frame(minWidth: Self.twoColumnsFrom / 2 - 8)
        }
        VStack(spacing: 16) {
          transitions
          exits
        }
      }
      Spacer(minLength: 24)
    }
  }

  private var transitions: some View {
    Card("Transitions", trailing: { HarmonicHintView(hint: model.perform.state?.harmonic) }) {
      rows(PerformRules.transitions)
    }
  }

  private var exits: some View {
    Card(
      "Exits",
      trailing: {
        // always laid out, so the header keeps its height; it only lets go of what is in flight
        Button("Cancel all") { model.cancelAllMoves() }
          .font(.system(size: 14)).frame(minHeight: 48).disabled(!model.perform.busy)
      }
    ) {
      rows(PerformRules.exits)
    }
  }

  @ViewBuilder private func rows(_ kinds: [String]) -> some View {
    ForEach(kinds, id: \.self) { k in
      if let m = model.perform.catalog.first(where: { $0.kind == k }) { MoveRowView(model: model, move: m) }
    }
  }
}

/// Both decks' keys and whether they mix: state, read-only.
private struct HarmonicHintView: View {
  let hint: HarmonicHint?

  var body: some View {
    HStack(spacing: 8) {
      Text(hint.map(PerformRules.hintKeys) ?? "A ? · B ?").font(.system(size: 12)).foregroundStyle(DJTheme.dim)
      Text(hint.map(PerformRules.hintWords) ?? "keys unknown").font(.system(size: 12, weight: .medium))
        .foregroundStyle(hint?.mixes == true ? DJTheme.running : hint?.mixes == false ? DJTheme.danger : DJTheme.dim)
    }
    .lineLimit(1)
    .frame(minHeight: 48)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hint.map { "\(PerformRules.hintKeys($0)), \(PerformRules.hintWords($0))" } ?? "keys unknown")
  }
}

/// One move: its pad (with the light), its deck and bars, and its caption.
private struct MoveRowView: View {
  let model: RustDJModel
  let move: MoveInfo

  var body: some View {
    let m = move
    let row = model.moveRow(m)
    let flight = PerformRules.flight(model.perform.state?.active ?? [], m.kind, m.oneAtATime, row.deck)
    let note = model.perform.notes[m.kind]
    let last = PerformRules.lastWord(model.perform.state?.last ?? [], m.kind, m.oneAtATime, row.deck)
    VStack(alignment: .leading, spacing: 6) {
      MovePad(label: m.label, phase: PerformRules.light(flight)) { model.toggleMove(m) }
      // the deck and the bars: one line when it fits, the bars under the deck otherwise
      FlowLayout(spacing: 16) {
        HStack(spacing: 6) {
          Caption(m.deckWord)
          ForEach(deckNames, id: \.self) { d in
            Chip(label: d, selected: row.deck == d) { model.setMoveRow(m) { $0.deck = d } }
          }
        }
        HStack(spacing: 6) {
          Caption(PerformRules.barsWord(m))
          ForEach(m.barChoices.map { Int($0) }, id: \.self) { n in
            Chip(label: "\(n)", selected: row.bars == n) { model.setMoveRow(m) { $0.bars = n } }
          }
        }
      }
      if m.hasAction {
        HStack(spacing: 6) {
          Caption("on the line")
          Chip(label: "next seed", selected: row.action == "seed") { model.setMoveRow(m) { $0.action = "seed" } }
          Chip(label: "cut to it", selected: row.action == "cut") { model.setMoveRow(m) { $0.action = "cut" } }
        }
      }
      // one line, always laid out: the row keeps its height whatever the move is doing
      Text(PerformRules.caption(flight, note, last).isEmpty ? " " : PerformRules.caption(flight, note, last))
        .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
        .foregroundStyle(flight == nil && note != nil ? DJTheme.danger : DJTheme.dim)
    }
  }
}

/// A thumb pad: 56 pt, its light at the left, lit while the move is in flight (tap again cancels).
private struct MovePad: View {
  let label: String
  /// "armed", "running" or nil.
  let phase: String?
  let onTap: () -> Void

  var body: some View {
    let inFlight = phase != nil
    Button(action: onTap) {
      HStack(spacing: 12) {
        Circle().fill(phase == "armed" ? DJTheme.armed : phase == "running" ? DJTheme.running : DJTheme.lightOff)
          .frame(width: 12, height: 12)
        Text(label).font(.system(size: 16, weight: .medium)).foregroundStyle(inFlight ? DJTheme.accent : Color.white)
        Spacer()
        Caption(inFlight ? "tap to cancel" : "")
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 56)
      .background(inFlight ? DJTheme.surface2 : DJTheme.surface0, in: RoundedRectangle(cornerRadius: 14))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(phase ?? "off")
  }
}
