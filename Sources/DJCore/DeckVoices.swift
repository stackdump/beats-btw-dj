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
    return RoleVoice.list(project: project, roles: roles, genre: currentSpec?.genre ?? "")
  }

  /// What a role beats has no instrument list for can play: harmony the sustained families
  /// (pads first, then strings, keys, organ, choir, bells); any other, every tonal instrument.
  static func fallbackOptions(_ role: String) -> [String] {
    let catalog = VoiceCatalog.shared
    let harmony = [
      "pad", "strings", "keys.epiano", "keys.piano", "keys.organ", "vocal", "synth.bell",
    ]
    let categories =
      role == "harmony"
      ? harmony : Array(Set(catalog.categoryOf.values)).sorted().filter { !$0.hasPrefix("bass") }
    return categories.flatMap { c in catalog.categoryOf.filter { $0.value == c }.keys.sorted() }
  }
}

extension RoleVoice {
  /// `project`'s `roles` (in that order) with an instrument to choose, for a net of `genre`:
  /// what `Deck.roleVoices` shows for the deck playing it, and `ClipRetune.voices` for a loop.
  public static func list(project: Project, roles: [String], genre: String) -> [RoleVoice] {
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
      // beats lists no instruments for some roles (harmony): offer what fits it instead of
      // leaving the role out of the Instruments panel
      if options.isEmpty { options = Deck.fallbackOptions(role) }
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

// MARK: - the sound panel (voice tweaks)

extension Deck {
  /// What channel `channel` plays now (the latest project loaded), for the sound panel.
  public func channelVoice(_ channel: Int) -> ChannelVoice? {
    guard mode == .net else { return nil }
    return wave.latest?.channelVoice(channel)
  }

  /// The channel's voice settings this session (default: the instrument's own voice).
  public func voiceSetting(_ channel: Int) -> VoiceSetting? { wave.voiceSettings[channel] }
  public func voiceTweak(_ channel: Int) -> VoiceTweak {
    wave.voiceSettings[channel]?.tweak ?? VoiceTweak()
  }
  public func usesSynthVoice(_ channel: Int) -> Bool {
    wave.voiceSettings[channel]?.useSynth ?? false
  }

  /// Shape channel `channel`'s voice (`DeckAction.voiceTweak`): live, on the song playing, from
  /// the next block — no reload. An empty tweak is the instrument's own voice (Reset).
  public func setVoiceTweak(_ tweak: VoiceTweak, channel: Int) {
    guard mode == .net else { return }
    wave.setVoice(channel: channel, tweak: tweak, useSynth: usesSynthVoice(channel))
  }

  /// A sampled channel plays its synth voice instead of the sample (`on`), or the sample again
  /// (`DeckAction.voiceSynth`). Live, like a tweak.
  public func setSynthVoice(_ on: Bool, channel: Int) {
    guard mode == .net else { return }
    wave.setVoice(channel: channel, tweak: voiceTweak(channel), useSynth: on)
  }

  /// Does loading `source` keep this deck's voice settings? Only when it is the song playing
  /// with another instrument picked (the same share but for its `tracks` override): the
  /// settings belong to the song, and to the instrument they were made on (a channel whose
  /// instrument changed starts afresh, `WaveDeckSource.load`). A new song, a favorite or the
  /// same song loaded again start from the instruments' own voices.
  func keepsVoiceSettings(loading source: DeckSourceDescriptor) -> Bool {
    guard let now = netSource, now != source else { return false }
    func song(_ d: DeckSourceDescriptor) -> JSONValue? {
      switch d {
      case .net(var spec):
        spec.layers["tracks"] = nil
        return spec.payload
      case .rawNets(let payload):
        guard var o = payload.object else { return nil }
        o["tracks"] = nil
        return .object(o)
      case .none, .sample: return nil
      }
    }
    guard let a = song(now), let b = song(source) else { return false }
    return a.canonicalJS == b.canonicalJS
  }
}
