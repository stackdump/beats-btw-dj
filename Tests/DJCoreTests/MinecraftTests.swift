import Testing

@testable import DJCore

/// The Minecraft palette: the user's installed game sounds (`MinecraftAssets`), built into a
/// local bank (`MinecraftImport` → minecraft-local.sf2 + sidecar), played through a whole-track
/// palette (`SoundPalette`). Tests that need the game's assets skip without them, as
/// SoundFontTests does without its bank.
struct MinecraftTests {
  let sr = 48_000.0

  @Test func theNewestIndexIsPicked() {
    #expect(MinecraftAssets.newest(["5", "27", "29", "30", "32"]) == "32")
    #expect(MinecraftAssets.newest(["9", "10"]) == "10")
    #expect(MinecraftAssets.newest([]) == nil)
  }

  @Test func theSoundtrackIsNeverRead() {
    #expect(MinecraftAssets.isForbidden("music/game/calm1"))
    #expect(MinecraftAssets.isForbidden("records/cat"))
    #expect(!MinecraftAssets.isForbidden("note/harp2"))
    // no program, kit zone or palette sound reaches for them
    for p in MinecraftBank.programs { #expect(!MinecraftAssets.isForbidden(p.sound), "\(p.name)") }
    for z in MinecraftBank.kitZones { #expect(!MinecraftAssets.isForbidden(z.sound)) }
  }

  /// Without the game the palette is simply unavailable, with a reason to show.
  @Test func missingAssetsMakeThePaletteUnavailable() throws {
    #expect(throws: MinecraftAssets.Unavailable.self) {
      try MinecraftAssets.locate(root: "/nonexistent/assets")
    }
    let empty = emptyScratchDir()
    let palette = try #require(SoundPalette.named("minecraft"))
    #expect(!palette.isPlayable(dir: empty))
    #expect(palette.unavailableReason(dir: empty) != nil)
    #expect(palette.sources(role: "bass", seed: 1, dir: empty) == nil)
    #expect(SoundPalette.kit(for: "minecraft", dir: empty) == nil)
  }

  /// The palette as data: every role's category exists and names programs the bank has.
  @Test func thePaletteNamesRealPrograms() throws {
    let p = try #require(SoundPalette.named("minecraft"))
    #expect(p.label == "Minecraft")
    #expect(p.isLocalOnly)
    #expect(p.kit == MinecraftBank.kitID)
    for role in ["kit", "bass", "melody", "harmony", "arp", "stinger"] {
      let c = try #require(p.roles[role]?.first.flatMap(SoundPalette.bankCategory), "\(role)")
      #expect(c.bank == MinecraftBank.fileName)
      #expect((c.kit != nil) == (role == "kit"), "\(role)")
      for s in c.sounds { #expect(MinecraftBank.program(named: s) != nil, "\(role): \(s)") }
    }
    let programs = MinecraftBank.programs.map(\.program)
    #expect(Set(programs).count == programs.count, "program numbers are unique")
    #expect(!programs.contains(MinecraftBank.kitProgram))
    #expect(SoundPalette.named("minecraft@32")?.id == "minecraft", "a recorded asset index")
  }

  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func assetsResolveThroughSoundsJSON() throws {
    let a = try #require(minecraftAssets)
    #expect(Int(a.indexID) != nil)
    #expect(a.sounds(event: "block.note_block.harp") == ["note/harp2"])
    #expect(a.sounds(event: "block.note_block.basedrum") == ["note/bd"])
    let f = try a.file(sound: "note/harp2")
    #expect(lastPathComponent(f.path) == f.sha1, "objects are named by their SHA-1")
    #expect(throws: MinecraftAssets.Unavailable.self) { try a.file(sound: "music/game/calm1") }
  }

  /// The import: one program per sound at its fixed number, the kit preset, the sidecar
  /// naming the index and every sample's SHA-1; the same assets build the same bytes.
  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func theImportBuildsTheBank() throws {
    let (dir, report) = try #require(scratchMinecraftBank)
    let a = try #require(minecraftAssets)
    #expect(report.assetIndex == a.indexID)
    #expect(report.programs.count >= 13, "skipped: \(report.skipped)")
    let side = try #require(MinecraftBank.Sidecar.load(dir: dir))
    #expect(side.assetIndex == a.indexID)
    #expect(side.format == MinecraftBank.formatVersion)
    #expect(side.version == "\(a.indexID)+b\(MinecraftBank.formatVersion)")
    #expect(side.programs.contains("harp2") && side.programs.contains("bassattack"))
    #expect(side.sha1["harp2"] == (try a.file(sound: "note/harp2")).sha1)
    #expect(side.sha1["kit:bd"] != nil)
    let presets = BankPresets.sf2(MinecraftBank.path(dir: dir))
    #expect(presets.contains { $0.program == 0 && $0.name == "mc harp2" })
    #expect(
      presets.contains { $0.program == MinecraftBank.kitProgram && $0.name == "Minecraft Kit" })
    #expect(DrumKits.scan(banks: [MinecraftBank.path(dir: dir)]).map(\.id) == [MinecraftBank.kitID])
    // steady tones loop, plucks don't
    for (name, loops) in [("flute", true), ("didgeridoo", true), ("harp2", false)] {
      #expect(report.programs.first { $0.name == name }?.loop == loops, "\(name)")
    }
    let again = emptyScratchDir()
    _ = try MinecraftImport.run(assets: a, to: again)
    #expect(bankBytes(again) == bankBytes(dir), "deterministic")
  }

  /// Every tone loads through the bank's checks (level-matched; local-only banks skip the
  /// tuning check) and plays in tune at its root; the kit loads as a kit.
  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func theBankPlaysInTune() throws {
    let (dir, report) = try #require(scratchMinecraftBank)
    let path = MinecraftBank.path(dir: dir)
    let bank = SamplerBank(sampleRate: sr)
    for p in report.programs {
      let s = SamplerSource.sf2(path, program: p.program)
      let slot = bank.slot(for: [s])
      #expect(slot != nil, "\(p.name): \(bank.loadFailure(for: s) ?? "")")
      if let slot { bank.release(slot) }
    }
    for name in ["harp2", "flute", "bell", "bassattack"] {
      let prog = try #require(MinecraftBank.programs.first { $0.name == name })
      let s = SamplerSource.sf2(path, program: prog.program)
      let slot = try #require(bank.slot(for: [s]))
      defer { bank.release(slot) }
      let note = prog.root + (name == "bassattack" ? 12 : 0)
      let x = WaveRunner.audition(
        tonalVoice(instrument: "", group: "melody"), notes: [(note, 0, 0.5)], sampleRate: sr,
        seconds: 0.4, sampler: (bank, slot))
      let e = pitchClassError(x[Int(0.03 * sr)..<Int(0.25 * sr)], note: note, sampleRate: sr)
      #expect(abs(e.cents) < 12, "\(name): \(e.cents) cents")
    }
    let kit = SamplerSource.kit(path, bank: 0, program: MinecraftBank.kitProgram)
    let k = bank.slot(for: [kit])
    #expect(k != nil, "the kit: \(bank.loadFailure(for: kit) ?? "")")
    if let k { bank.release(k) }
  }

  /// The octave zones: across ±2 octaves of each tone's root every key plays in tune (each zone
  /// is an exact octave of the measured recording), and crossing a split moves the level by no
  /// more than a semitone step inside a zone could (≤ 3 dB).
  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func octaveZonesPlayInTuneAndLevel() throws {
    let (dir, report) = try #require(scratchMinecraftBank)
    let path = MinecraftBank.path(dir: dir)
    let bank = SamplerBank(sampleRate: sr)
    let built = Set(report.programs.map(\.name))
    for name in ["harp2", "flute", "bell", "bassattack", "bit"] where built.contains(name) {
      let prog = try #require(MinecraftBank.programs.first { $0.name == name })
      let slot = try #require(bank.slot(for: [.sf2(path, program: prog.program)]))
      defer { bank.release(slot) }
      func play(_ note: Int) -> [Float] {
        WaveRunner.audition(
          tonalVoice(instrument: "", group: "melody"), notes: [(note, 0, 0.5)], sampleRate: sr,
          seconds: 0.4, sampler: (bank, slot))
      }
      for note in stride(from: prog.root - 24, through: prog.root + 24, by: 3)
      where (24...108).contains(note) {
        let x = play(note)
        let e = pitchClassError(x[Int(0.03 * sr)..<Int(0.25 * sr)], note: note, sampleRate: sr)
        #expect(e.level > 0, "\(name) @\(note): silent")
        #expect(abs(e.cents) < 5, "\(name) @\(note): \(e.cents) cents")
      }
      for z in MinecraftImport.octaveZones(root: prog.root).dropLast() {
        let below = z.keys.upperBound
        let a = rmsDB(play(below)[Int(0.03 * sr)..<Int(0.25 * sr)])
        let b = rmsDB(play(below + 1)[Int(0.03 * sr)..<Int(0.25 * sr)])
        #expect(abs(a - b) <= 3, "\(name) split \(below)|\(below + 1): \(a) → \(b) dB")
      }
    }
  }

  /// A held flute note sustains on its loop (a pad can hold it); a harp pluck dies away.
  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func steadyTonesHold() throws {
    let (dir, _) = try #require(scratchMinecraftBank)
    let path = MinecraftBank.path(dir: dir)
    let bank = SamplerBank(sampleRate: sr)
    func tail(_ name: String) throws -> Double {
      let prog = try #require(MinecraftBank.programs.first { $0.name == name })
      let slot = try #require(bank.slot(for: [.sf2(path, program: prog.program)]))
      defer { bank.release(slot) }
      let x = WaveRunner.audition(
        tonalVoice(instrument: "", group: "harmony"), notes: [(prog.root, 0, 2.5)], sampleRate: sr,
        seconds: 2.2, sampler: (bank, slot))
      return rmsDB(x[Int(1.8 * sr)...]) - rmsDB(x[Int(0.05 * sr)..<Int(0.3 * sr)])
    }
    #expect(try tail("flute") > -15, "flute holds")
    #expect(try tail("harp2") < -30, "harp decays")
  }

  /// The Minecraft kit sits where the synth kit did, as any sampled kit must.
  @Test(
    .enabled(if: MinecraftBank.isInstalled(), "minecraft-local.sf2 not imported (make minecraft)"))
  func theMinecraftKitSitsInTheMix() throws {
    try SampledKitTests().expectKitLevels(MinecraftBank.kitID)
  }

  /// A palette pick is seeded by the track seed and role: stable, varied across seeds, and
  /// always from the role's category.
  @Test(.enabled(if: minecraftAssets != nil, "no Minecraft assets (PrismLauncher)"))
  func palettePicksAreSeeded() throws {
    let (dir, _) = try #require(scratchMinecraftBank)
    let p = try #require(SoundPalette.named("minecraft"))
    let bass = Set(
      ["bassattack", "didgeridoo", "guitar"].compactMap(MinecraftBank.program(named:)))
    var firsts: Set<SamplerSource> = []
    for seed in 0..<20 {
      let s = try #require(p.sources(role: "bass", seed: Double(seed), dir: dir))
      #expect(s == p.sources(role: "bass", seed: Double(seed), dir: dir))
      #expect(s.count == bass.count)
      for x in s {
        guard case .sf2(_, let prog) = x else {
          Issue.record("\(x)")
          continue
        }
        #expect(bass.contains(prog))
      }
      firsts.insert(s[0])
    }
    #expect(firsts.count > 1, "seeds pick different basses")
    #expect(p.sources(role: "nope", seed: 1, dir: dir) == nil)
  }

  /// On a deck: the palette lands at the next bar on the same song, records its asset
  /// version, voices the roles from the bank (drums on its kit), and a picked instrument keeps
  /// its own sound.
  @Test(
    .enabled(if: MinecraftBank.isInstalled(), "minecraft-local.sf2 not imported (make minecraft)"))
  func aDeckSwapsToThePaletteAtTheNextBar() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 48_000)
    dj.deterministic = true
    let deck = try #require(dj["A"])
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard")
    deck.loadNet(
      PreparedTrack(spec: spec, sampleRate: deck.wave.sampleRate, opts: deck.waveOptions))
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let buf = makeEngineRenderBuffer(dj, frames: 512)
    pullEngine(dj, buf, cycles: 40, frames: 512)
    let index = try #require(MinecraftBank.Sidecar.load()?.version)
    dj.perform(.setPalette(deck: "A", palette: "minecraft"))
    #expect(deck.palette == "minecraft@\(index)")
    pullEngine(dj, buf, cycles: 200, frames: 512)
    let sampled = deck.wave.sampledNets
    #expect(sampled.values.contains { $0.hasPrefix("kit:\(MinecraftBank.fileName)") }, "\(sampled)")
    #expect(
      sampled.contains {
        $0.key.hasPrefix("bass") && $0.value.hasPrefix("sf2:\(MinecraftBank.fileName)")
      }, "\(sampled)")
    // a kit pick wins over the palette's kit
    dj.perform(.setKit(deck: "A", kit: floorKit))
    pullEngine(dj, buf, cycles: 200, frames: 512)
    if floorBank != nil {
      #expect(deck.wave.sampledNets.values.contains { $0.hasPrefix("kit:MuseScore") })
    }
    dj.perform(.setPalette(deck: "A", palette: nil))
    pullEngine(dj, buf, cycles: 200, frames: 512)
    #expect(deck.palette == nil)
    #expect(!deck.wave.sampledNets.values.contains { $0.contains(MinecraftBank.fileName) })
  }

  /// The zones cover the keyboard once, and no key within two octaves of the root plays a
  /// sample more than six semitones from that sample's root.
  @Test func octaveZonesCoverTheKeyboard() {
    for p in MinecraftBank.programs where p.kind == .tone {
      for root in (p.root - 1)...(p.root + 1) {
        let zones = MinecraftImport.octaveZones(root: root)
        #expect(zones.map(\.shift) == [-1, 0, 1], "\(p.name)")
        var next = 0
        for z in zones {
          #expect(z.keys.lowerBound == next, "\(p.name): contiguous")
          next = z.keys.upperBound + 1
          for k in z.keys where abs(k - root) <= 24 {
            #expect(abs(k - (root + 12 * z.shift)) <= 6, "\(p.name) key \(k)")
          }
        }
        #expect(next == 128)
      }
    }
  }

  /// The octave shifts: an exact octave, the level kept in the passband, nothing folding back
  /// (−60 dB) or imaged, loop points scaled, the same bytes twice.
  @Test func octaveShiftsAreBandLimitedOctaves() throws {
    let rate = MinecraftImport.sampleRate
    let a4 = sineWave(440, sampleRate: rate, seconds: 0.5)
    let body = { (x: [Float]) in x[(x.count / 4)..<(3 * x.count / 4)] }
    let up = MinecraftImport.octaveShift(a4, loop: 1000..<3000, octaves: 1)
    let down = MinecraftImport.octaveShift(a4, loop: 1000..<3000, octaves: -1)
    #expect(up.pcm.count == a4.count / 2)
    #expect(down.pcm.count == a4.count * 2)
    #expect(up.loop == 500..<1500)
    #expect(down.loop == 2000..<6000)
    #expect(MinecraftImport.octaveShift(a4, loop: nil, octaves: 0).pcm == a4)
    for (x, note) in [(up.pcm, 81), (down.pcm, 57)] {
      let e = pitchClassError(body(x), note: note, sampleRate: rate)
      #expect(e.octave == 0 && abs(e.cents) < 1, "\(note): \(e)")
      #expect(abs(rmsDB(body(x)) - rmsDB(body(a4))) < 0.1, "\(note): level")
    }
    // 15 kHz an octave up would fold to 14.1 kHz; an octave down it leaves an image at
    // 14.55 kHz beside the 7.5 kHz it becomes
    let high = sineWave(15_000, sampleRate: rate, seconds: 0.5)
    let ref = toneLevelDB(body(high), freq: 15_000, sampleRate: rate)
    let folded = MinecraftImport.octaveShift(high, loop: nil, octaves: 1).pcm
    #expect(rmsDB(body(folded)) - rmsDB(body(high)) < -60, "nothing folds back")
    #expect(toneLevelDB(body(folded), freq: 14_100, sampleRate: rate) - ref < -60)
    let stretched = MinecraftImport.octaveShift(high, loop: nil, octaves: -1).pcm
    #expect(abs(toneLevelDB(body(stretched), freq: 7_500, sampleRate: rate) - ref) < 0.5)
    #expect(toneLevelDB(body(stretched), freq: 14_550, sampleRate: rate) - ref < -60, "no image")
    #expect(MinecraftImport.octaveShift(high, loop: nil, octaves: 1).pcm == folded)
  }

  /// The sidecar records the bank format and the palette records it in its version; a bank
  /// built before formats (no `format` key) still records just its asset index.
  @Test func theBankFormatIsInThePaletteVersion() throws {
    let p = try #require(SoundPalette.named("minecraft"))
    let now = emptyScratchDir()
    try writeMinecraftSidecar(dir: now, assetIndex: "32", format: MinecraftBank.formatVersion)
    let side = try #require(MinecraftBank.Sidecar.load(dir: now))
    #expect(side.format == MinecraftBank.formatVersion)
    #expect(MinecraftBank.formatVersion == 2)
    #expect(p.recorded(dir: now) == "minecraft@32+b2")
    #expect(SoundPalette.named("minecraft@32+b2")?.id == "minecraft")
    #expect(SoundPalette.version("minecraft@32+b2") == "32+b2")
    let old = emptyScratchDir()
    try writeMinecraftSidecar(dir: old, assetIndex: "32", format: nil)
    #expect(MinecraftBank.Sidecar.load(dir: old)?.format == 1)
    #expect(p.recorded(dir: old) == "minecraft@32")
  }

  @Test func setPaletteRoundTrips() {
    for a in [
      DeckAction.setPalette(deck: "A", palette: "minecraft@32"),
      .setPalette(deck: "B", palette: nil),
    ] {
      #expect(DeckAction(json: a.json) == a)
    }
  }

  /// A palette is the `tracks` override on every channel; the parity path ignores it.
  @Test func aPaletteIsATracksOverrideTheParityPathIgnores() throws {
    let spec = TrackSpec(genre: "house", seed: 3, structure: "minimal")
    let project = spec.project()
    let d = try #require(
      DeckSourceDescriptor.net(spec).withPalette("minecraft@32", channels: project.channels))
    guard case .net(let s2) = d else { throw KitTestError.notNet }
    let p2 = s2.project()
    #expect(p2.palette == "minecraft@32")
    for id in p2.nets.keys where p2.nets[id]!.role != "control" {
      #expect(p2.nets[id]!.track.palette == "minecraft@32", "\(id)")
    }
    var o = WaveOptions()
    o.master = "linear"
    #expect(
      renderRunner(project, opts: o, sampleRate: sr, seconds: 1)
        == renderRunner(p2, opts: o, sampleRate: sr, seconds: 1))
    #expect(try #require(d.withPalette(nil, channels: project.channels)) == .net(spec))
  }

  /// Publishing refuses a session that plays the Minecraft bank — a palette or its kit, at
  /// load or as a poke — unless told to; other sessions publish as before.
  @Test func publishRefusesLocalOnlySounds() throws {
    let spec = TrackSpec(genre: "house", seed: 3, structure: "minimal")
    let channels = spec.project().channels
    let plain = Session(
      sampleRate: 48_000, frames: 48_000, decks: ["A": .net(spec)], params: ["A": DeckParams()],
      crossfader: 0.5, master: 0.8, events: [])
    #expect(plain.localOnlySounds.isEmpty)
    _ = try SessionBundle(session: plain, renderedAt: "2026-10-17T00:00:00Z")
    var loaded = plain
    loaded.decks["A"] = DeckSourceDescriptor.net(spec).withPalette(
      "minecraft@32", channels: channels)
    var poked = plain
    poked.events = [
      SessionEvent(frame: 10, kind: .action(.setPalette(deck: "A", palette: "minecraft@32")))
    ]
    var kitted = plain
    kitted.events = [
      SessionEvent(frame: 10, kind: .action(.setKit(deck: "A", kit: MinecraftBank.kitID)))
    ]
    for s in [loaded, poked, kitted] {
      #expect(!s.localOnlySounds.isEmpty)
      #expect(throws: PublishError.self) { try SessionBundle(session: s, renderedAt: "x") }
      #expect(throws: PublishError.self) {
        try SessionBundle(session: s, renderedAt: "x", draft: true)
      }
      _ = try SessionBundle(session: s, renderedAt: "x", allowLocalOnly: true)
    }
  }
}

/// Gameplay → stingers (MinecraftEvents.swift): mc_recent_events mapped through
/// voices/minecraft-events.json, each event once, at most one stinger a bar per deck.
extension MinecraftTests {
  @Test func recentEventsParseFromTheToolAndItsResult() throws {
    let text = try mcRecentEventsFixture()
    let events = try MinecraftEvent.parse(text)
    #expect(
      events.map(\.event) == [
        "log:chat", "minecraft:notification/players/joined", "log:advancement", "log:death",
        "log:death",
      ])
    #expect(events.allSatisfy { $0.player == "stackdump" })
    #expect(events[1].source == "rpc")
    // the same array inside an MCP result (val_call's strings, or text parts)
    let wrapped = JSONValue.object(JSONObject([("content", .array([.string(text)]))]))
    #expect(try MinecraftEvent.parse(json: wrapped) == events)
    let parts = JSONValue.object(
      JSONObject([
        (
          "content",
          .array([.object(JSONObject([("type", .string("text")), ("text", .string(text))]))])
        )
      ]))
    #expect(try MinecraftEvent.parse(json: parts) == events)
    #expect(try MinecraftEvent.parse("[]").isEmpty)
    #expect(throws: MinecraftEventError.self) { try MinecraftEvent.parse(#"{"x":1}"#) }
  }

  @Test func eventsMapToStingers() throws {
    let map = try MinecraftEventMap.load()
    func at(_ s: String, _ e: String) -> MinecraftEvent { MinecraftEvent(at: s, event: e) }
    #expect(map.action(for: at("t", "log:death"), deck: "A") == .stinger(deck: "A", n: 0))
    #expect(map.action(for: at("t", "log:advancement"), deck: "B") == .stinger(deck: "B", n: 1))
    #expect(
      map.action(for: at("t", "minecraft:notification/players/joined"), deck: "A")
        == .stinger(deck: "A", n: 2))
    #expect(map.action(for: at("t", "log:chat"), deck: "A") == nil)
    #expect(MinecraftEventMap.shared.actions.count == map.actions.count)
  }

  /// The app's Contents/Resources copy wins over SwiftPM's (Bundle.main first).
  @Test func theMapLoadsFromTheFirstBundleThatHasIt() throws {
    let over = try eventMapWithOverride(
      #"{"events":{"log:chat":{"op":"stinger","n":3}}}"#)
    #expect(
      over.action(for: MinecraftEvent(at: "t", event: "log:chat"), deck: "A")
        == .stinger(deck: "A", n: 3))
    #expect(over.action(for: MinecraftEvent(at: "t", event: "log:death"), deck: "A") == nil)
    // the test runner's main bundle has none: SwiftPM's is next
    #expect(try MinecraftEventMap.load().actions["log:death"] != nil)
  }

  /// A re-read window fires nothing twice (events sharing a millisecond included), and a
  /// deck takes one stinger a bar.
  @Test func aRepeatedWindowFiresEachEventOnce() throws {
    let events = try MinecraftEvent.parse(try mcRecentEventsFixture())
    var feed = MinecraftEventFeed(map: try MinecraftEventMap.load())
    var bar = 0
    let first = feed.take(Array(events.prefix(3)), deck: "A", bar: bar)
    #expect(first.fired.map(\.action) == [.stinger(deck: "A", n: 2)])
    #expect(first.skipped.map(\.reason) == ["unmapped", "a stinger already fired in bar 0"])
    #expect(feed.cursor == "2026-10-18T16:16:22.845Z")
    // the next poll overlaps: only the new death at the cursor's millisecond and the one after
    bar = 1
    let second = feed.take(events, deck: "A", bar: bar)
    #expect(second.fired.map(\.action) == [.stinger(deck: "A", n: 0)])
    #expect(second.fired.first?.event.at == "2026-10-18T16:16:22.845Z")
    #expect(second.skipped.map(\.reason) == ["a stinger already fired in bar 1"])
    // the same window again: nothing new
    bar = 2
    let third = feed.take(events, deck: "A", bar: bar)
    #expect(third.fired.isEmpty && third.skipped.isEmpty)
    // the bar limit is per deck
    var feedB = MinecraftEventFeed(map: try MinecraftEventMap.load())
    let deaths = events.filter { $0.event == "log:death" }
    let b = feedB.take(deaths, deck: "B", bar: 7)
    #expect(b.fired.count == 1)
    _ = feedB.take([], deck: "A", bar: 7)
    let later = MinecraftEvent(at: "2026-10-18T16:17:00.000Z", event: "log:death")
    #expect(feedB.take([later], deck: "A", bar: 7).fired.count == 1, "deck A's bar 7 is free")
  }

  @Test func primingTakesTheBacklogWithoutPlayingIt() throws {
    let events = try MinecraftEvent.parse(try mcRecentEventsFixture())
    var feed = MinecraftEventFeed(map: try MinecraftEventMap.load())
    let primed = feed.take(events, deck: "A", bar: 0, prime: true)
    #expect(primed.fired.isEmpty && primed.skipped.count == events.count)
    #expect(feed.take(events, deck: "A", bar: 1).fired.isEmpty)
    // a sample deck can't take stingers: the event is consumed with the reason
    let next = MinecraftEvent(at: "2026-10-18T16:20:00.000Z", event: "log:advancement")
    let s = feed.take([next], deck: "A", bar: 2, net: false)
    #expect(s.fired.isEmpty && s.skipped.first?.reason.contains("net") == true)
    // without a beat grid: one stinger per poll
    let two = [
      MinecraftEvent(at: "2026-10-18T16:21:00.000Z", event: "log:death"),
      MinecraftEvent(at: "2026-10-18T16:21:01.000Z", event: "log:death"),
    ]
    #expect(feed.take(two, deck: "A", bar: nil).fired.count == 1)
  }

  /// `djctl minecraft events`: stdin → the request's params, the reply → lines.
  @Test func theCommandBuildsTheRequest() throws {
    let p = try MinecraftEventsCommand.params(
      stdin: try mcRecentEventsFixture(), deck: "B", prime: false)
    #expect(p["deck"]?.string == "B")
    #expect(p["events"]?.array?.count == 5)
    #expect(p["prime"] == nil)
    let back = try MinecraftEvent.parse(json: p["events"]!)
    #expect(back == (try MinecraftEvent.parse(try mcRecentEventsFixture())))
    let q = try MinecraftEventsCommand.params(stdin: "[]", deck: nil, prime: true)
    #expect(q["deck"] == nil && q["prime"]?.bool == true)
    let ev = MinecraftEvent(
      at: "t", event: "log:death", params: .object(JSONObject([("player", .string("x"))])))
    let reply = MinecraftEventFeed.report(
      deck: "A", fired: [.init(event: ev, action: .stinger(deck: "A", n: 0))], skipped: [],
      cursor: "t")
    let text = MinecraftEventsCommand.describe(reply)
    #expect(text.contains("log:death (x) → A"))
    #expect(text.hasSuffix("fired 1, skipped 0"))
  }
}
