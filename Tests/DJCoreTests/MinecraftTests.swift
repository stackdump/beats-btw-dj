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
    for role in ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp", "stinger"] {
      let c = try #require(p.roles[role].flatMap { SoundPalette.categories[$0] }, "\(role)")
      #expect(c.bank == MinecraftBank.fileName)
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
    let index = try #require(MinecraftBank.Sidecar.load()?.assetIndex)
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
