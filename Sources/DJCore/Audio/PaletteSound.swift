import Foundation

// A track's sound choices (`SoundPalette`) as configuration. The three things a feature names:
// 1. the pokes: `DeckAction.setPalette` (the whole track), `DeckAction.setRoleVoice` (one role's
//    option, "fine-tune"; nil = back to the palette), `DeckAction.setKit` (any installed kit);
// 2. the rule: each role plays the palette's option picked by the track seed + role, unless the
//    user overrode it (`Project.applySound`); the deck carries its palette, kit and overrides
//    into every new track it makes (`TrackSpec.carryingSound`: Next, auto-next, the seed wheel,
//    Wander), so they survive every recompute until cleared;
// 3. the boundary: the next bar, on the same song (`Deck.retarget`); a new track at its swap.

/// What a net plays, as its palette and the user's choices resolve it (`Project.applySound`).
/// dj-only: never encoded, so a project's canonical text and CID stay beats'.
public struct TrackSound: Sendable, Equatable {
  /// The user's own option for this net's role (the `tracks` override `voice`), nil = the
  /// palette's pick.
  public var override: String?
  /// The option it plays (`SoundPalette` grammar: `own`, `synth`, `synth:<name>`, `cat:…`,
  /// `gm:<n>`, `dls:<n>`, `bank:…`, `inst:<name>`; for the drums a kit option), nil = no
  /// palette: its instrument's own sound.
  public var option: String?
  /// A drum net's kit from the palette (`DrumKit.id`, "synth" = a synth kit), nil = none.
  public var kit: String?
  /// The composer's instrument, kept when a pick or a palette's synth voice replaced it.
  public var composed: String?

  public init() {}
}

extension Project {
  /// The role a net's sound is chosen as (`pool`: the palette's role, `key`: what its pick is
  /// seeded with): the drums share one kit, a tonal net is its group (bass, melody, harmony,
  /// arp, stinger) seeded by its riff group or id (each stinger hit its own).
  static func soundRole(_ id: String, _ nb: NetBundle) -> (pool: String, key: String) {
    if isDrumChannel(nb.track.channel) { return ("kit", "kit") }
    let r = nb.riffGroup.isEmpty ? id : nb.riffGroup
    return (nb.track.group ?? r, r)
  }

  /// Resolve every net's sound from its palette (`Track.palette`) and the user's choices, as
  /// a pure function of the project's overrides, the track seed and what is installed: run
  /// after the share's overrides (`TrackSpec.finish`) and again after any sound poke (the
  /// same project, its choices changed). Idempotent: a palette's synth voice replaces the
  /// instrument only until the next resolve.
  public mutating func applySound(seed: Double, dir: String = SamplerSource.soundFontDir) {
    for id in nets.keys {
      guard var nb = nets[id], nb.role != "control" else { continue }
      let (pool, key) = Self.soundRole(id, nb)
      var t = nb.track
      let palette = SoundPalette.named(t.palette)
      // the user's pick of an instrument (`inst:` or a `tracks` instrument) plays as picked
      if let o = t.sound.override, let name = SoundPalette.pickedName(o), pool != "kit" {
        if t.sound.composed == nil { t.sound.composed = t.instrument }
        t.instrument = name
        t.picked = true
        t.sound.option = o
        t.sound.kit = nil
      } else if t.picked && pool != "kit" {
        t.sound.option = nil
        t.sound.kit = nil
      } else {
        if let c = t.sound.composed, !t.picked { t.instrument = c }
        let opt = t.sound.override ?? palette?.pick(role: pool, key: key, seed: seed, dir: dir)
        t.sound.option = opt
        t.sound.kit = nil
        if let opt, let name = SoundPalette.synthName(opt), !t.picked {
          // a synth voice (or synth kit) of another name: the lane voices that instrument
          if t.sound.composed == nil { t.sound.composed = t.instrument }
          t.instrument = name
        }
        if pool == "kit", let opt { t.sound.kit = SoundPalette.kitID(option: opt) }
      }
      nb.track = t
      nets[id] = nb
    }
  }

  /// The channels whose nets play as `role` (a palette role: kit, bass, melody, …).
  public func channels(soundRole role: String) -> [Int] {
    var out: Set<Int> = []
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control", Self.soundRole(id, nb).pool == role else {
        continue
      }
      out.insert(nb.track.channel)
    }
    return out.sorted()
  }

  /// The palette roles the project plays, in the chooser's order.
  public var soundRoles: [String] {
    var have: Set<String> = []
    for id in nets.keys {
      guard let nb = nets[id], nb.role != "control" else { continue }
      have.insert(Self.soundRole(id, nb).pool)
    }
    return SoundPalette.roleOrder.filter(have.contains)
  }

  /// The first net that plays as `role`, sorted by id (the one the panel shows).
  public func soundNet(_ role: String) -> NetBundle? {
    nets.keys.sorted().lazy.compactMap { id in self.nets[id].map { (id, $0) } }
      .first { $0.1.role != "control" && Self.soundRole($0.0, $0.1).pool == role }?.1
  }
}

extension WaveOptions {
  /// These options with the room and echo the palette plays in (`SoundPalette.room` / `.echo`,
  /// another genre's), else `genre`'s, for the fixes they hold.
  public func forPalette(_ palette: String?, genre: String) -> WaveOptions {
    var o = self
    let p = SoundPalette.named(palette)
    if musicality.contains(.space) { o.space = SpaceSpec.forGenre(p?.room ?? genre) }
    if musicality.contains(.echo) {
      let e = p?.echo ?? genre
      o.echo = e == "none" ? nil : EchoSpec.forGenre(e)
    }
    return o
  }
}

extension TrackSpec {
  /// The `tracks` override fields that are the deck's sound choices, not the song's.
  public static let soundFields = ["palette", "kit", "voice"]

  /// This spec with `other`'s sound choices — its palette, kit pick and role overrides — on
  /// the same channels (beats gives every role the same channel in every genre), merged into
  /// any override this spec has. What the deck carries into a new track.
  public func carryingSound(from other: TrackSpec) -> TrackSpec {
    guard let tracks = other.layers["tracks"]?.object else { return self }
    var s = self
    var all = s.layers["tracks"]?.object ?? JSONObject()
    for (ch, o) in tracks.entries {
      var entry = all[ch]?.object ?? JSONObject()
      var changed = false
      for f in Self.soundFields {
        if let v = o[f] {
          entry[f] = v
          changed = true
        }
      }
      if changed { all[ch] = .object(entry) }
    }
    if !all.entries.isEmpty { s.layers["tracks"] = .object(all) }
    return s
  }

  /// The palette the spec names (on any channel), as recorded, or nil.
  public var palette: String? {
    for (_, o) in layers["tracks"]?.object?.entries ?? [] {
      if let p = o["palette"]?.string, !p.isEmpty { return p }
    }
    return nil
  }

  /// This spec playing from `palette` (nil or the default = none) on every role's channel
  /// (beats' channels: the same in every genre).
  public func withPalette(_ palette: String?) -> TrackSpec {
    let id = SoundPalette.normalized(palette)
    guard
      case .net(let s)? = DeckSourceDescriptor.net(self).withPalette(
        id, channels: Self.soundChannels(genre: genre))
    else { return self }
    return s
  }

  /// Every channel beats puts a playing role on in `genre` (the melody's and bass's from the
  /// genre, the rest fixed): where a palette is written for a track not composed yet.
  public static func soundChannels(genre: String) -> [Int] {
    let g = BeatsTables.shared.genres[genre]
    let fixed = [5, 7, 10, 11, 12, 13] + BeatsTables.shared.stingerSpecs.map(\.channel)
    return Array(Set(fixed + [g?.melodyChannel ?? 4, g?.bassChannel ?? 6])).sorted()
  }
}

/// One role of a net deck's track as the palette chooser's fine-tune area shows it: what it
/// plays, whether the user overrode it, and the options to choose from.
public struct RoleSoundRow: Equatable, Sendable, Identifiable {
  /// The palette role: kit, bass, melody, harmony, arp, stinger.
  public var role: String
  public var channels: [Int]
  /// What it plays now, as a name ("Feedback Rhodes", "pwm-lead", "TR-808 · MuseScore_General").
  public var playing: String
  /// The option it plays (nil: its instrument's own sound, no palette choice).
  public var option: String?
  /// The user's override (`DeckAction.setRoleVoice`), or nil.
  public var override: String?
  /// An instrument the user picked for it the older way (a `tracks` instrument), or nil.
  public var picked: String?
  /// A kit the user picked (`DeckAction.setKit`), for the drums.
  public var kitPick: String?
  public var choices: [RoleSoundChoice]

  public var id: String { role }
  /// The user chose this role's sound: "reset to palette" undoes it.
  public var isOverridden: Bool { override != nil || picked != nil || kitPick != nil }

  /// As `dj_state` / `dj_palettes` show it.
  public var json: JSONValue {
    var o = JSONObject([
      ("role", .string(role)), ("channels", .array(channels.map { .int($0) })),
      ("plays", .string(playing)), ("overridden", .bool(isOverridden)),
    ])
    if let option { o["option"] = .string(option) }
    if let override { o["override"] = .string(override) }
    if let picked { o["picked"] = .string(picked) }
    if let kitPick { o["kit"] = .string(kitPick) }
    o["options"] = .array(
      choices.map { c in
        var e = JSONObject([("option", .string(c.option)), ("label", .string(c.label))])
        if let u = c.unavailable { e["unavailable"] = .string(u) }
        return .object(e)
      })
    return .object(o)
  }
}

/// One option a role can be set to.
public struct RoleSoundChoice: Equatable, Sendable, Identifiable {
  public var option: String
  public var label: String
  /// Why it can't play here, nil when it can.
  public var unavailable: String?
  public var selected: Bool
  public var id: String { option }
}

/// One palette as the chooser shows it.
public struct PaletteCard: Equatable, Sendable, Identifiable {
  public var id: String
  public var label: String
  public var icon: String
  public var color: String
  public var description: String
  /// Why it can't play here (the card greys out), nil when it can.
  public var unavailable: String?
  public var localOnly: Bool
  public var selected: Bool

  /// Every shipped palette, `current` (a track's recorded palette, nil = the default) lit.
  public static func cards(
    current: String?, unavailable: [String: String?] = PaletteCard.unavailableHere
  ) -> [PaletteCard] {
    let here = SoundPalette.playing(current)?.id
    return SoundPalette.all.map { p in
      PaletteCard(
        id: p.id, label: p.label, icon: p.icon, color: p.color, description: p.description,
        unavailable: unavailable[p.id] ?? nil, localOnly: p.isLocalOnly, selected: p.id == here)
    }
  }

  /// Why each palette can't play here, looked at once per launch.
  public static let unavailableHere: [String: String?] = Dictionary(
    uniqueKeysWithValues: SoundPalette.all.map { ($0.id, $0.unavailableReason()) })
}

extension Deck {
  /// The palette the deck's track plays (its own, else the default), nil for a sample deck.
  public var playingPalette: SoundPalette? {
    mode == .net ? SoundPalette.playing(netProject?.palette) : nil
  }

  /// Every palette role the track plays, for the fine-tune area (empty for a sample deck).
  public var roleSounds: [RoleSoundRow] {
    guard mode == .net, let project = netProject, let palette = playingPalette else { return [] }
    let seed = voicingSeed
    return project.soundRoles.compactMap { role in
      guard let nb = project.soundNet(role) else { return nil }
      let t = nb.track
      let own = role == "kit" ? "synth" : "own"
      var options = palette.pool(role) ?? []
      var extras = [own, "synth"]
      if role == "kit" { extras = ["synth"] + synthDrumKits.map { "synth:\($0)" } }
      for extra in extras where !options.contains(extra) { options.append(extra) }
      if let o = t.sound.override, !options.contains(o) { options.append(o) }
      let current = t.sound.option ?? own
      let legacyPick = t.picked && t.sound.override.flatMap(SoundPalette.pickedName) == nil
      let playing: String
      if role == "kit", let k = t.kit {
        playing = SoundPalette.label(option: k, role: "kit")
      } else if legacyPick {
        playing = t.instrument
      } else if current == "own" {
        playing = role == "kit" ? "\(t.instrument) synth kit" : t.instrument
      } else {
        playing = SoundPalette.label(option: current, role: role, seed: seed)
      }
      return RoleSoundRow(
        role: role, channels: project.channels(soundRole: role), playing: playing,
        option: t.sound.option, override: t.sound.override,
        picked: legacyPick ? t.instrument : nil, kitPick: role == "kit" ? t.kit : nil,
        choices: options.map { o in
          RoleSoundChoice(
            option: o, label: SoundPalette.label(option: o, role: role, seed: seed),
            unavailable: SoundPalette.unavailableReason(option: o, role: role),
            selected: !legacyPick && (role != "kit" || t.kit == nil) && o == current)
        })
    }
  }

  /// Play `role` with `voice` (`DeckAction.setRoleVoice`; nil = back to the palette's pick):
  /// the same song from the next bar, the choice in the source's `tracks` override (`voice` on
  /// the role's channels) so it records, stars and shares, and carried into every new track
  /// until cleared. Clearing also drops an instrument (or, for the drums, a kit) the user
  /// picked for the role the older way: "reset to palette".
  public func setRoleVoice(_ role: String, _ voice: String?) {
    guard mode == .net, var project = netProject else { return }
    let voice = voice.flatMap { $0.isEmpty ? nil : $0 }
    let channels = project.channels(soundRole: role)
    guard !channels.isEmpty else { return }
    var changed = false
    for id in project.nets.keys {
      guard var nb = project.nets[id], nb.role != "control", channels.contains(nb.track.channel)
      else { continue }
      if nb.track.sound.override != voice { changed = true }
      nb.track.sound.override = voice
      if nb.track.picked {
        nb.track.picked = false
        if let c = nb.track.sound.composed { nb.track.instrument = c }
        changed = true
      }
      if role == "kit", voice == nil, nb.track.kit != nil {
        nb.track.kit = nil
        changed = true
      }
      project.nets[id] = nb
    }
    guard changed else { return }
    project.applySound(seed: voicingSeed)
    retarget(project) { d in
      var x = d.withTrackField("voice", voice, channels: channels)
      x = x?.withTrackField("instrument", nil, channels: channels)
      if role == "kit", voice == nil { x = x?.withTrackField("kit", nil, channels: channels) }
      return x
    }
  }
}
