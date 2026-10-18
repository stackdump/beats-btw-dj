import Testing

@testable import DJCore

/// Sampled drum kits (`DrumKits`, `SamplerSource.kit`): a track's drum lanes on a sound bank's
/// kit instead of beats' synth kit, chosen per track (`Track.kit`, a `tracks` override, the
/// poke `DeckAction.setKit`). Tests that play a bank skip when it is not installed.
struct SampledKitTests {
  let sr = 48_000.0

  @Test func kitIdsParse() {
    #expect(DrumKits.parse("MuseScore_General.sf2#128:0")! == ("MuseScore_General.sf2", 128, 0))
    #expect(DrumKits.parse("minecraft-local.sf2#0:127")! == ("minecraft-local.sf2", 0, 127))
    for bad in ["", "x.sf2", "x.sf2#", "x.sf2#1", "x.sf2#a:b", "../x.sf2#128:0", "x.sf2#129:0"] {
      #expect(DrumKits.parse(bad) == nil, "\(bad)")
    }
    #expect(DrumKits.source(for: "nowhere.sf2#128:0") == nil)
  }

  @Test func drumLanesPlayTheirGMKeys() {
    let keys = ["kick", "snare", "clap", "hat", "openhat", "crash"].map(DrumKits.gmNote)
    #expect(keys == [36, 38, 39, 42, 46, 49])
    // every kind beats' drum map makes comes back to its own key
    for note in [35, 36, 37, 38, 39, 40, 42, 44, 46] {
      let k = DrumKits.gmNote(kind: drumKind(note))
      #expect(drumKind(k) == drumKind(note), "\(note)")
    }
  }

  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func soundFontKitsAreListed() throws {
    let kits = DrumKits.scan(banks: [try #require(floorBank)])
    #expect(kits.count >= 8, "\(kits.map(\.label))")
    #expect(kits.contains { $0.id == floorKit })
    #expect(kits.allSatisfy { if case .kit(_, 128, _) = $0.source { true } else { false } })
    #expect(DrumKits.source(for: floorKit) == kits.first { $0.id == floorKit }?.source)
  }

  @Test(.enabled(if: appleBank != nil, "no gs_instruments.dls"))
  func appleGMKitsAreListed() throws {
    let kits = DrumKits.scan(banks: [try #require(appleBank)])
    #expect(!kits.isEmpty)
    #expect(kits.contains { $0.id == "gs_instruments.dls#128:0" }, "\(kits.map(\.label))")
    let b = SamplerBank(sampleRate: sr)
    let s = try #require(DrumKits.source(for: "gs_instruments.dls#128:0"))
    let slot = b.slot(for: [s])
    #expect(slot != nil, "Apple's standard kit loads: \(b.loadFailure(for: s) ?? "")")
    if let slot { b.release(slot) }
  }

  /// `kitTargetRMSdB` is where beats' synth kit sits on the kit phrase, as a runner plays it
  /// (synth lanes through the master, samplers beside it).
  @Test func theSynthKitSetsTheKitTarget() {
    let synth = renderRunner(kitPhraseProject(), opts: kitOptions(nil), sampleRate: sr, seconds: 2)
    let db = rmsDB(synth[...])
    #expect(abs(db - SamplerInstrument.kitTargetRMSdB) < 1, "synth kit \(db) dB")
  }

  /// A sampled kit sits where the synth kit did: the whole phrase within 1.5 dB of it, the
  /// kick within 6 dB of the synth kick and the loudest part, and the kick / snare gap near
  /// `MixBalance`'s (kick 0, snare −6: within 4 dB). (beats' synth snare sits 17 dB under its
  /// kick, which `.balance` trims; a sampled kit is mixed already, and is not trimmed.)
  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func aSampledKitSitsWhereTheSynthKitDid() throws {
    try expectKitLevels(floorKit)
  }

  @Test(.enabled(if: appleBank != nil, "no gs_instruments.dls"))
  func applesKitSitsWhereTheSynthKitDid() throws {
    try expectKitLevels("gs_instruments.dls#128:0")
  }

  func expectKitLevels(_ kit: String) throws {
    let bank = SamplerBank(sampleRate: sr)
    let o = kitOptions(bank)
    let prepared = WaveRunner.prepare(kitPhraseProject(kit: kit), sampleRate: sr, opts: o)
    #expect(prepared.lanes.contains { $0.samplerSlot >= 0 }, "\(kit) loads")
    func level(_ only: Int?, _ kitted: Bool) -> Double {
      let p = kitPhraseProject(only: only, kit: kitted ? kit : nil)
      let opts = kitted ? o : kitOptions(nil)
      return rmsDB(renderRunner(p, opts: opts, sampleRate: sr, seconds: 2)[...])
    }
    let whole = (level(nil, true), level(nil, false))
    #expect(abs(whole.0 - whole.1) < 1.5, "\(kit): whole \(whole.0) vs synth \(whole.1)")
    let kick = (level(36, true), level(36, false))
    let snare = level(38, true)
    let hat = level(42, true)
    #expect(abs(kick.0 - kick.1) < 6, "\(kit) kick \(kick.0) vs synth \(kick.1)")
    #expect(kick.0 > snare && kick.0 > hat, "\(kit): kick \(kick.0) snare \(snare) hat \(hat)")
    let gap = kick.0 - snare
    let target = MixBalance.targetDB["kick"]! - MixBalance.targetDB["snare"]!
    #expect(abs(gap - target) < 4, "\(kit): kick − snare \(gap) dB")
    print("kit \(kit): whole \(whole.0) (synth \(whole.1)) kick \(kick) snare \(snare) hat \(hat)")
  }

  /// A whole track on a sampled kit plays as loud as on the synth kit (the loudness and
  /// balance passes still hold it: the kit moves with the kick's `.balance` trim): within 3 dB
  /// RMS, and it does not clip.
  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func aTrackOnAKitKeepsItsLoudness() throws {
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "minimal")
    func render(_ kit: String?) throws -> AudioMetrics {
      let src = WaveDeckSource(sampleRate: sr, opts: .extended)
      var s = spec
      if let kit,
        case .net(let k)? = DeckSourceDescriptor.net(spec).withKit(
          kit, channels: spec.project().drumChannels)
      {
        s = k
      }
      let track = PreparedTrack(spec: s, sampleRate: sr, opts: .extended(samplers: src.samplers))
      return OfflineRender(track: track, source: src, seconds: 12).metrics
    }
    let synth = try render(nil)
    let kit = try render(floorKit)
    #expect(abs(kit.rmsDB - synth.rmsDB) < 3, "kit \(kit.rmsDB) vs synth \(synth.rmsDB) dB")
    #expect(kit.peakDB < 0, "kit peak \(kit.peakDB) dB")
  }

  /// The parity path never samples drums: without the deck's bank and the instrument table a
  /// kit pick renders beats' synth kit, bit for bit.
  @Test func theParityPathKeepsTheSynthKit() {
    var o = WaveOptions()
    o.master = "linear"
    let plain = renderRunner(kitPhraseProject(), opts: o, sampleRate: sr, seconds: 1)
    let picked = renderRunner(kitPhraseProject(kit: floorKit), opts: o, sampleRate: sr, seconds: 1)
    #expect(sameSamples(plain, picked) == .identical)
    var x = WaveOptions.extended
    x.master = "linear"
    #expect(
      sameSamples(
        renderRunner(kitPhraseProject(), opts: x, sampleRate: sr, seconds: 1),
        renderRunner(kitPhraseProject(kit: floorKit), opts: x, sampleRate: sr, seconds: 1))
        == .identical)
  }

  /// A kit pick is the share's `tracks` override on every drum channel: the composed project's
  /// drum nets carry it, nothing else does, and clearing it leaves no trace.
  @Test func aKitIsATracksOverride() throws {
    let spec = TrackSpec(genre: "techno", seed: 7, structure: "minimal")
    let project = spec.project()
    let channels = project.drumChannels
    #expect(!channels.isEmpty && channels.allSatisfy(isDrumChannel))
    let picked = try #require(DeckSourceDescriptor.net(spec).withKit(floorKit, channels: channels))
    guard case .net(let s2) = picked else { throw KitTestError.notNet }
    let p2 = s2.project()
    #expect(p2.drumKit == floorKit)
    for id in p2.nets.keys {
      let nb = p2.nets[id]!
      guard nb.role != "control" else { continue }
      #expect((nb.track.kit != nil) == isDrumChannel(nb.track.channel), "\(id)")
    }
    // the same compose: notes and instruments are beats'
    #expect(p2.nets.keys == project.nets.keys)
    let cleared = try #require(picked.withKit(nil, channels: channels))
    #expect(cleared == .net(spec))
  }

  @Test func setKitRoundTrips() {
    for a in [DeckAction.setKit(deck: "A", kit: floorKit), .setKit(deck: "B", kit: nil)] {
      #expect(DeckAction(json: a.json) == a)
    }
  }

  /// On a deck: the poke lands at the next bar on the same song, the drums move to the kit's
  /// slot, the source carries the kit, and a replay of the session does the same.
  @Test(.enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func aDeckSwapsKitsAtTheNextBar() throws {
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
    #expect(deck.kit == nil)
    #expect(!deck.wave.sampledNets.keys.contains { $0.hasPrefix("kick") })
    let before = deck.wave.tick
    dj.perform(.setKit(deck: "A", kit: floorKit))
    #expect(deck.kit == floorKit)
    #expect(deck.netSource.map(sourceHasKit) == true)
    pullEngine(dj, buf, cycles: 200, frames: 512)
    #expect(deck.wave.tick > before, "the song carried on")
    #expect(
      deck.wave.sampledNets.keys.contains { $0.hasPrefix("kick") }, "\(deck.wave.sampledNets)")
    #expect(deck.wave.sampledNets.values.contains { $0.hasPrefix("kit:") })
    dj.perform(.setKit(deck: "A", kit: nil))
    pullEngine(dj, buf, cycles: 200, frames: 512)
    #expect(deck.kit == nil)
    #expect(!deck.wave.sampledNets.values.contains { $0.hasPrefix("kit:") })
  }
}

enum KitTestError: Error { case notNet }

/// Does a source's `tracks` override name a kit?
func sourceHasKit(_ d: DeckSourceDescriptor) -> Bool {
  guard case .net(let spec) = d, let tracks = spec.layers["tracks"]?.object else { return false }
  return tracks.entries.contains { $0.value["kit"]?.string != nil }
}
