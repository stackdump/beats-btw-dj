import AppKit
import DJCore
import Foundation

/// The control socket's methods (see `ControlSocket`, `MCPBridge`). Everything goes through
/// the same calls the app's own buttons make, so it lands in a recorded session the same way.
extension AppModel {
  public enum ControlRequestError: Error, CustomStringConvertible {
    case bad(String)
    public var description: String {
      switch self {
      case .bad(let s): return s
      }
    }
  }

  /// Start listening (the real app only; tests call `control` directly).
  func startControlServer() {
    do {
      controlServer = try ControlServer { [weak self] method, params in
        guard let self else { throw ControlRequestError.bad("DJApp is shutting down") }
        return try await self.control(method, params)
      }
    } catch {
      status = "control socket: \(error)"
    }
  }

  public func control(_ method: String, _ p: JSONValue) async throws -> JSONValue {
    guard let dj = engine else { throw ControlRequestError.bad("the audio engine did not start") }
    switch method {
    case "state":
      poll()
      return controlState()

    case "catalog":
      return controlCatalog()

    case "palettes":
      return controlPalettes(deck: p["deck"]?.string)

    case "perform":
      guard let a = p["action"], let action = DeckAction(json: a) else {
        throw ControlRequestError.bad(
          "`action` must be an object with a known `op` (see the dj_perform description)")
      }
      if case .load = action {
        throw ControlRequestError.bad(
          "use dj_generate, dj_load_share or dj_load_file to load a deck")
      }
      if case .clipImport(let id, _, _, let beats, _) = action {
        guard engine?.sampleLibrary[id] != nil, beats > 0 else {
          throw ControlRequestError.bad(
            "clipImport needs the content id of audio already loaded and beats > 0 "
              + "(dj_stock_loops addToRow puts a stock loop on the row)")
        }
      }
      // auto-mix: only the lengths and phrases the app offers; the defer is the engine's own
      if case .autoMixDefer = action {
        throw ControlRequestError.bad("autoMixDefer is recorded by the app itself, not performed")
      }
      if case .autoMix = action {
        if let bars = a["bars"], !AutoMixSettings.lengths.contains(bars.int ?? -1) {
          throw ControlRequestError.bad("autoMix bars must be one of \(AutoMixSettings.lengths)")
        }
        if let every = a["every"], !AutoMixSettings.everies.contains(every.int ?? -1) {
          throw ControlRequestError.bad(
            "autoMix every must be one of \(AutoMixSettings.everies) (0 = to the outro)")
        }
      }
      if let deck = a["deck"]?.string, a["op"]?.string?.hasPrefix("autoMix") != true {
        let d = try requireDeck(deck)
        let netOnly = [
          "section", "role", "macro", "stinger", "panic", "voiceTweak", "voiceSynth", "setKit",
          "setPalette", "setRoleVoice", "mixOut", "mixIn", "stemMute",
        ]
        // the loop channel and the sample decks take the master macros (the vinyl brake too)
        // and panic: their master FX bus
        let masterBus: Bool = {
          if case .panic = action { return true }
          guard case .macro(_, let id) = action else { return false }
          return MasterMacro(id: id) != nil
        }()
        if let op = a["op"]?.string, netOnly.contains(op), d.mode != .net, !masterBus {
          throw ControlRequestError.bad("deck \(deck) is playing a sample; \(op) needs a net deck")
        }
        switch action {
        case .voiceTweak(_, let ch, _), .voiceSynth(_, let ch, _):
          guard d.channelVoice(ch) != nil else {
            let chs = d.roleVoices.map { "\($0.channel) (\($0.role))" }.joined(separator: ", ")
            throw ControlRequestError.bad(
              "deck \(deck) has nothing on channel \(ch) (channels: \(chs))")
          }
        default: break
        }
        if case .macro(_, let id) = action, !Deck.isMacro(id: id) {
          throw ControlRequestError.bad("unknown macro \(id) (see dj_catalog)")
        }
        if case .setPalette(_, let p?) = action, SoundPalette.named(p) == nil {
          throw ControlRequestError.bad(
            "unknown palette \(p) (one of: \(SoundPalette.all.map(\.id).joined(separator: ", ")))")
        }
        if case .setRoleVoice(_, let role, _) = action,
          !d.roleSounds.contains(where: { $0.role == role })
        {
          throw ControlRequestError.bad(
            "deck \(deck) has no role \(role) (roles: "
              + d.roleSounds.map(\.role).joined(separator: ", ") + ")")
        }
        switch action {
        case .mixOut(_, let bars), .mixIn(_, let bars):
          guard (1...64).contains(bars) else {
            throw ControlRequestError.bad("\(a["op"]?.string ?? "mix") bars must be 1-64")
          }
        default: break
        }
        if case .stemMute(_, let stem, _) = action, !Deck.stemNames.contains(stem) {
          throw ControlRequestError.bad(
            "stemMute stem must be one of \(Deck.stemNames.joined(separator: ", "))")
        }
        // the master FX sliders: on a net's chain, a sample deck's bus, or the loops' ("L")
        if case .masterFx(_, let key, let value) = action {
          guard MasterFxKey(id: key) != nil else {
            throw ControlRequestError.bad(
              "unknown master FX key \(key) (one of: "
                + MasterFxKey.allCases.map(\.id).joined(separator: ", ") + ")")
          }
          guard value.isFinite, (0...1).contains(value) else {
            throw ControlRequestError.bad("masterFx value must be 0…1 (the slider's travel)")
          }
        }
        // the FX unit: a known control, inside its travel, on a deck that has it
        if case .fx(_, let param, let value) = action {
          guard let p = FxParam(id: param) else {
            throw ControlRequestError.bad(
              "unknown FX unit param \(param) (one of: "
                + FxParam.allCases.map(\.id).joined(separator: ", ") + ")")
          }
          guard value.isFinite, p.range.contains(value) else {
            throw ControlRequestError.bad(
              "fx \(param) value must be \(jsNumberString(p.range.lowerBound))…"
                + "\(jsNumberString(p.range.upperBound))")
          }
          if let why = d.fxUnitMissing(p) {
            throw ControlRequestError.bad("deck \(deck): no \(param) (\(why))")
          }
        }
        if case .wanderPace(_, let bars) = action, !WanderState.paces.contains(bars) {
          throw ControlRequestError.bad("wanderPace bars must be one of \(WanderState.paces)")
        }
        if case .wanderLock(_, let dim, _) = action, !WanderLock.isValid(dim) {
          throw ControlRequestError.bad(
            "wanderLock dimension must be one of \(WanderLock.dimensions) or keep:<role>")
        }
        if case .grid(_, let bpm, let offset) = action {
          guard d.mode == .sample else {
            throw ControlRequestError.bad("deck \(deck) is playing a net; grid needs a sample deck")
          }
          guard bpm > 0, bpm.isFinite, offset.isFinite else {
            throw ControlRequestError.bad("grid bpm must be > 0 (and offset a number of seconds)")
          }
        }
      }
      if case .loopFollow(let mode) = action, LoopFollow(rawValue: mode) == nil {
        throw ControlRequestError.bad(
          "loopFollow mode must be one of \(LoopFollow.allCases.map(\.rawValue))")
      }
      // the library's ops go the way the Loops row's buttons do (its Undo, its removed/)
      switch action {
      case .clipRemove(let id): removeClip(id)
      case .clipRestore(let id, nil):
        guard restoreRemoved(id) else { throw ControlRequestError.bad("no removed loop \(id)") }
      case .clipForget(let id): deleteForever(id)
      // as the panel's buttons do: remembered for the deck
      case .wanderPace(let deck, let bars): setWanderPace(deck, bars)
      case .autoMix(let on, let bars, let every): setAutoMix(on: on, bars: bars, every: every)
      case .wanderLock(let deck, let dim, let on): setWanderLock(deck, dim, on)
      // rendered off the main thread, as the clip settings' "Retune" does
      case .clipRetune(let id, let voices):
        guard dj.clip(id) != nil else { throw ControlRequestError.bad("no loop \(id) on the row") }
        guard !voices.isEmpty else {
          throw ControlRequestError.bad("clipRetune needs voices: {\"<channel>\": instrument}")
        }
        do {
          guard try await retuneClip(id, voices: voices) != nil else {
            throw ControlRequestError.bad("loop \(id) left the row (or is already retuning)")
          }
        } catch let r as ClipRetune.Refusal {
          throw ControlRequestError.bad(r.message)
        }
      default: dj.perform(action)
      }
      poll()
      return a["deck"]?.string.flatMap { deckJSON($0) } ?? controlState()

    case "generate":
      let deck = p["deck"]?.string ?? ""
      _ = try requireDeck(deck)
      guard let genre = p["genre"]?.string, BeatsTables.shared.genres[genre] != nil else {
        throw ControlRequestError.bad("unknown genre (see dj_catalog)")
      }
      let structure = p["structure"]?.string
      if let structure, !Self.structures.contains(structure) {
        throw ControlRequestError.bad("structure must be one of \(Self.structures)")
      }
      // composition options: an `options` object and/or the same keys flat
      var options = p["options"]?.object ?? JSONObject()
      for k in ComposeOptions.keys { if let v = p[k] { options[k] = v } }
      var spec: TrackSpec
      do {
        spec = try ComposeOptions.apply(
          options, to: TrackSpec(genre: genre, seed: p["seed"]?.double ?? 1, structure: structure))
      } catch let e as ComposeOptions.Invalid {
        throw ControlRequestError.bad(e.description)
      }
      // the deck's sound carries over, as the Generate panel's does; `palette` chooses another
      let palette = p["palette"]?.string
      if let palette, SoundPalette.named(palette) == nil {
        throw ControlRequestError.bad("unknown palette \(palette) (see dj_palettes)")
      }
      spec = generateSpec(deck, spec, palette: palette)
      await composeAndLoad(deck, spec)
      poll()
      return deckJSON(deck) ?? .null

    case "loadShare", "composeRoll", "importScore":
      let inspecting = method == "importScore" && p["inspect"]?.bool == true
      let deck = p["deck"]?.string ?? ""
      if !inspecting { _ = try requireDeck(deck) }
      // dj_compose / dj_inspired: a piano roll becomes a raw-nets envelope, then loads like
      // any share. dj_import: a score file is read into the same kind of envelope.
      var rollPayload: JSONValue?
      var importSummary: JSONValue?
      if method == "composeRoll" {
        do { rollPayload = try PianoRoll.envelope(p) } catch let e as PianoRollError {
          throw ControlRequestError.bad(e.description)
        }
      } else if method == "importScore" {
        let path = ((p["path"]?.string ?? "") as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path),
          let data = FileManager.default.contents(atPath: path)
        else { throw ControlRequestError.bad("no file at `path`") }
        var o = MidiImport.Options()
        if let v = p["from"]?.double { o.from = Int(v) }
        if let v = p["bars"]?.double { o.bars = Int(v) }
        o.tempo = p["tempo"]?.double
        o.name = p["name"]?.string
        o.source = p["source"]?.string
        for (k, v) in p["map"]?.object?.entries ?? [] { if let r = v.string { o.map[k] = r } }
        do {
          let r = try ScoreImport.convert(data, file: path, options: o)
          rollPayload = r.envelope
          importSummary = r.summary
        } catch {
          throw ControlRequestError.bad("\(error)")
        }
        if inspecting { return .object(JSONObject([("import", importSummary ?? .null)])) }
      }
      let source: DeckSourceDescriptor
      do {
        if rollPayload == nil, let link = p["link"]?.string {
          source = try .share(link)
        } else if let payload = rollPayload ?? p["link"] ?? p["payload"], payload.object != nil {
          source = try .share(payload: payload)
        } else {
          throw ControlRequestError.bad(
            "`link` is required: a beats share URL or an envelope payload (JSON)")
        }
      } catch let e as ShareLoadError {
        throw ControlRequestError.bad(e.description)
      }
      guard await prepareAndLoad(deck, source) else { throw ControlRequestError.bad(status) }
      poll()
      var o = deckJSON(deck)?.object ?? JSONObject()
      if let importSummary { o["import"] = importSummary }
      if case .rawNets(let payload) = source {
        o["share"] = .object(
          JSONObject([
            ("kind", .string("rawNets")), ("cid", .string(BeatsCID.shareCID(payload))),
          ]))
      } else if case .net(let spec) = source {
        o["share"] = .object(
          JSONObject([
            ("kind", .string("net")), ("cid", .string(BeatsCID.shareCID(spec.payload))),
            ("genre", .string(spec.genre)), ("seed", .number(spec.seed)),
          ]))
      }
      return .object(o)

    case "loadFile":
      let deck = p["deck"]?.string ?? ""
      _ = try requireDeck(deck)
      guard let path = p["path"]?.string, FileManager.default.fileExists(atPath: path) else {
        throw ControlRequestError.bad("no file at `path`")
      }
      guard load(deck, url: URL(fileURLWithPath: path)) else {
        throw ControlRequestError.bad(status)
      }
      poll()
      return deckJSON(deck) ?? .null

    case "pad":
      guard let group = p["group"]?.string, let index = p["index"]?.int else {
        throw ControlRequestError.bad("`group` and `index` are required")
      }
      if !showPads { setShowPads(true) }
      poll()
      let shift = p["shift"]?.bool ?? false
      guard let port = padPort,
        router?.press(port: port, group: group, index: index, shift: shift) == true
      else {
        throw ControlRequestError.bad("no pad \(group)[\(index)] on the APC mini")
      }
      poll()
      return controlState()

    case "audition":
      return try audition(p)

    case "favorites":
      switch p["action"]?.string ?? "list" {
      case "list": break
      case "add":
        let deck = p["deck"]?.string ?? ""
        _ = try requireDeck(deck)
        poll()
        guard addFavorite(deck) != nil else {
          throw ControlRequestError.bad(
            "deck \(deck) has nothing to star (a net, or a sample loaded from a file)")
        }
      case "remove":
        guard let cid = try favoriteCID(p) else {
          throw ControlRequestError.bad("`cid` (or `deck`) is required")
        }
        removeFavorite(cid: cid)
      case "load":
        let deck = p["deck"]?.string ?? ""
        _ = try requireDeck(deck)
        guard let cid = p["cid"]?.string, let f = favorites.first(where: { $0.cid == cid }) else {
          throw ControlRequestError.bad("no favorite with that `cid` (see action list)")
        }
        guard await loadFavoriteNow(deck, f) else { throw ControlRequestError.bad(status) }
        poll()
        return deckJSON(deck) ?? .null
      case "tags":
        guard let cid = try favoriteCID(p), favorites.contains(where: { $0.cid == cid }) else {
          throw ControlRequestError.bad("`cid` (or `deck`) of a favorite is required")
        }
        setFavoriteTags(cid, p["tags"]?.array?.compactMap(\.string) ?? [])
      case "crates": break
      case "newCrate":
        newCrate(try crateName(p))
      case "addToCrate":
        let crate = try crateName(p)
        if let path = p["path"]?.string {
          await loadStockLoops()
          guard
            favorites.contains(where: { $0.cid == Favorite.fileCID(path) })
              || stockLoops.contains(where: { $0.path == path })
          else {
            throw ControlRequestError.bad("no stock loop at that `path` (see dj_stock_loops)")
          }
          addToCrate(path, crate)
        } else if let cid = p["cid"]?.string {
          guard addFavoriteToCrate(cid, crate) else {
            throw ControlRequestError.bad("no favorite with that `cid` (see action list)")
          }
        } else {
          throw ControlRequestError.bad("`cid` (a favorite) or `path` (a stock loop) is required")
        }
      case "removeFromCrate":
        let crate = try crateName(p)
        guard let cid = p["cid"]?.string, favorites.contains(where: { $0.cid == cid }) else {
          throw ControlRequestError.bad("`cid` of a favorite is required")
        }
        removeFromCrate(cid, crate)
      case "deleteCrate":
        let crate = try crateName(p)
        guard crates.contains(crate) else {
          throw ControlRequestError.bad("no crate \"\(crate)\" (crates: \(crates))")
        }
        deleteCrate(crate)
      case "keepMove":
        let deck = p["deck"]?.string ?? ""
        let d = try requireDeck(deck)
        guard let step = p["step"]?.int else {
          throw ControlRequestError.bad("`step` (a move of dj_state's wander.log) is required")
        }
        guard let move = d.wander.log.first(where: { $0.step == step }) else {
          let have = d.wander.log.map(\.step)
          throw ControlRequestError.bad("deck \(deck) has no wander move \(step) (log: \(have))")
        }
        guard move.spec != nil else {
          throw ControlRequestError.bad("wander move \(step) has no track to star")
        }
        let kept = keepWanderMove(move)
        poll()
        var o = favoritesReply()
        o["kept"] = .bool(kept != nil)
        if let kept { o["favorite"] = favoriteJSON(kept) }
        return .object(o)
      case let other:
        throw ControlRequestError.bad(
          "action must be list | add | remove | load | tags | crates | newCrate | addToCrate | "
            + "removeFromCrate | deleteCrate | keepMove, not \(other)")
      }
      poll()
      return .object(favoritesReply())

    case "stockLoops":
      await loadStockLoops()
      switch p["action"]?.string ?? "list" {
      case "list":
        let hits = stockLoops.matching(
          category: p["category"]?.string ?? "", query: p["query"]?.string ?? "",
          near: p["near"]?.double ?? p["deck"]?.string.flatMap { loopTempo(for: $0) })
        let limit = max(1, Int(p["limit"]?.double ?? 20))
        return .object(
          JSONObject([
            ("total", .int(hits.count)),
            ("categories", .array(stockLoops.categories.map { .string($0) })),
            ("loops", .array(hits.prefix(limit).map(stockLoopJSON))),
          ]))
      case "load":
        let deck = p["deck"]?.string ?? ""
        _ = try requireDeck(deck)
        guard let path = p["path"]?.string, let loop = stockLoops.first(where: { $0.path == path })
        else { throw ControlRequestError.bad("`path` must be a loop from action list") }
        guard await loadStockLoop(deck, loop) else { throw ControlRequestError.bad(status) }
        poll()
        return deckJSON(deck) ?? .null
      case "addToRow":
        guard let path = p["path"]?.string, let loop = stockLoops.first(where: { $0.path == path })
        else { throw ControlRequestError.bad("`path` must be a loop from action list") }
        guard let id = await addStockLoopToRow(loop) else { throw ControlRequestError.bad(status) }
        poll()
        return controlState()["loops"]?["clips"]?.array?.first { $0["id"]?.string == id } ?? .null
      case let other:
        throw ControlRequestError.bad("action must be list | load | addToRow, not \(other)")
      }

    case "copyDeck":
      let from = p["from"]?.string ?? ""
      let to = p["to"]?.string ?? ""
      _ = try requireDeck(from)
      _ = try requireDeck(to)
      guard from != to else { throw ControlRequestError.bad("`from` and `to` are the same deck") }
      guard await copyDeck(from: from, to: to) else { throw ControlRequestError.bad(status) }
      poll()
      return deckJSON(to) ?? .null

    case "setInstrument":
      let deck = p["deck"]?.string ?? ""
      let d = try requireDeck(deck)
      guard let role = p["role"]?.string, let instrument = p["instrument"]?.string else {
        throw ControlRequestError.bad("`role` and `instrument` are required")
      }
      let voices = d.roleVoices
      guard let v = voices.first(where: { $0.role.components(separatedBy: " · ").contains(role) })
      else {
        let roles = voices.map(\.role).joined(separator: ", ")
        throw ControlRequestError.bad("deck \(deck) has no role \(role) to voice (roles: \(roles))")
      }
      guard v.options.contains(instrument) else {
        throw ControlRequestError.bad("\(role) can play: \(v.options.joined(separator: ", "))")
      }
      guard await setInstrument(deck, channel: v.channel, instrument) else {
        throw ControlRequestError.bad(status)
      }
      poll()
      return deckJSON(deck) ?? .null

    case "view":
      return try controlView(p)

    case "settings":
      return try await controlSettings(p)

    case "screenshot":
      return try screenshot(to: p["path"]?.string)

    case "record":
      let on = p["on"]?.bool ?? false
      if on != isRecording { toggleRecording() }
      guard on == isRecording else { throw ControlRequestError.bad(status) }
      var o = JSONObject([("recording", .bool(isRecording)), ("status", .string(status))])
      if !on, let cid = lastSession { o["cid"] = .string(cid) }
      return .object(o)

    case "notes":
      return try controlNotes(p)

    case "journal":
      return try await controlJournal(p)

    case "variations":
      return try await controlVariations(p)

    case "loops":
      return try await controlLoops(p)

    case "minecraftEvents":
      return try controlMinecraftEvents(p)

    default:
      throw ControlRequestError.bad("unknown method \(method)")
    }
  }

  static let structures = ["minimal", "standard", "extended"]

  /// Every instrument beats' generator can pick, sorted.
  static var allInstruments: [String] {
    var names = Set<String>()
    for set in BeatsTables.shared.instrumentSets.values {
      for pool in set.values { names.formUnion(pool) }
    }
    return names.sorted()
  }

  /// What an instrument can sound like here: its category, how many sampled sounds this Mac
  /// has for it (a track picks one by seed), its fallback (SoundFont or GM), or its synth voice.
  static func soundOf(_ name: String) -> String {
    if name.hasPrefix("drums") { return "drum kit" }
    let v = InstrumentTable.shared.voice(instrument: name, group: "melody")
    let synth = v.engine == "table" ? "table:\(v.wave)" : v.engine
    let catalog = VoiceCatalog.shared
    guard let category = catalog.categoryOf[name] else { return synth }
    let n = catalog.pool(category).count
    let keeps = catalog.keepSynth.contains(category)
    var out = "\(category): \(n) sampled"
    if !catalog.soundFonts.isEmpty && catalog.gm[category] != nil {
      out += ", SoundFont"
    } else if !keeps && n == 0 {
      out += ", GM"
    }
    return out + (keeps ? " or \(synth)" : "")
  }

  /// Render a short phrase on one instrument, save it as a WAV and play it on the Mac's
  /// output (outside the decks, so nothing on them changes).
  func audition(_ p: JSONValue) throws -> JSONValue {
    guard let name = p["instrument"]?.string, Self.allInstruments.contains(name) else {
      throw ControlRequestError.bad("unknown instrument (dj_catalog lists them)")
    }
    guard !name.hasPrefix("drums") else {
      throw ControlRequestError.bad("drum kits are not tonal; generate a track to hear one")
    }
    let sr = engine?.sampleRate ?? 48_000
    let notes: [(note: Int, at: Double, seconds: Double)]
    if let given = p["notes"]?.array?.compactMap(\.int), !given.isEmpty {
      notes = given.enumerated().map { (min(108, max(21, $1)), Double($0) * 0.3, 0.3) }
    } else {
      // a strummed C chord, then a few single notes
      notes = [
        (48, 0, 0.6), (52, 0.02, 0.6), (55, 0.04, 0.6), (60, 0.06, 0.6), (64, 0.08, 0.6),
        (60, 0.8, 0.25), (64, 1.05, 0.25), (67, 1.3, 0.25), (72, 1.55, 0.8),
      ]
    }
    let seconds = p["seconds"]?.double ?? max(2.5, (notes.map { $0.at }.max() ?? 0) + 1.5)
    let voice = InstrumentTable.shared.voice(instrument: name, group: "melody")
    var sampler: (bank: SamplerBank, slot: Int)?
    var plays = voice.engine == "table" ? "table:\(voice.wave)" : voice.engine
    let catalog = VoiceCatalog.shared
    var sources = catalog.sources(instrument: name, role: "melody", seed: p["seed"]?.double ?? 0)
    if let sound = p["sound"]?.string {
      let pool = catalog.categoryOf[name].map { catalog.pool($0) } ?? []
      guard let s = pool.first(where: { $0.name.lowercased() == sound.lowercased() }) else {
        throw ControlRequestError.bad(
          "no sound \"\(sound)\" for \(name) (its pool: \(pool.map(\.name).joined(separator: ", ")))"
        )
      }
      sources = [s.source]
    }
    if let sources, let slot = auditionBank.slot(for: sources) {
      sampler = (auditionBank, slot)
      plays = auditionBank.source(of: slot)?.description ?? plays
    }
    let audio = WaveRunner.audition(
      voice, notes: notes, sampleRate: sr, seconds: min(10, max(0.5, seconds)), sampler: sampler)
    if let sampler { sampler.bank.release(sampler.slot) }
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJApp/auditions", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name).wav")
    let wav = WAV.encode(RenderedAudio(sampleRate: sr, left: audio, right: audio))
    try wav.write(to: url)
    let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
    let rms = (audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.count)))
      .squareRoot()
    if p["play"]?.bool ?? true {
      auditionSound?.stop()
      let sound = NSSound(data: wav)
      sound?.volume = Float(master)
      sound?.play()
      auditionSound = sound
    }
    return .object(
      JSONObject([
        ("instrument", .string(name)), ("sound", .string(Self.soundOf(name))),
        ("plays", .string(plays)),
        ("path", .string(url.path)), ("seconds", .number(Double(audio.count) / sr)),
        ("peakDB", .number((20 * log10(max(Double(peak), 1e-9)) * 10).rounded() / 10)),
        ("rmsDB", .number((20 * log10(max(rms, 1e-9)) * 10).rounded() / 10)),
      ]))
  }

  /// The app's own window as a PNG (no Screen Recording permission: it is our window).
  /// Default path: `~/Library/Application Support/DJApp/shots/<time>.png`.
  func screenshot(to path: String?) throws -> JSONValue {
    poll()
    guard
      let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
      let view = window.contentView
    else { throw ControlRequestError.bad("no visible DJApp window") }
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw ControlRequestError.bad("could not allocate a bitmap for the window")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw ControlRequestError.bad("could not encode PNG")
    }
    let url: URL
    if let path {
      url = URL(fileURLWithPath: path)
    } else {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
        of: ":", with: "")
      url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DJApp/shots/\(stamp).png")
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: url)
    return .object(
      JSONObject([
        ("path", .string(url.path)), ("width", .int(rep.pixelsWide)),
        ("height", .int(rep.pixelsHigh)),
      ]))
  }

  /// `cid`, or the favorite of what `deck` is playing.
  private func favoriteCID(_ p: JSONValue) throws -> String? {
    if let cid = p["cid"]?.string { return cid }
    guard let deck = p["deck"]?.string else { return nil }
    _ = try requireDeck(deck)
    poll()
    return decks[deck]?.sourceCID
  }

  func stockLoopJSON(_ l: StockLoop) -> JSONValue {
    var o = JSONObject([
      ("name", .string(l.name)), ("path", .string(l.path)), ("pack", .string(l.pack)),
      ("category", .string(l.category)), ("subcategory", .string(l.subcategory)),
      ("genre", .string(l.genre)), ("bpm", .number((l.bpm * 10).rounded() / 10)),
      ("beats", .int(l.beats)),
    ])
    if let k = l.key { o["key"] = .string(k) }
    return .object(o)
  }

  /// The favorites method's reply: every favorite, and every crate.
  func favoritesReply() -> JSONObject {
    JSONObject([
      ("favorites", .array(favorites.map(favoriteJSON))),
      ("crates", .array(crates.map { .string($0) })),
    ])
  }

  private func crateName(_ p: JSONValue) throws -> String {
    let n = (p["crate"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { throw ControlRequestError.bad("`crate` (its name) is required") }
    return n
  }

  func favoriteJSON(_ f: Favorite) -> JSONValue {
    var o = JSONObject([("title", .string(f.title)), ("cid", .string(f.cid))])
    if case .net(let spec) = f.source {
      o["genre"] = .string(spec.genre)
      o["seed"] = .number(spec.seed)
      if let st = spec.structure { o["structure"] = .string(st) }
    } else if f.isSample {
      o["kind"] = .string("sample")
      if let file = f.file { o["file"] = .string(file) }
    } else {
      o["kind"] = .string("rawNets")
    }
    if !f.tags.isEmpty { o["tags"] = .array(f.tags.map { .string($0) }) }
    return .object(o)
  }

  /// `minecraftEvents` (dj_minecraft_events): mc_recent_events' window → the mapped actions
  /// on `deck` (default: the focus deck), each new event once, a stinger at most once a bar.
  /// Performed through the engine, so they record as a button's would.
  func controlMinecraftEvents(_ p: JSONValue) throws -> JSONValue {
    guard let dj = engine else { throw ControlRequestError.bad("the audio engine did not start") }
    guard let list = p["events"] else {
      throw ControlRequestError.bad("`events` must be mc_recent_events' array (or its result)")
    }
    let events: [MinecraftEvent]
    do {
      events = try MinecraftEvent.parse(json: list)
    } catch {
      throw ControlRequestError.bad("\(error)")
    }
    let deck = p["deck"]?.string ?? dj.focus
    let d = try requireDeck(deck)
    let (fired, skipped) = minecraftFeed.take(
      events, deck: deck, bar: d.beatState?.bar, net: d.mode == .net,
      prime: p["prime"]?.bool ?? false)
    for f in fired { dj.perform(f.action) }
    poll()
    return MinecraftEventFeed.report(
      deck: deck, fired: fired, skipped: skipped, cursor: minecraftFeed.cursor)
  }

  /// The control socket's `settings`: the monitoring settings the bottom bar and mixer set —
  /// `pfl` {deck: bool}, `headphoneMix` / `headphoneLevel` (0…1), `awake`, `inpulseOutput`.
  /// Applies only the keys given (all checked first, so a bad one changes nothing) and returns
  /// every value as it stands. None of it is recorded: the cue never reaches the master mix.
  func controlSettings(_ p: JSONValue) async throws -> JSONValue {
    var pfl: [(String, Bool)] = []
    if let given = p["pfl"] {
      guard let o = given.object else {
        throw ControlRequestError.bad("`pfl` must be an object of deck: bool, e.g. {\"A\": true}")
      }
      for (name, v) in o.entries {
        guard let on = v.bool else { throw ControlRequestError.bad("pfl.\(name) must be a bool") }
        _ = try requireDeck(name)
        pfl.append((name, on))
      }
    }
    func level(_ key: String) throws -> Double? {
      guard let v = p[key] else { return nil }
      guard let x = v.double, (0...1).contains(x) else {
        throw ControlRequestError.bad("`\(key)` must be a number from 0 to 1")
      }
      return x
    }
    let mix = try level("headphoneMix")
    let headLevel = try level("headphoneLevel")
    let awake = p["awake"]?.bool
    if p["awake"] != nil && awake == nil { throw ControlRequestError.bad("`awake` must be a bool") }
    let route = p["inpulseOutput"]?.bool
    if p["inpulseOutput"] != nil && route == nil {
      throw ControlRequestError.bad("`inpulseOutput` must be a bool")
    }
    if route == true && !inpulseRouted && findInpulse() == nil {
      throw ControlRequestError.bad(
        "no DJControl Inpulse audio output is connected (plug it in over USB; "
          + "dj_state.inpulseOutput is null while it is missing)")
    }
    for (name, on) in pfl { setPFL(name, on) }
    if let mix { setHeadphoneMix(mix) }
    if let headLevel { setHeadphoneLevel(headLevel) }
    if let awake { setKeepScreenAwake(awake) }
    if let route { await routeInpulseOutput(route) }
    poll()
    let state = controlState()
    var o = JSONObject([
      ("headphones", state["headphones"] ?? .null), ("awake", .bool(keepScreenAwake)),
      ("inpulseOutput", state["inpulseOutput"] ?? .null),
    ])
    if route == true && !inpulseRouted { o["status"] = .string(status) }
    return .object(o)
  }

  func requireDeck(_ name: String) throws -> Deck {
    guard let d = engine?[name] else {
      let have = (engine?.decks.keys.sorted() ?? []).joined(separator: ", ")
      throw ControlRequestError.bad("no deck \"\(name)\" (decks: \(have))")
    }
    return d
  }

  func controlState() -> JSONValue {
    var o = JSONObject()
    o["status"] = .string(status)
    o["decks"] = .object(
      JSONObject(decks.keys.sorted().compactMap { n in deckJSON(n).map { (n, $0) } }))
    o["crossfader"] = .number(crossfader)
    o["autoMix"] = engine?.autoMixJSON ?? .null
    o["master"] = .number(master)
    o["focus"] = .string(engine?.focus ?? "A")
    o["fxUnit"] = fxUnitJSON()
    o["recording"] = .bool(isRecording)
    o["loops"] = .object(
      JSONObject([
        (
          "clips",
          .array(
            clips.map {
              var c = JSONObject([
                ("id", .string($0.id)), ("title", .string($0.title)),
                ("source", .string($0.source)), ("bars", .int($0.bars)), ("bpm", .number($0.bpm)),
              ])
              c["loop"] = .string("\($0.loop)")
              c["gain"] = .number($0.gain)
              if let color = $0.color { c["color"] = .string(color) }
              c["canLoadSource"] = .bool($0.canLoadOrigin)
              // waiting to come in or go out: beats until it switches
              if let cd = $0.countdown { c["switchIn"] = .number(cd.beatsLeft) }
              c["muted"] = .bool($0.muted)
              c["soloed"] = .bool($0.soloed)
              c["keyLock"] = .bool($0.keyLock)
              c["stretched"] = .bool($0.stretched)
              if $0.fx != LoopFX() { c["fx"] = $0.fx.json }
              if let on = $0.onDeck { c["onDeck"] = .string(on) }
              if let p = engine?.clip($0.id)?.provenance { c["provenance"] = p }
              return .object(c)
            })
        ),
        (
          "masterFx",
          .object(
            JSONObject([
              (
                "running",
                .array(
                  MasterMacro.allCases.filter { loopChannel.masterRunning.contains($0) }.map {
                    .string($0.id)
                  })
              ),
              ("link", .bool(loopChannel.fxLink)),
            ]))
        ),
        (
          "removed",
          .array(
            removedLoops.map {
              .object(
                JSONObject([
                  ("id", .string($0.id)), ("title", .string($0.title)),
                  ("source", .string($0.source)), ("beats", .int($0.beats)),
                  ("bpm", .number($0.bpm)), ("index", .int($0.index)),
                  ("removed", .string($0.removed)),
                ]))
            })
        ),
        (
          "channel",
          .object(
            JSONObject([
              ("looping", .int(loopChannel.looping)), ("volume", .number(loopChannel.volume)),
              ("mute", .bool(loopChannel.mute)), ("fade", .string(loopChannel.fade.rawValue)),
              ("keyLock", .bool(loopChannel.keyLock)),
            ]))
        ),
        ("tapBars", .int(tapBars)),
        ("quantize", .int(loopQuantum)),
        // whose tempo the loops follow (the row's "Tempo") and, for louder, the deck that is now
        (
          "follow",
          .object(
            JSONObject([
              ("mode", .string(loopFollow.rawValue)),
              ("deck", followingDeck.map { .string($0) } ?? .null),
            ]))
        ),
        (
          "scenes",
          .array(
            (engine?.scenes ?? []).map { s in
              .object(
                JSONObject([
                  ("name", .string(s.name)),
                  (
                    "clips",
                    .array(
                      s.clips.map {
                        .object(
                          JSONObject([("id", .string($0.clipID)), ("gain", .number($0.gain))]))
                      })
                  ),
                  ("active", .bool(scenes.first { $0.name == s.name }?.active ?? false)),
                ]))
            })
        ),
        (
          "taking",
          .object(
            JSONObject(
              recording.sorted { $0.key < $1.key }.map {
                (
                  $0.key,
                  .object(
                    JSONObject([
                      ("bars", .int($0.value.bars)), ("released", .bool($0.value.released)),
                    ]))
                )
              }))
        ),
      ]))
    if let s = lastSession { o["lastSession"] = .string(s) }
    o["controllers"] = .array(
      devices.map {
        .object(JSONObject([("port", .string($0.port)), ("profile", .string($0.profile))]))
      })
    if !lastMessage.isEmpty { o["lastMidi"] = .string(lastMessage) }
    o["padsOnScreen"] = .bool(showPads)
    o["view"] = viewJSON
    o["keepScreenAwake"] = .bool(keepScreenAwake)
    o["awake"] = .bool(keepScreenAwake)
    // buttons locked by right-click ▸ Disable (their `lockKey`s), sorted
    o["locked"] = .array(lockedButtons.sorted().map { .string($0) })
    // the headphone cue: mix (0 cue … 1 master), level, and which decks are cued
    o["headphones"] = .object(
      JSONObject([
        ("mix", .number(headphoneMix)), ("level", .number(headphoneLevel)),
        (
          "pfl",
          .object(
            JSONObject(
              decks.keys.sorted().map { n in (n, .bool(engine?[n]?.pfl ?? false)) }))
        ),
      ]))
    if let out = inpulseOutput {
      o["inpulseOutput"] = .object(
        JSONObject([
          ("name", .string(out.name)), ("uid", .string(out.uid)),
          ("channels", .int(out.outputChannels)), ("routed", .bool(inpulseRouted)),
        ]))
    } else {
      o["inpulseOutput"] = .null
    }
    o["scope"] = .object(
      JSONObject([
        ("open", .bool(showScopes)), ("kind", .string(scopeKind.rawValue)),
        ("source", .string(Self.scopeSourceID(scopeSource))), ("measured", .bool(scopeMeasured)),
      ]))
    if let stage = stageModel { o["stage"] = stageJSON(stage) }  // reads; never attaches the feed
    o["crates"] = .array(crates.map { .string($0) })
    o["variations"] = .object(
      JSONObject(
        variations.sorted { $0.key < $1.key }.map { instrument, saved in
          (
            instrument,
            .array(
              saved.map {
                .object(
                  JSONObject([
                    ("name", .string($0.name)), ("useSynth", .bool($0.useSynth)),
                    ("params", $0.params.json),
                  ]))
              })
          )
        }))
    let b = BuildInfo.current
    var build = JSONObject([
      ("id", .string(b.id)), ("version", .string(b.version)), ("build", .string(b.build)),
    ])
    if let d = b.dateString { build["date"] = .string(d) }
    o["build"] = .object(build)
    return .object(o)
  }

  /// "master", or the deck's name.
  static func scopeSourceID(_ s: ScopeSource) -> String {
    switch s {
    case .master: "master"
    case .deck(let n): n
    }
  }

  /// The Stage window: whether it is up (its model attached to the feed) and its toolbar's
  /// settings. Only reads the model, so asking does not switch a feed's tap on.
  func stageJSON(_ stage: StageModel) -> JSONValue {
    let s = stage.settings
    return .object(
      JSONObject([
        ("open", .bool(stage.isAttached)), ("source", .string(Self.scopeSourceID(s.source))),
        ("visualizer", .string(s.visualizer.rawValue)),
        ("overlays", .array(s.overlays.map(\.rawValue).sorted().map { .string($0) })),
        ("scale", .string(s.scale.rawValue)), ("expandVariants", .bool(s.expandVariants)),
        ("showBacks", .bool(s.showBacks)), ("showLabels", .bool(s.showLabels)),
        ("cardOnChange", .bool(s.cardOnChange)), ("background", .string(s.bgMode.rawValue)),
        ("showWander", .bool(s.showWander)), ("menuCollapsed", .bool(s.menuCollapsed)),
      ]))
  }

  func deckJSON(_ name: String) -> JSONValue? {
    guard let s = decks[name], let d = engine?[name] else { return nil }
    var o = JSONObject()
    o["title"] = .string(s.title)
    o["mode"] = .string(s.isNet ? "net" : "sample")
    o["playing"] = .bool(s.playing)
    if let bpm = s.bpm { o["bpm"] = .number((bpm * 10).rounded() / 10) }
    o["position"] = .number((s.positionSeconds * 100).rounded() / 100)
    o["duration"] = .number((s.duration * 100).rounded() / 100)
    o["volume"] = .number(s.volume)
    o["filter"] = .number(s.filter)
    o["pitch"] = .number(s.pitch)
    o["eq"] = .object(
      JSONObject([
        ("low", .number(d.eqLow)), ("mid", .number(d.eqMid)), ("high", .number(d.eqHigh)),
      ]))
    o["quantize"] = .string(s.quantize)
    o["autoAdvance"] = .bool(d.autoAdvance)
    // loudness before the EQ and fader (LevelMatch.swift): the deck's meter, a sample's
    // auto-gain, a net deck's limiter
    func r1(_ x: Double) -> JSONValue { .number((x * 10).rounded() / 10) }
    var level = JSONObject([
      ("shortTermLUFS", r1(max(-120, d.shortTermLUFS))),
      ("momentaryLUFS", r1(max(-120, d.momentaryLUFS))), ("autoGain", .bool(d.autoGain)),
      ("autoGainDB", r1(d.autoGainDB)),
    ])
    if d.autoGain, let l = d.sampleLevel {  // reading it measures: only when it is used
      if let lufs = l.lufs { level["sampleLUFS"] = r1(lufs) }
      level["samplePartial"] = .bool(l.partial)
    }
    if s.isNet { level["limiterGainReductionDB"] = r1(d.limiterGainReductionDB) }
    o["level"] = .object(level)
    o["hotCues"] = .array(s.cues.sorted().map { .int($0) })
    // the deck's walk: on, pace, the countdown, paused (steering), locks, the newest moves
    o["wander"] = d.wanderJSON(lockedActions: engine?.lockedActions ?? [])
    // a sample deck's master chain runs the master macros too (its own bus)
    if !s.isNet {
      o["macrosRunning"] = .array(
        MasterMacro.allCases.filter { s.masterRunning.contains($0) }.map { .string($0.id) })
    }
    if s.isNet {
      o["sections"] = .array(
        s.sections.enumerated().map { i, sec in
          .object(
            JSONObject([
              ("index", .int(i)), ("name", .string(sec.name)), ("steps", .int(sec.steps)),
            ]))
        })
      if let c = s.currentSection { o["currentSection"] = .int(c) }
      o["roles"] = .object(JSONObject(s.roles.map { ($0, .bool(s.rolesOn.contains($0))) }))
      o["beatInBar"] = .int(s.beatInBar)
      // what Hit 1–4 fire: curated from the genre and palette (StingerCuration)
      o["stingers"] = .array(d.stingers.map(\.json))
      // the macros in effect: net ones, then the master chain's
      o["macrosRunning"] = .array(
        (NetMacro.allCases.filter { s.macroPulse.isRunning($0) }.map(\.id)
          + MasterMacro.allCases.filter { s.masterRunning.contains($0) }.map(\.id)).map {
            .string($0)
          })
      o["nextTrack"] = .string(s.nextReady ? "ready" : (s.nextComposing ? "composing" : "none"))
      o["mixingOut"] = .bool(s.mixingOut)
      o["mixingIn"] = .bool(s.mixingIn)
      // what dj plays the net with: its pass (composed tracks) and the runner's fixes
      if let f = d.fixes {
        o["fixes"] = .object(
          JSONObject([
            ("pass", .bool(d.passApplied)), ("names", .array(f.names.map { .string($0) })),
          ]))
      }
      // what reloads this track: a favorite, dj_load_share, a copy
      if let cid = s.sourceCID {
        var share = JSONObject([("cid", .string(cid))])
        if let spec = d.currentSpec {
          share["kind"] = .string("net")
          share["genre"] = .string(spec.genre)
          share["seed"] = .number(spec.seed)
          if let st = spec.structure { share["structure"] = .string(st) }
          share["cohesion"] = .string(spec.cohesion)
        } else {
          share["kind"] = .string("rawNets")
        }
        o["share"] = .object(share)
        o["favorite"] = .bool(favorites.contains { $0.cid == cid })
      }
      if !s.voices.isEmpty {
        o["instruments"] = .object(JSONObject(s.voices.map { ($0.role, .string($0.instrument)) }))
        // each channel's voice: what plays it and the sound panel's settings (session-only)
        o["voices"] = .array(
          s.voices.map { v in
            let setting = s.voiceSettings[v.channel]
            var e = JSONObject([
              ("role", .string(v.role)), ("channel", .int(v.channel)),
              ("instrument", .string(v.instrument)),
              ("sampled", .bool(s.channelVoices[v.channel]?.sampled ?? false)),
              ("useSynth", .bool(setting?.useSynth ?? false)),
              ("tweak", setting?.tweak.json ?? .object(JSONObject())),
            ])
            if let name = currentVariation(v.instrument, setting)?.name {
              e["variation"] = .string(name)
            }
            if let saved = variations[v.instrument], !saved.isEmpty {
              e["variations"] = .array(saved.map { .string($0.name) })
            }
            return .object(e)
          })
      }
      // the sound palette and what each role plays from it
      o["palette"] = .string(d.playingPalette?.id ?? SoundPalette.defaultID)
      if let k = d.kit { o["kit"] = .string(k) }
      o["sound"] = .array(s.roleSounds.map(\.json))
      if let spec = d.currentSpec {
        let options = ComposeOptions.describe(spec)
        if !options.entries.isEmpty { o["options"] = .object(options) }
      }
      // role (riff variants `bass-0`, `bass-1`… folded together) → what it plays on
      var sampled: [String: String] = [:]
      for (net, src) in d.wave.sampledNets {
        let role = net.split(separator: "-").dropLast().joined(separator: "-")
        sampled[role.isEmpty ? net : role] = src
      }
      if !sampled.isEmpty {
        o["sampled"] = .object(
          JSONObject(sampled.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))
      }
    }
    return .object(o)
  }

  /// Every palette: what it is, whether it plays here (and why not), and each role's options;
  /// with `deck`, which one that deck plays and what each role plays from it.
  func controlPalettes(deck: String?) -> JSONValue {
    let current = deck.flatMap { engine?[$0]?.playingPalette?.id }
    var o = JSONObject()
    o["default"] = .string(SoundPalette.defaultID)
    o["palettes"] = .array(
      SoundPalette.all.map { p in
        var e = JSONObject([
          ("id", .string(p.id)), ("label", .string(p.label)), ("icon", .string(p.icon)),
          ("description", .string(p.description)), ("localOnly", .bool(p.isLocalOnly)),
          ("neighbours", .array(p.neighbours.map { .string($0) })),
        ])
        if let why = PaletteCard.unavailableHere[p.id] ?? nil { e["unavailable"] = .string(why) }
        e["roles"] = .object(
          JSONObject(
            SoundPalette.roleOrder.compactMap { r in
              p.roles[r].map { (r, .array($0.map { .string($0) })) }
            }))
        if let current { e["playing"] = .bool(current == p.id) }
        return .object(e)
      })
    if let deck, let d = engine?[deck] {
      o["deck"] = .string(deck)
      o["sound"] = .array(d.roleSounds.map(\.json))
    }
    return .object(o)
  }

  func controlCatalog() -> JSONValue {
    var o = JSONObject()
    o["decks"] = .array((engine?.decks.keys.sorted() ?? []).map { .string($0) })
    o["genres"] = .array(BeatsTables.shared.genres.keys.sorted().map { .string($0) })
    o["structures"] = .array(Self.structures.map { .string($0) })
    o["palettes"] = .array(SoundPalette.all.map { .string($0.id) })
    o["voices"] = .object(
      JSONObject(
        VoiceCatalog.shared.sounds.keys.sorted().map { c in
          (c, .array(VoiceCatalog.shared.pool(c).map { .string($0.name) }))
        }))
    o["instruments"] = .array(
      Self.allInstruments.map {
        .object(JSONObject([("name", .string($0)), ("sound", .string(Self.soundOf($0)))]))
      })
    o["macros"] =
      .array(
        NetMacro.allCases.map {
          .object(
            JSONObject([
              ("id", .string($0.id)), ("label", .string($0.label)), ("group", .string("Net")),
            ]))
        }
          + MasterMacro.allCases.map {
            .object(
              JSONObject([
                ("id", .string($0.id)), ("label", .string($0.label)), ("group", .string($0.group)),
              ]))
          })
    o["apcPads"] = .array(
      SurfaceProfile.apcMiniMK2.deviceMap().filter { !$0.parked && $0.action != "unbound" }.map {
        var r = JSONObject([
          ("group", .string($0.group)), ("index", .int($0.index)), ("action", .string($0.action)),
        ])
        if let s = $0.shiftedAction { r["shifted"] = .string(s) }
        return .object(r)
      })
    return .object(o)
  }
}
