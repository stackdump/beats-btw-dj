import Foundation

/// One role of a net deck as an instrument choice: the beats instrument its nets play (which
/// picks the synth voice and, through its category, the sampled sound), and the instruments
/// beats' generator would pick from for that role — this genre's first.
public struct RoleVoice: Equatable, Sendable {
  /// The role, or roles sharing the channel joined by " · " (`kick · snare · hihat`).
  public var role: String
  /// The MIDI channel the role's nets share: the key of the share envelope's `tracks` override.
  public var channel: Int
  public var instrument: String
  public var options: [String]
}

extension Deck {
  /// The deck's roles with an instrument to choose, in the deck's role order. Empty for a
  /// sample deck, and for roles beats has no instrument pool for.
  public var roleVoices: [RoleVoice] {
    guard mode == .net, let project = netProject else { return [] }
    let genre = currentSpec?.genre ?? ""
    let sets = BeatsTables.shared.instrumentSets
    var out: [RoleVoice] = []
    for role in roles {
      // A role is a riff group (`bass-0`, `bass-1`… share one channel) or a lone net's id.
      guard
        let net = project.nets.keys.lazy
          .compactMap({ id in project.nets[id].map { (id, $0) } })
          .first(where: { $0.1.role != "control" && ($0.1.riffGroup == role || $0.0 == role) })?.1
      else { continue }
      var options = sets[genre]?[role] ?? []
      for id in sets.keys.sorted() where id != genre {
        for i in sets[id]?[role] ?? [] where !options.contains(i) { options.append(i) }
      }
      guard !options.isEmpty else { continue }
      // Roles on one channel (the drum kit) are one choice: `tracks` is keyed by channel.
      if let i = out.firstIndex(where: { $0.channel == net.track.channel }) {
        out[i].role += " · " + role
        continue
      }
      if !options.contains(net.track.instrument) { options.insert(net.track.instrument, at: 0) }
      out.append(
        RoleVoice(
          role: role, channel: net.track.channel, instrument: net.track.instrument,
          options: options))
    }
    return out
  }
}

extension DeckSourceDescriptor {
  /// This net with the nets on `channel` playing `instrument`: the share envelope's `tracks`
  /// override (`{"<channel>": {"instrument": …}}`, merged into any already there), so the
  /// change records in a session, survives a favorite and goes out in a share link. nil for a
  /// source that isn't a net.
  public func withInstrument(_ instrument: String, channel: Int) -> DeckSourceDescriptor? {
    func merged(_ tracks: JSONValue?) -> JSONValue {
      var all = tracks?.object ?? JSONObject()
      var entry = all["\(channel)"]?.object ?? JSONObject()
      entry["instrument"] = .string(instrument)
      all["\(channel)"] = .object(entry)
      return .object(all)
    }
    switch self {
    case .net(var spec):
      spec.layers["tracks"] = merged(spec.layers["tracks"])
      return .net(spec)
    case .rawNets(let payload):
      guard var o = payload.object else { return nil }
      o["tracks"] = merged(o["tracks"])
      return .rawNets(payload: .object(o))
    case .none, .sample:
      return nil
    }
  }
}
