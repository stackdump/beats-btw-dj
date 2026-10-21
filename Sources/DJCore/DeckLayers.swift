import Foundation

// A deck's layer list (`Deck.layerEntries`): where it comes from at load and the key the track is
// in. The moves that change it are Wander's (`WanderAction.layers`); the app plays it (`LayerRunner`).

extension Deck {
  /// A new track is on the deck: its layer list is its own `loopLayers` (a raw share's), else empty.
  /// A composed deck's Wander swaps do not come through here, so layers it has brought in carry over
  /// its seed changes.
  func resetLayers(from source: DeckSourceDescriptor) {
    layerEpoch += 1
    switch source {
    case .rawNets(let payload):
      let specs = (try? LoopLayers.parse(payload[LoopLayers.envelopeKey])) ?? []
      layerEntries = LoopLayers.entries(from: specs)
      layerKeyName = payload["djKey"]?.string
    case .net, .none, .sample:
      layerEntries = []
      layerKeyName = nil
    }
  }

  /// The key to pick layers in: the track's own (`djKey`), else a composed deck's genre scale and
  /// root, else unknown.
  public var layerKey: String? {
    if let k = layerKeyName { return k }
    guard let k = wanderKey else { return nil }
    let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    let minor = ["minor", "dorian", "phrygian", "aeolian", "blues"].contains {
      k.scale.lowercased().contains($0)
    }
    return names[((k.rootPC % 12) + 12) % 12] + (minor ? " minor" : " major")
  }

  /// Replace the layer list (a Wander move).
  func setLayers(_ entries: [LayerEntry]) { layerEntries = entries }
}
