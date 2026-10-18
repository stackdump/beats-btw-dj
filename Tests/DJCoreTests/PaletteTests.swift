import Testing

@testable import DJCore

/// Sound palettes as the way a track chooses its sound (`SoundPalette`, palettes.json): the data,
/// what each resolves to on this Mac, the deterministic picks, the user's overrides surviving
/// recomputes, Wander's palette hop, the codec, the publish guard and the levels.
struct PaletteDataTests {
  let roles = ["kit", "bass", "melody", "harmony", "arp", "stinger"]

  /// The shipped set: 8–13 named, described palettes, the default first, every option in the
  /// grammar, every neighbour real.
  @Test func theShippedPalettesAreWellFormed() throws {
    let all = SoundPalette.all
    #expect((8...13).contains(all.count), "\(all.map(\.id))")
    #expect(Set(all.map(\.id)).count == all.count, "unique ids")
    #expect(all.first?.id == SoundPalette.defaultID && SoundPalette.defaultID == "studio")
    let studio = try #require(SoundPalette.named("studio"))
    #expect(studio.roles.isEmpty, "the default plays every instrument's own sound")
    for p in all {
      #expect(!p.label.isEmpty && !p.icon.isEmpty && p.description.count > 20, "\(p.id)")
      #expect(p.color.hasPrefix("#") && p.color.count == 7, "\(p.id)")
      #expect(!p.neighbours.isEmpty, "\(p.id) has somewhere to hop")
      for n in p.neighbours {
        #expect(SoundPalette.named(n) != nil && n != p.id, "\(p.id) → \(n)")
      }
      for (role, opts) in p.roles {
        #expect(roles.contains(role) || role == "*" || role == "pad", "\(p.id): \(role)")
        for o in opts {
          let why = SoundPalette.unavailableReason(option: o, role: role) ?? ""
          for bad in ["unknown option", "not a kit", "no instrument", "no synth kit", "not a"] {
            #expect(!why.hasPrefix(bad), "\(p.id) \(role): \(o): \(why)")
          }
        }
      }
    }
    #expect(SoundPalette.named("jazz@3")?.id == "jazz")
    #expect(SoundPalette.playing(nil)?.id == "studio")
  }

  /// Every palette either plays here — each role it names resolving, for any seed, to an option
  /// that is installed, whose samples are on disk — or says which role can't and why.
  @Test func everyPaletteResolvesEveryRoleHereOrSaysWhy() throws {
    var report: [String] = []
    for p in SoundPalette.all {
      if let why = p.unavailableReason() {
        report.append("\(p.id): unavailable — \(why)")
        #expect(!p.isPlayable())
        continue
      }
      for role in roles where p.pool(role) != nil {
        #expect(!p.available(role).isEmpty, "\(p.id) \(role)")
        for seed in [1.0, 11, 42, 777] {
          let o = try #require(p.pick(role: role, key: role, seed: seed), "\(p.id) \(role)")
          #expect(SoundPalette.unavailableReason(option: o, role: role) == nil)
          if role == "kit" {
            let k = try #require(SoundPalette.kitID(option: o))
            if k != "synth" { #expect(DrumKits.source(for: k) != nil, "\(p.id): \(k)") }
          } else if let s = SoundPalette.sources(option: o, role: role, seed: seed) {
            for src in s.prefix(1) { #expect(src.isAvailable, "\(p.id) \(role): \(src)") }
          } else {
            #expect(
              o == "own" || o == "synth" || SoundPalette.synthName(o) != nil
                || SoundPalette.pickedName(o) != nil, "\(p.id) \(role): \(o) plays nothing")
          }
        }
      }
      report.append("\(p.id): plays here")
    }
    print("palettes on this Mac:\n  " + report.joined(separator: "\n  "))
    // with nothing installed a sampled palette says so, and a synth one still plays
    let empty = emptyScratchDir()
    let jazz = try #require(SoundPalette.named("jazz"))
    #expect(jazz.unavailableReason(dir: empty)?.contains("not installed") == true)
    #expect(SoundPalette.named("synthwave")?.isPlayable(dir: empty) == true)
    #expect(SoundPalette.named("synth")?.isPlayable(dir: empty) == true)
  }

  /// A pick is a pure function of the track seed and the role: the same every time, different
  /// across seeds, and each role picks on its own.
  @Test func picksAreDeterministicFromSeedAndRole() throws {
    let p = try #require(SoundPalette.named("synthwave"))
    var melodies: Set<String> = []
    for seed in 1...40 {
      let a = p.pick(role: "melody", key: "melody", seed: Double(seed))
      #expect(a == p.pick(role: "melody", key: "melody", seed: Double(seed)))
      melodies.insert(a ?? "")
    }
    #expect(melodies.count > 2, "seeds pick different leads: \(melodies)")
    // the composed project resolves the same way twice, and differently for another seed
    func picks(_ seed: Double) -> [String] {
      let pr = TrackSpec(genre: "house", seed: seed, structure: "standard").withPalette(
        "synthwave"
      ).project()
      return pr.nets.keys.sorted().compactMap { pr.nets[$0]?.track.sound.option }
    }
    #expect(picks(11) == picks(11) && !picks(11).isEmpty)
    #expect((1...12).map { picks(Double($0)) }.contains { $0 != picks(11) })
    // a synth option voices that instrument (the composer's is kept to restore)
    let pr = TrackSpec(genre: "house", seed: 11, structure: "standard").withPalette("synthwave")
      .project()
    let melody = try #require(pr.soundNet("melody"))
    let opt = try #require(melody.track.sound.option)
    #expect(SoundPalette.synthName(opt) == melody.track.instrument, "\(opt)")
    #expect(melody.track.sound.composed != nil)
  }

  /// Studio is the default: written as none, so a track keeps its share and plays as before.
  @Test func studioIsNoPaletteAtAll() {
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard")
    #expect(SoundPalette.normalized("studio") == nil && SoundPalette.normalized(nil) == nil)
    #expect(spec.withPalette("studio") == spec)
    #expect(spec.withPalette("jazz").withPalette("studio").palette == nil)
    #expect(spec.withPalette("jazz").palette == "jazz")
  }

  /// The Synth palette is beats' own synth voices: bit for bit what the deck plays with no
  /// sampler at all.
  @Test func theSynthPaletteIsTheSynthRender() {
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard")
    let synth = renderSpec(spec.withPalette("synth"), seconds: 6)
    let plain = renderSpec(spec, seconds: 6, sampled: false)
    #expect(synth.left == plain.left && synth.right == plain.right)
    #expect(synth.left.contains { $0 != 0 })
  }

  /// Every palette that plays here lands within a few dB of the Synth palette (integrated
  /// loudness over the busiest section): samplers are level-matched on load, synth voices
  /// within 3 dB of the lead, kits matched to the synth kit, and the mix is balanced after.
  @Test func everyPaletteSitsAtTheSynthPalettesLevel() throws {
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard")
    let start = Loudness.busiestStart(spec.project())
    func lufs(_ id: String) -> Double {
      let r = renderSpec(spec.withPalette(id), seconds: 10, startTick: start)
      return IntegratedLoudness.lufs(left: r.left, right: r.right, sampleRate: 24_000)
    }
    let reference = lufs("synth")
    #expect(reference > -30 && reference < -10, "\(reference)")
    var levels: [String] = []
    for p in SoundPalette.all where p.isPlayable() && p.id != "synth" {
      let l = lufs(p.id)
      levels.append("\(p.id) \(l)")
      #expect(abs(l - reference) < 4, "\(p.id): \(l) LUFS against synth \(reference)")
    }
    print("palette levels (synth \(reference) LUFS): \(levels.joined(separator: ", "))")
  }

  @Test func theLoudnessMeterReadsASineAsBS1770Does() {
    // a 997 Hz sine at −20 dBFS on both channels reads −20 + 3 (two channels) − 0.69 ≈ −17.7
    let sr = 48_000.0
    let x = sineWave(997, rmsDB: -20, seconds: 3, sampleRate: sr)
    let l = IntegratedLoudness.lufs(left: x, right: x, sampleRate: sr)
    #expect(abs(l - -17.0) < 0.3, "\(l)")
    #expect(IntegratedLoudness.lufs(left: [0], right: [0], sampleRate: sr) == -200)
  }
}

struct PaletteDeckTests {
  func deck(_ palette: String? = "jazz") throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 24_000)
    dj.deterministic = true
    let d = try #require(dj["A"])
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard").withPalette(palette)
    d.loadNet(PreparedTrack(spec: spec, sampleRate: d.wave.sampleRate, opts: d.waveOptions))
    return (dj, d)
  }

  /// An override survives a re-generate, Next, the seed wheel and Wander's swaps, and the
  /// reset puts the palette's own pick back.
  @Test func overridesSurviveRecomputesUntilReset() throws {
    let (dj, d) = try deck()
    #expect(SoundPalette.named(d.palette)?.id == "jazz")
    let pick = try #require(d.roleSounds.first { $0.role == "melody" })
    #expect(pick.override == nil && !pick.isOverridden)
    let other = try #require(pick.choices.first { !$0.selected && $0.unavailable == nil })
    dj.perform(.setRoleVoice(deck: "A", role: "melody", voice: other.option))
    let row = try #require(d.roleSounds.first { $0.role == "melody" })
    #expect(row.override == other.option && row.isOverridden)
    #expect(row.choices.first(where: \.selected)?.option == other.option)
    #expect(sourceNames(d.netSource, "voice", other.option))
    let melodyNet = try #require(d.netProject?.soundNet("melody"))
    #expect(melodyNet.track.sound.option == other.option)
    // Next / auto-next: the next version keeps the palette and the override
    let spec = try #require(d.currentSpec)
    let next = spec.nextVersion
    #expect(next.seed != spec.seed && next.palette == spec.palette)
    #expect(next.project().soundNet("melody")?.track.sound.option == other.option)
    // the seed wheel
    d.stepSeed(3)
    #expect(d.currentSpec?.seed == spec.seed + 3)
    #expect(d.netProject?.soundNet("melody")?.track.sound.option == other.option)
    #expect(SoundPalette.named(d.palette)?.id == "jazz")
    // Wander: every swap it plans carries it (a palette hop changes the palette, not this)
    let c = try #require(d.wanderContext(lockedActions: []))
    var swaps = 0
    for step in 0..<300 where swaps < 8 {
      guard let p = Wander.plan(c, step: step), case .swap(let s) = p.action else { continue }
      swaps += 1
      #expect(sourceNames(.net(s), "voice", other.option), "\(p.detail)")
      if p.kind != .palette { #expect(SoundPalette.named(s.palette)?.id == "jazz", "\(p.detail)") }
    }
    #expect(swaps == 8)
    // reset to the palette
    dj.perform(.setRoleVoice(deck: "A", role: "melody", voice: nil))
    let back = try #require(d.roleSounds.first { $0.role == "melody" })
    #expect(back.override == nil && !back.isOverridden)
    #expect(!sourceNames(d.netSource, "voice", other.option))
    let again = try #require(d.netProject?.soundNet("melody"))
    let expected = SoundPalette.named("jazz")?.pick(
      role: "melody", key: "melody", seed: d.voicingSeed)
    #expect(again.track.sound.option == expected)
  }

  /// An instrument chosen in fine-tune (`inst:`) plays as a pick, survives Next, and resets.
  @Test func anInstrumentPickIsAnOverrideToo() throws {
    let (dj, d) = try deck("synthwave")
    dj.perform(.setRoleVoice(deck: "A", role: "bass", voice: "inst:acid"))
    let bass = try #require(d.netProject?.soundNet("bass"))
    #expect(bass.track.instrument == "acid" && bass.track.picked)
    #expect(d.roleSounds.first { $0.role == "bass" }?.isOverridden == true)
    let next = try #require(d.currentSpec?.nextVersion).project()
    #expect(next.soundNet("bass")?.track.instrument == "acid")
    dj.perform(.setRoleVoice(deck: "A", role: "bass", voice: nil))
    let b = try #require(d.netProject?.soundNet("bass"))
    #expect(!b.track.picked && b.track.sound.override == nil)
    #expect(
      b.track.sound.option
        == SoundPalette.named("synthwave")?.pick(role: "bass", key: "bass", seed: d.voicingSeed))
  }

  /// The palette changes on the same song at the next bar, keeps the user's overrides, and
  /// the default clears it from the share.
  @Test func setPaletteKeepsOverridesAndTheDefaultClearsIt() throws {
    let (dj, d) = try deck("lofi")
    dj.perform(.setRoleVoice(deck: "A", role: "bass", voice: "gm:32"))
    dj.perform(.setPalette(deck: "A", palette: "club"))
    #expect(SoundPalette.named(d.palette)?.id == "club")
    #expect(d.netProject?.soundNet("bass")?.track.sound.option == "gm:32")
    #expect(d.roleSounds.first { $0.role == "melody" }?.choices.first?.option == "synth:rave-stab")
    dj.perform(.setPalette(deck: "A", palette: "studio"))
    #expect(d.palette == nil)
    #expect(!specHas(try #require(d.currentSpec), "palette"))
    #expect(sourceNames(d.netSource, "voice", "gm:32"), "the override stays")
  }

  /// The drums: the palette's kit plays unless a kit is picked; reset clears the pick.
  @Test func theDrumsFollowThePaletteUntilAKitIsPicked() throws {
    let (dj, d) = try deck("club")
    let kit = try #require(d.roleSounds.first { $0.role == "kit" })
    #expect(!kit.isOverridden && kit.option != nil)
    dj.perform(.setKit(deck: "A", kit: "MuseScore_General.sf2#128:32"))
    #expect(d.roleSounds.first { $0.role == "kit" }?.kitPick == "MuseScore_General.sf2#128:32")
    #expect(d.roleSounds.first { $0.role == "kit" }?.isOverridden == true)
    #expect(d.currentSpec?.nextVersion.project().drumKit == "MuseScore_General.sf2#128:32")
    dj.perform(.setRoleVoice(deck: "A", role: "kit", voice: nil))
    #expect(d.kit == nil && d.roleSounds.first { $0.role == "kit" }?.isOverridden == false)
  }

  @Test func theNewActionRoundTrips() {
    for a in [
      DeckAction.setRoleVoice(deck: "A", role: "melody", voice: "gm:4"),
      .setRoleVoice(deck: "B", role: "kit", voice: "synth:drums-808"),
      .setRoleVoice(deck: "A", role: "bass", voice: nil),
    ] {
      #expect(DeckAction(json: a.json) == a)
    }
    #expect(DeckAction(json: DeckAction.setPalette(deck: "A", palette: "jazz").json) != nil)
  }

  /// A replayed session lands on the same sound: the pokes are recorded, the picks derived.
  @Test func aReplayPlaysTheSameSound() throws {
    let (dj, d) = try deck("ambient")
    let rec = try SessionRecorder.start(on: dj)
    dj.perform(.setPalette(deck: "A", palette: "orchestral"))
    dj.perform(.setRoleVoice(deck: "A", role: "harmony", voice: "gm:48"))
    let session = rec.finish()
    #expect(session.events.count == 2)
    let (dj2, d2) = try deck("ambient")
    for e in session.events { if case .action(let a) = e.kind { dj2.perform(a) } }
    #expect(d2.netSource == d.netSource)
    #expect(d2.roleSounds == d.roleSounds)
  }
}

struct PaletteWanderTests {
  func context(locks: Set<String> = [], palette: String? = "jazz") -> WanderContext {
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard").withPalette(palette)
    let roles = ["kick", "snare", "hihat", "bass", "melody", "harmony"]
    let voices = [
      WanderVoice(
        roles: ["bass"], channel: 6, instrument: "bass", options: ["bass", "acid"],
        option: "gm:32"),
      WanderVoice(
        roles: ["melody"], channel: 4, instrument: "lead", options: ["lead", "pluck"],
        option: "gm:66"),
    ]
    return WanderContext(
      deck: "A", spec: spec, isLoop: false, roles: roles, rolesOn: Set(roles), disabledRoles: [],
      stemsMuted: [], lockedActions: [], locks: locks, voices: voices, anchorBPM: nil, key: nil,
      palette: palette, channels: [4, 6, 7, 10, 11, 12, 13])
  }

  func hops(_ c: WanderContext, steps: Int = 3000) -> [WanderPlan] {
    (0..<steps).compactMap { Wander.plan(c, step: $0) }.filter { $0.kind == .palette }
  }

  /// Rare, to a neighbour only, and never under the palette or instruments lock.
  @Test func aPaletteHopGoesToANeighbourAndRespectsLocks() throws {
    let free = hops(context())
    #expect(!free.isEmpty && free.count < 150, "rare: \(free.count) in 3000")
    let neighbours = Set(try #require(SoundPalette.named("jazz")).neighbours)
    for h in free {
      guard case .swap(let s) = h.action else {
        Issue.record("a hop swaps")
        continue
      }
      let to = try #require(SoundPalette.named(s.palette)?.id ?? "studio")
      #expect(neighbours.contains(to), "\(h.detail)")
      #expect(s.seed == 11 && s.genre == "house", "the same song")
    }
    #expect(hops(context(locks: ["palette"])).isEmpty)
    #expect(hops(context(locks: ["instruments"])).isEmpty)
    #expect(WanderMoveKind.palette.weight > 0 && WanderMoveKind.palette.weight <= 3)
    #expect(WanderMoveKind.allCases.reduce(0) { $0 + $1.weight } == 100)
  }

  /// A kept role keeps the sound it plays through a hop; the default palette hops too.
  @Test func aKeptRoleRidesThroughAHop() throws {
    let c = context(locks: [WanderLock.keep("melody")])
    let h = try #require(hops(c).first)
    guard case .swap(let s) = h.action else { throw KitTestError.notNet }
    #expect(sourceNames(.net(s), "voice", "gm:66"))
    #expect(!sourceNames(.net(s), "voice", "gm:32"), "only the kept role")
    #expect(!hops(context(palette: nil)).isEmpty, "from Studio too")
  }

  /// Every other swap keeps the deck's palette.
  @Test func swapsCarryThePalette() throws {
    var n = 0
    for step in 0..<400 {
      guard let p = Wander.plan(context(locks: ["palette"]), step: step),
        case .swap(let s) = p.action
      else { continue }
      n += 1
      #expect(SoundPalette.named(s.palette)?.id == "jazz", "\(p.detail)")
    }
    #expect(n > 10)
  }
}

struct PalettePublishTests {
  func session(_ d: DeckSourceDescriptor, events: [SessionEvent] = []) -> Session {
    Session(
      sampleRate: 48_000, frames: 48_000, decks: ["A": d], params: ["A": DeckParams()],
      crossfader: 0.5, master: 0.8, events: events)
  }

  /// Local-only content (Apple's GM bank, the Minecraft bank) is refused however it gets in —
  /// a palette, a role's option, a kit — and anything else publishes.
  @Test func publishRefusesEveryLocalOnlySource() throws {
    let spec = TrackSpec(genre: "house", seed: 3, structure: "minimal")
    for id in ["jazz", "synthwave", "orchestral", "studio"] {
      let s = session(.net(spec.withPalette(id)))
      #expect(s.localOnlySounds.isEmpty, "\(id): \(s.localOnlySounds)")
    }
    #expect(SoundPalette.named("retro")?.isLocalOnly == true)
    #expect(SoundPalette.named("minecraft")?.isLocalOnly == true)
    #expect(SoundPalette.named("jazz")?.isLocalOnly == false)
    let refused = [
      session(.net(spec.withPalette("retro"))),
      session(
        .net(spec),
        events: [SessionEvent(frame: 1, kind: .action(.setPalette(deck: "A", palette: "retro")))]
      ),
      session(
        .net(spec),
        events: [
          SessionEvent(
            frame: 1, kind: .action(.setRoleVoice(deck: "A", role: "melody", voice: "dls:0")))
        ]),
      session(
        .net(spec),
        events: [
          SessionEvent(frame: 1, kind: .action(.setKit(deck: "A", kit: "gs_instruments.dls#128:0")))
        ]),
    ]
    for s in refused {
      #expect(!s.localOnlySounds.isEmpty)
      #expect(throws: PublishError.self) { try SessionBundle(session: s, renderedAt: "x") }
      _ = try SessionBundle(session: s, renderedAt: "x", allowLocalOnly: true)
    }
    let fine = session(
      .net(spec),
      events: [
        SessionEvent(
          frame: 1, kind: .action(.setRoleVoice(deck: "A", role: "melody", voice: "gm:0")))
      ])
    #expect(fine.localOnlySounds.isEmpty)
  }
}

/// What the chooser and the fine-tune area show (DJCore models).
struct PaletteChooserModelTests {
  @Test func theCardsLightTheCurrentPaletteAndGreyTheMissing() {
    let cards = PaletteCard.cards(current: nil)
    #expect(cards.count == SoundPalette.all.count)
    #expect(cards.filter(\.selected).map(\.id) == ["studio"])
    #expect(PaletteCard.cards(current: "lofi").filter(\.selected).map(\.id) == ["lofi"])
    #expect(PaletteCard.cards(current: "minecraft@32").first { $0.selected }?.id == "minecraft")
    let missing = PaletteCard.cards(current: nil, unavailable: ["jazz": "no bass"])
    #expect(missing.first { $0.id == "jazz" }?.unavailable == "no bass")
    #expect(missing.first { $0.id == "club" }?.unavailable == nil)
    #expect(cards.first { $0.id == "retro" }?.localOnly == true)
  }

  @Test func theFineTuneRowsShowWhatThePalettePicked() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 24_000)
    dj.deterministic = true
    let d = try #require(dj["A"])
    #expect(d.roleSounds.isEmpty, "nothing on the deck")
    let spec = TrackSpec(genre: "house", seed: 11, structure: "standard").withPalette("synthwave")
    d.loadNet(PreparedTrack(spec: spec, sampleRate: 24_000, opts: d.waveOptions))
    let rows = d.roleSounds
    #expect(rows.map(\.role).first == "kit")
    #expect(Set(rows.map(\.role)).isSuperset(of: ["kit", "bass", "melody"]))
    let p = try #require(SoundPalette.named("synthwave"))
    for r in rows {
      #expect(r.choices.filter(\.selected).count == 1, "\(r.role)")
      #expect(Array(r.choices.prefix(p.pool(r.role)?.count ?? 0).map(\.option)) == p.pool(r.role))
      #expect(r.choices.contains { $0.option == "synth" }, "beats' own voice is always there")
      #expect(!r.playing.isEmpty && !r.isOverridden)
    }
    let melody = try #require(rows.first { $0.role == "melody" })
    #expect(melody.playing == SoundPalette.synthName(melody.option ?? "") ?? "")
  }
}
