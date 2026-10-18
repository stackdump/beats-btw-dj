import Foundation

// The checkpoint: everything a replay needs to stand where the app stood — the decks' sources
// and knobs (as a session names them), the mixer, the loop row by clip id, the row's settings,
// the locks, and the persistent stores (favorites, crates, voice variations, notes). Audio is
// never in it: samples are named by content id, clips by id (their audio is in the loop library).

/// A deck at a checkpoint.
public struct DeckCheckpoint: Equatable, Sendable {
  public var source: DeckSourceDescriptor
  public var params: DeckParams
  public var playing: Bool
  /// The deck it follows the tempo of (`Deck.follow`).
  public var leader: String?
  /// The row's clip it holds, when it holds one (`DJEngine.playClip`).
  public var clip: String?
  /// The sound panel's settings per channel (session-only state, but the session is live).
  public var voices: [Int: VoiceSetting]
  /// Where the deck was, when the checkpoint was asked for its playheads
  /// (`JournalState(engine:stores:playheads: true)`): the sample frame on a sample deck, the net
  /// tick on a net deck. Nil (and not written) otherwise: line 0 and older files have none.
  public var position: Double?

  public init(
    source: DeckSourceDescriptor = .none, params: DeckParams = DeckParams(), playing: Bool = false,
    leader: String? = nil, clip: String? = nil, voices: [Int: VoiceSetting] = [:],
    position: Double? = nil
  ) {
    self.position = position
    self.source = source
    self.params = params
    self.playing = playing
    self.leader = leader
    self.clip = clip
    self.voices = voices
  }
}

/// A clip on the row at a checkpoint (its audio is the loop library's, by id).
public struct ClipCheckpoint: Equatable, Sendable {
  public var id: String
  public var title: String
  public var color: String?
  public var gain: Double
  public var muted: Bool
  public var soloed: Bool
  /// Its own key lock; nil follows the row's.
  public var keyLock: Bool?
  /// Looping (or on its way in) under the mixer.
  public var looping: Bool
  /// Its after effects (`LoopClip.fx`).
  public var fx: LoopFX

  public init(
    id: String, title: String, color: String? = nil, gain: Double = 1, muted: Bool = false,
    soloed: Bool = false, keyLock: Bool? = nil, looping: Bool = false, fx: LoopFX = LoopFX()
  ) {
    self.fx = fx
    self.id = id
    self.title = title
    self.color = color
    self.gain = gain
    self.muted = muted
    self.soloed = soloed
    self.keyLock = keyLock
    self.looping = looping
  }
}

/// The persistent stores, as values: what `FavoritesStore`, the crates, `VoiceVariationStore`
/// and `NotesStore` hold. A replay applies the journal's store events to them with the stores'
/// own edit functions, so it ends where the files did.
public struct JournalStoreState: Equatable, Sendable {
  public var favorites: [Favorite]
  public var crates: [String]
  public var variations: [String: [VoiceVariation]]
  public var notes: [TrackNote]

  public init(
    favorites: [Favorite] = [], crates: [String] = [],
    variations: [String: [VoiceVariation]] = [:], notes: [TrackNote] = []
  ) {
    self.favorites = favorites
    self.crates = crates
    self.variations = variations
    self.notes = notes
  }

  /// Apply a store event; false for events that are not about the stores.
  @discardableResult
  public mutating func apply(_ e: JournalEvent) -> Bool {
    switch e {
    case .favoriteAdd(let f): favorites = FavoritesStore.adding(f, to: favorites)
    case .favoriteRemove(let cid): favorites = FavoritesStore.removing(cid: cid, from: favorites)
    case .favoriteTags(let cid, let tags):
      favorites = FavoritesStore.settingTags(cid: cid, tags, in: favorites)
    case .crateAdd(let name): crates = Self.addingCrate(name, to: crates)
    case .crateDelete(let name): crates = crates.filter { $0 != name }
    case .variationSave(let i, let v):
      variations = VoiceVariationStore.saving(v, for: i, in: variations)
    case .variationRename(let i, let n, let to):
      variations = VoiceVariationStore.renaming(n, to: to, for: i, in: variations)
    case .variationDelete(let i, let n):
      variations = VoiceVariationStore.deleting(n, for: i, in: variations)
    case .noteAdd(let n): notes = notes.adding(n)
    case .noteEdit(let id, let text, let at): notes = notes.editing(id, text: text, at: at)
    case .noteDelete(let id): notes = notes.deleting(id)
    case .storesReplace(let all): self = all
    default: return false
    }
    return true
  }

  /// The crates list with `name` made (trimmed; blank or already there changes nothing).
  public static func addingCrate(_ name: String, to crates: [String]) -> [String] {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty || crates.contains(n) ? crates : crates + [n]
  }

  var json: JSONValue {
    .object(
      JSONObject([
        ("favorites", .array(favorites.map(\.json))),
        ("crates", .array(crates.map { .string($0) })),
        (
          "variations",
          .object(
            JSONObject(
              variations.keys.sorted().map { k in (k, .array(variations[k]!.map(\.json))) }))
        ),
        ("notes", .array(notes.map(\.json))),
      ]))
  }

  init(json v: JSONValue?) {
    var vars: [String: [VoiceVariation]] = [:]
    for (k, list) in v?["variations"]?.object?.entries ?? [] {
      let vs = (list.array ?? []).compactMap(VoiceVariation.init(json:))
      if !vs.isEmpty { vars[k] = vs }
    }
    self.init(
      favorites: (v?["favorites"]?.array ?? []).compactMap(Favorite.init(json:)),
      crates: v?["crates"]?.array?.compactMap(\.string) ?? [], variations: vars,
      notes: (v?["notes"]?.array ?? []).compactMap(TrackNote.init(json:)))
  }
}

/// The full rebuildable state at one moment.
public struct JournalState: Equatable, Sendable {
  public static let schema = "dj-vevr-se/state/v1"
  public var sampleRate: Double
  public var decks: [String: DeckCheckpoint]
  /// The loop channel's strip: volume, trim, reverb (in `params`) and mute.
  public var loopChannel: DeckParams
  public var loopMute: Bool
  public var crossfader: Double
  public var master: Double
  /// The row's settings, as the actions that set them (`DJEngine.loopSettings`).
  public var loopSettings: [DeckAction]
  public var clips: [ClipCheckpoint]
  public var scenes: [LoopScene]
  /// Clips taken off the row this run (newest first) with the place each had.
  public var removed: [(id: String, index: Int)]
  /// `DJEngine.lockedActions`, sorted.
  public var locked: [String]
  public var stores: JournalStoreState
  /// Whether `stores` is part of this state. Line 0 always carries them; a mid-file checkpoint
  /// (`Journal.checkpoint`) leaves them out (no `stores` key), and a replay that starts there
  /// folds line 0's stores and the store events before it instead.
  public var hasStores = true

  public static func == (a: Self, b: Self) -> Bool { a.json == b.json }

  public init(
    sampleRate: Double, decks: [String: DeckCheckpoint] = [:],
    loopChannel: DeckParams = DeckParams(),
    loopMute: Bool = false, crossfader: Double = 0.5, master: Double = 0.8,
    loopSettings: [DeckAction] = [], clips: [ClipCheckpoint] = [],
    scenes: [LoopScene] = [], removed: [(id: String, index: Int)] = [], locked: [String] = [],
    stores: JournalStoreState = JournalStoreState()
  ) {
    self.sampleRate = sampleRate
    self.decks = decks
    self.loopChannel = loopChannel
    self.loopMute = loopMute
    self.crossfader = crossfader
    self.master = master
    self.loopSettings = loopSettings
    self.clips = clips
    self.scenes = scenes
    self.removed = removed
    self.locked = locked
    self.stores = stores
  }

  /// The engine's state now, with the stores' contents. `playheads` also keeps where each deck
  /// is (`DeckCheckpoint.position`); off by default, because states compare by their JSON and a
  /// replay's playheads are not the live run's to the frame. Loop clips' phases are never kept.
  public init(
    engine dj: DJEngine, stores: JournalStoreState = JournalStoreState(), playheads: Bool = false
  ) {
    sampleRate = dj.sampleRate
    var decks: [String: DeckCheckpoint] = [:]
    for (name, d) in dj.decks {
      decks[name] = DeckCheckpoint(
        source: dj.journalSource(d), params: d.currentParams, playing: d.playing,
        leader: d.leader?.name, clip: d.clipID,
        voices: d.mode == .net ? d.wave.voiceSettings : [:],
        position: playheads ? d.journalPosition : nil)
    }
    self.decks = decks
    loopChannel = dj.loopChannel.currentParams
    loopMute = dj.loopChannel.mute
    crossfader = dj.crossfader
    master = dj.master
    loopSettings = dj.loopSettings
    let looping = Set(dj.loopingClips)
    clips = dj.clips.map { c in
      ClipCheckpoint(
        id: c.id, title: c.title, color: c.color, gain: dj.clipGain(c.id),
        muted: dj.isClipMuted(c.id), soloed: dj.isClipSoloed(c.id),
        keyLock: dj.clipKeyLocks[c.id], looping: looping.contains(c.id), fx: c.fx)
    }
    scenes = dj.scenes
    removed = dj.removedClips.map { ($0.clip.id, $0.index) }
    locked = dj.lockedActions.sorted()
    self.stores = stores
  }

  public var json: JSONValue {
    var decksObj = JSONObject()
    for name in decks.keys.sorted() {
      let d = decks[name]!
      var o = JSONObject([
        ("source", d.source.json), ("params", d.params.json), ("playing", .bool(d.playing)),
      ])
      if let l = d.leader { o["leader"] = .string(l) }
      if let c = d.clip { o["clip"] = .string(c) }
      if let p = d.position { o["position"] = .number(p) }
      if !d.voices.isEmpty {
        o["voices"] = .array(
          d.voices.keys.sorted().map { ch in
            let v = d.voices[ch]!
            return .object(
              JSONObject([
                ("channel", .int(ch)), ("instrument", .string(v.instrument)),
                ("tweak", v.tweak.json), ("synth", .bool(v.useSynth)),
              ]))
          })
      }
      decksObj[name] = .object(o)
    }
    var loop = loopChannel.json.object ?? JSONObject()
    loop["mute"] = .bool(loopMute)
    var out = JSONObject([
      ("schema", .string(Self.schema)), ("sampleRate", .number(sampleRate)),
      ("decks", .object(decksObj)), ("loopChannel", .object(loop)),
      (
        "mixer",
        .object(JSONObject([("crossfader", .number(crossfader)), ("master", .number(master))]))
      ),
      ("loopSettings", .array(loopSettings.map(\.json))),
      (
        "clips",
        .array(
          clips.map { c in
            var o = JSONObject([
              ("id", .string(c.id)), ("title", .string(c.title)), ("gain", .number(c.gain)),
              ("muted", .bool(c.muted)), ("soloed", .bool(c.soloed)),
              ("looping", .bool(c.looping)),
            ])
            if let color = c.color { o["color"] = .string(color) }
            if let k = c.keyLock { o["keyLock"] = .bool(k) }
            if c.fx != LoopFX() { o["fx"] = c.fx.json }
            return .object(o)
          })
      ),
      ("scenes", .array(scenes.map(\.json))),
      (
        "removed",
        .array(
          removed.map {
            .object(JSONObject([("id", .string($0.id)), ("index", .int($0.index))]))
          })
      ),
      ("locked", .array(locked.map { .string($0) })),
    ])
    if hasStores { out["stores"] = stores.json }
    return .object(out)
  }

  public init?(json v: JSONValue) {
    guard v["schema"]?.string == Self.schema, let sr = v["sampleRate"]?.double else { return nil }
    sampleRate = sr
    var decks: [String: DeckCheckpoint] = [:]
    for (name, d) in v["decks"]?.object?.entries ?? [] {
      guard let source = d["source"].flatMap(DeckSourceDescriptor.init(json:)) else { return nil }
      var voices: [Int: VoiceSetting] = [:]
      for e in d["voices"]?.array ?? [] {
        guard let ch = e["channel"]?.int else { continue }
        voices[ch] = VoiceSetting(
          tweak: VoiceTweak(json: e["tweak"]), useSynth: e["synth"]?.bool ?? false,
          instrument: e["instrument"]?.string ?? "")
      }
      decks[name] = DeckCheckpoint(
        source: source, params: d["params"].map(DeckParams.init(json:)) ?? DeckParams(),
        playing: d["playing"]?.bool ?? false, leader: d["leader"]?.string,
        clip: d["clip"]?.string, voices: voices, position: d["position"]?.double)
    }
    self.decks = decks
    let loop = v["loopChannel"]
    loopChannel = loop.map(DeckParams.init(json:)) ?? DeckParams()
    loopMute = loop?["mute"]?.bool ?? false
    crossfader = v["mixer"]?["crossfader"]?.double ?? 0.5
    master = v["mixer"]?["master"]?.double ?? 0.8
    loopSettings = (v["loopSettings"]?.array ?? []).compactMap(DeckAction.init(json:))
    clips = (v["clips"]?.array ?? []).compactMap { c in
      guard let id = c["id"]?.string else { return nil }
      return ClipCheckpoint(
        id: id, title: c["title"]?.string ?? "loop", color: c["color"]?.string,
        gain: c["gain"]?.double ?? 1, muted: c["muted"]?.bool ?? false,
        soloed: c["soloed"]?.bool ?? false, keyLock: c["keyLock"]?.bool,
        looping: c["looping"]?.bool ?? false, fx: LoopFX(json: c["fx"]))
    }
    scenes = (v["scenes"]?.array ?? []).compactMap(LoopScene.init(json:))
    removed = (v["removed"]?.array ?? []).compactMap { e in
      e["id"]?.string.map { ($0, e["index"]?.int ?? 0) }
    }
    locked = v["locked"]?.array?.compactMap(\.string) ?? []
    hasStores = v["stores"] != nil
    stores = JournalStoreState(json: v["stores"])
  }

  /// Every sample id the state names (decks' sources), for a replay to find before it starts.
  var sampleIDs: [String] {
    decks.values.compactMap {
      if case .sample(let id, _, _) = $0.source, id != DeckSourceDescriptor.demoID, $0.clip == nil {
        return id
      }
      return nil
    }
  }

  /// Stand a fresh engine (with these decks) where this state was. `clip` finds a clip's audio
  /// by id (the loop library: the row, then `removed/`); a clip it can't find is left out and
  /// named in the returned warnings. The deck sources' samples come from `dj.sampleResolver`.
  /// A deck with a `position` is put there after its load and params, before it plays (a net
  /// deck's relocation is inline in `deterministic` mode, else it lands like a section launch);
  /// decks without one, and every loop clip, start from their beginnings.
  @discardableResult
  public func restore(into dj: DJEngine, clip: (String) -> LoopClip?) -> [String] {
    var warnings: [String] = []
    for a in loopSettings { dj.applyAction(a) }
    var found: [LoopClip] = []
    for c in clips {
      if let lc = clip(c.id) {
        found.append(lc)
      } else {
        warnings.append("clip \(c.id) has no audio")
      }
    }
    dj.restoreClips(found)
    for c in clips where dj.clip(c.id) != nil {
      if dj.clip(c.id)?.title != c.title { dj.renameClip(c.id, c.title) }
      dj.setClipColor(c.id, c.color)
      if c.gain != 1 { dj.setClipGain(c.id, c.gain) }
      if c.muted { dj.setClipMute(c.id, true) }
      if c.soloed { dj.setClipSolo(c.id, true) }
      if let k = c.keyLock { dj.setClipKeyLock(c.id, k) }
      if dj.clipFx(c.id) != c.fx { dj.setClipFx(c.id, c.fx) }  // the run's, not the library's
    }
    dj.restoreScenes(scenes)
    for r in removed.reversed() {
      if let lc = clip(r.id) {
        dj.rememberRemovedClip(lc, at: r.index)
      } else {
        warnings.append("removed clip \(r.id) has no audio")
      }
    }
    for name in decks.keys.sorted() {
      guard let d = decks[name], let deck = dj[name] else { continue }
      if let id = d.clip, dj.clip(id) != nil {
        dj.playClip(id, on: name)
      } else {
        dj.applyAction(.load(deck: name, source: d.source))
      }
      deck.apply(d.params)
      for (ch, v) in d.voices.sorted(by: { $0.key < $1.key }) {
        if !v.tweak.isEmpty { deck.setVoiceTweak(v.tweak, channel: ch) }
        if v.useSynth { deck.setSynthVoice(true, channel: ch) }
      }
      if let p = d.position { deck.seek(journalPosition: p) }
    }
    for (name, d) in decks { if let l = d.leader { dj[name]?.follow(dj.decks[l]) } }
    dj.loopChannel.volume = loopChannel.volume
    dj.loopChannel.gain = loopChannel.gain  // the run's trim, not the engine's default
    dj.loopChannel.reverb.wet = loopChannel.reverbWet
    dj.loopChannel.reverb.size = loopChannel.reverbSize
    dj.loopChannel.reverb.tone = loopChannel.reverbTone
    dj.loopChannel.mute = loopMute
    dj.crossfader = crossfader
    dj.master = master
    dj.lockedActions = Set(locked)
    for c in clips where c.looping && dj.clip(c.id) != nil { dj.startLoop(c.id, atOnce: true) }
    for name in decks.keys.sorted() where decks[name]!.playing { dj[name]?.setPlaying(true) }
    return warnings
  }
}

extension DJEngine {
  /// What a deck holds, as a journal names it: like `Deck.sourceDescriptor`, but at any moment
  /// (a deck playing mid-track is still named by its source).
  func journalSource(_ d: Deck) -> DeckSourceDescriptor {
    switch d.mode {
    case .net:
      if let spec = d.currentSpec { return .net(spec) }
      if let payload = d.currentRawNets { return .rawNets(payload: payload) }
      return .none
    case .sample:
      guard let buffer = d.loaded else { return .none }
      let id = d.isDemo ? DeckSourceDescriptor.demoID : (d.clipID ?? sampleID(buffer))
      return .sample(id: id, title: d.title, grid: d.beatGrid)
    }
  }
}

extension Deck {
  /// Where the deck is, as a checkpoint keeps it: the sample frame (sample deck) or the net tick
  /// (net deck); nil with nothing loaded.
  var journalPosition: Double? {
    switch mode {
    case .sample: loaded == nil ? nil : turntable.position
    case .net: netProject == nil ? nil : Double(wave.tick)
    }
  }

  /// Put the deck at a checkpoint's `position` (see `journalPosition`).
  func seek(journalPosition p: Double) {
    switch mode {
    case .sample: if loaded != nil { turntable.send(.seek(sample: p)) }
    case .net: relocate(toTick: Int(p.rounded()))
    }
  }
}
