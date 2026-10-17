import DJCore
import SwiftUI

/// The Instruments panel's whole-track sound choices: the palette (`SoundPalette`: every
/// role's category from one bank, e.g. Minecraft; greyed out with its reason when it can't play
/// here) and the drum kit (beats' synth kit or a sampled kit installed on this Mac,
/// `DrumKits`). Each is a poke (`DeckAction.setPalette` / `setKit`) that swaps at the next bar
/// on the same song, and a `tracks` override, so it stars and shares.
struct SoundChoices: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  var body: some View {
    if state.isNet {
      VStack(alignment: .leading, spacing: 3) {
        Text("palette").font(.caption2).foregroundStyle(.secondary)
        FlowRow(spacing: 4) {
          ChoiceButton(label: "instruments", selected: state.palette == nil, tint: tint) {
            model.setPalette(name, nil)
          }
          .help("each role's own instrument category")
          ForEach(SoundPalette.all) { p in
            palette(p)
          }
        }
      }
    }
    if state.isNet
      && state.roles.contains(where: { ["kick", "snare", "hihat", "clap"].contains($0) })
    {
      VStack(alignment: .leading, spacing: 3) {
        Text("drum kit").font(.caption2).foregroundStyle(.secondary)
        FlowRow(spacing: 4) {
          ChoiceButton(label: "synth", selected: state.kit == nil, tint: tint) {
            model.setKit(name, nil)
          }
          .help("beats' own synth kit")
          ForEach(model.drumKits) { k in
            ChoiceButton(label: k.label, selected: state.kit == k.id, tint: tint) {
              model.setKit(name, k.id)
            }
            .help("\(k.name) from \(k.bank): played from this Mac, swaps at the next bar")
          }
        }
      }
    }
  }

  private func palette(_ p: SoundPalette) -> some View {
    let why = AppModel.paletteUnavailable[p.id] ?? nil
    let local = p.isLocalOnly ? "; local only, never published" : ""
    return ChoiceButton(
      label: p.label, selected: SoundPalette.named(state.palette)?.id == p.id, tint: tint
    ) {
      model.setPalette(name, p.id)
    }
    .disabled(why != nil)
    .help(
      why.map { "\(p.label) can't play here: \($0)" }
        ?? "every role from the \(p.label) palette (picked instruments keep theirs), at the next bar\(local)"
    )
  }
}

extension AppModel {
  /// The kits installed on this Mac (scanned once).
  var drumKits: [DrumKit] { DrumKits.installed }

  /// Why each palette can't play here (nil: it can), looked at once per launch.
  static let paletteUnavailable: [String: String?] = Dictionary(
    uniqueKeysWithValues: SoundPalette.all.map { ($0.id, $0.unavailableReason()) })

  /// Play deck `deck`'s drums on `kit` (nil = the synth kit), at the next bar (recorded).
  func setKit(_ deck: String, _ kit: String?) {
    engine?.perform(.setKit(deck: deck, kit: kit))
    decks[deck]?.kit = engine?[deck]?.kit
  }

  /// Play deck `deck`'s track from `palette` (nil = none), at the next bar (recorded).
  func setPalette(_ deck: String, _ palette: String?) {
    engine?.perform(.setPalette(deck: deck, palette: palette))
    decks[deck]?.palette = engine?[deck]?.palette
  }
}
