import Foundation

// A net deck's drum kit (`DrumKits`): beats' synth kit by default, or a sampled kit the user
// picked. The poke is `DeckAction.setKit`; the configuration it lands on is the share's
// `tracks` override (`kit` on every drum channel), so it records, stars and shares; the
// boundary is the next bar — the same song at the same place, only the drums' voice changes.

extension DeckSourceDescriptor {
  /// This net with `field` set to `value` (nil or "" clears it) in the `tracks` override of
  /// each of `channels`, merged into any entries already there. nil for a source that isn't a
  /// net.
  public func withTrackField(_ field: String, _ value: String?, channels: [Int])
    -> DeckSourceDescriptor?
  {
    func merged(_ tracks: JSONValue?) -> JSONValue {
      var all = tracks?.object ?? JSONObject()
      for channel in channels {
        var entry = all["\(channel)"]?.object ?? JSONObject()
        if let value, !value.isEmpty {
          entry[field] = .string(value)
        } else {
          entry[field] = nil
        }
        all["\(channel)"] = entry.entries.isEmpty ? nil : .object(entry)
      }
      return .object(all)
    }
    func set(_ o: inout JSONObject) {
      let t = merged(o["tracks"])
      o["tracks"] = (t.object?.entries.isEmpty ?? true) ? nil : t
    }
    switch self {
    case .net(var spec):
      set(&spec.layers)
      return .net(spec)
    case .rawNets(let payload):
      guard var o = payload.object else { return nil }
      set(&o)
      return .rawNets(payload: .object(o))
    case .none, .sample:
      return nil
    }
  }

  /// This net's drums playing `kit` (a `DrumKit.id`; nil = beats' synth kit).
  public func withKit(_ kit: String?, channels: [Int]) -> DeckSourceDescriptor? {
    withTrackField("kit", kit, channels: channels)
  }
}

extension Project {
  /// The channels of the project's drum nets (kick, snare, hats, clap), in order.
  public var drumChannels: [Int] {
    var out: [Int] = []
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control", isDrumChannel(nb.track.channel),
        !out.contains(nb.track.channel)
      else { continue }
      out.append(nb.track.channel)
    }
    return out.sorted()
  }

  /// The kit the drums play (`Track.kit` of the first drum net), nil = the synth kit.
  public var drumKit: String? {
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control", isDrumChannel(nb.track.channel) else {
        continue
      }
      return nb.track.kit
    }
    return nil
  }

  /// Every drum net playing `kit` (what the `tracks` override does when the share loads).
  mutating func setDrumKit(_ kit: String?) {
    for id in nets.keys {
      guard var nb = nets[id], isDrumChannel(nb.track.channel) else { continue }
      nb.track.kit = kit
      nets[id] = nb
    }
  }
}

extension Deck {
  /// The kit the deck's drums play (`DrumKit.id`), nil for beats' synth kit or a sample deck.
  public var kit: String? { mode == .net ? netProject?.drumKit : nil }

  /// The first tick of the next bar's hand-over (`WaveRunner` swaps a queued project in when
  /// `(tick + 1) % 16 == 0`): a project prepared from here carries on where the playing one
  /// would have been.
  var nextSwapTick: Int {
    let t = max(0, wave.tick)
    return t + (15 - t % 16)
  }

  /// Play the drums on `kit` (`DeckAction.setKit`; nil = the synth kit): the song keeps its
  /// place and swaps at the next bar, its source gains the `tracks` override so a favorite or
  /// share keeps the kit. A kit not installed here plays the synth kit.
  public func setKit(_ kit: String?) {
    guard mode == .net, var project = netProject else { return }
    let kit = kit.flatMap { $0.isEmpty ? nil : $0 }
    guard project.drumKit != kit else { return }
    let channels = project.drumChannels
    guard !channels.isEmpty else { return }
    project.setDrumKit(kit)
    retarget(project) { $0.withKit(kit, channels: channels) }
  }

  /// Replace the deck's project with `project` (the same song with other sound choices) and
  /// its source with `edit(source)`, then rebuild at the next bar from where it plays.
  func retarget(_ project: Project, _ edit: (DeckSourceDescriptor) -> DeckSourceDescriptor?) {
    if let next = netSource.flatMap(edit) {
      switch next {
      case .net(let spec): currentSpec = spec
      case .rawNets(let payload): currentRawNets = payload
      case .none, .sample: break
      }
    }
    netProject = project
    relocate(toTick: wave.isPlaying ? nextSwapTick : wave.tick)
  }
}

// MARK: - the sound palette

// A whole-track palette (`SoundPalette`): the poke is `DeckAction.setPalette`, the
// configuration the `tracks` override `palette` on every channel (each role's category from
// the palette, seeded by the track seed + role as voicing is; picked instruments and a picked
// kit keep theirs), the boundary the next bar, on the same song.

extension DeckSourceDescriptor {
  /// This net with every one of `channels` playing from `palette` (nil = none).
  public func withPalette(_ palette: String?, channels: [Int]) -> DeckSourceDescriptor? {
    withTrackField("palette", palette, channels: channels)
  }
}

extension Project {
  /// The channels of every net that plays (not control nets), in order.
  public var channels: [Int] {
    var out: Set<Int> = []
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control" else { continue }
      out.insert(nb.track.channel)
    }
    return out.sorted()
  }

  /// The palette the track plays from (the first playing net's), nil = none.
  public var palette: String? {
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control" else { continue }
      return nb.track.palette
    }
    return nil
  }

  mutating func setPalette(_ palette: String?) {
    for id in nets.keys {
      guard var nb = nets[id] else { continue }
      nb.track.palette = palette
      nets[id] = nb
    }
  }
}

extension Deck {
  /// The palette the deck's track plays from, as recorded (`minecraft@32`), or nil.
  public var palette: String? { mode == .net ? netProject?.palette : nil }

  /// Play the track from `palette` (`DeckAction.setPalette`; nil = none): the same song from
  /// the next bar. A palette not playable here (its bank not imported) leaves every role as it
  /// was voiced. The id is recorded with the asset version it plays here (`recorded`) when it
  /// comes without one.
  ///
  /// Wander's "palette" lock (`WanderLock.dimensions`, `Wander.carry`) takes the palette and
  /// the kit into every new track the walk swaps in; without it a swap starts from the new
  /// track's own instruments, as it drops instrument picks.
  public func setPalette(_ palette: String?) {
    guard mode == .net, var project = netProject else { return }
    var id = palette.flatMap { $0.isEmpty ? nil : $0 }
    if let p = id, SoundPalette.version(p) == nil, let known = SoundPalette.named(p) {
      id = known.recorded()
    }
    guard project.palette != id else { return }
    let channels = project.channels
    guard !channels.isEmpty else { return }
    project.setPalette(id)
    retarget(project) { $0.withPalette(id, channels: channels) }
  }
}
