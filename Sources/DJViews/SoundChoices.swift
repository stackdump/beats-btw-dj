import DJCore
import SwiftUI

/// The Instruments panel's whole-track sound choices: the drum kit (beats' synth kit or a
/// sampled kit installed on this Mac, `DrumKits`). Each is a poke (`DeckAction.setKit`) that
/// swaps at the next bar on the same song, and a `tracks` override, so it stars and shares.
struct SoundChoices: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  var body: some View {
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
}

extension AppModel {
  /// The kits installed on this Mac (scanned once).
  var drumKits: [DrumKit] { DrumKits.installed }

  /// Play deck `deck`'s drums on `kit` (nil = the synth kit), at the next bar (recorded).
  func setKit(_ deck: String, _ kit: String?) {
    engine?.perform(.setKit(deck: deck, kit: kit))
    decks[deck]?.kit = engine?[deck]?.kit
  }
}
