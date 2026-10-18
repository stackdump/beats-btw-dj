import Testing

@testable import DJCore

// The sound panel (long press on an instrument): a channel's voice shaped live, on the song
// playing, with no reload; session-only; saved variations in their own library.

private let sr = 22_050.0

private func song(_ genre: String = "techno", _ seed: Double = 42) -> Project {
  TrackSpec(genre: genre, seed: seed, structure: "minimal").project()
}

/// The MIDI channel of the first non-control net of `group`.
private func channel(_ p: Project, _ group: String) -> Int? {
  p.nets.values.first { $0.role != "control" && $0.track.group == group }?.track.channel
}

private func source(_ p: Project, opts: WaveOptions = .extended) -> WaveDeckSource {
  let src = WaveDeckSource(sampleRate: sr)
  var o = opts
  if o.samplers != nil { o.samplers = src.samplers }
  src.load(WaveRunner.prepare(p, sampleRate: sr, opts: o))
  src.setTempo(300)
  return src
}

private func render(_ src: WaveDeckSource, blocks: Int, each: (() -> Void)? = nil) -> [Float] {
  var out: [Float] = []
  var l = [Float](repeating: 0, count: 256)
  for _ in 0..<blocks {
    l.withUnsafeMutableBufferPointer { src.render(frames: 256, left: $0.baseAddress!, right: nil) }
    out += l
    each?()
  }
  return out
}

private func lanes(_ src: WaveDeckSource, _ ch: Int? = nil) -> [[Double]] {
  (src.latest?.lanes ?? []).filter { ch == nil || $0.channel == ch }.map(\.voiceState)
}

private let shaped = VoiceTweak(
  gainDB: 9, attack: 0.04, decayScale: 2, maxDecay: 3, lowpass: 900, distortion: 0.4,
  vibratoRate: 6, vibratoDepth: 0.02, pitchFrom: 3, pitchTo: 1, pitchTime: 0.15)

struct VoiceTweakEngineTests {
  @Test func aTweakChangesThatChannelAtOnceWithoutAReload() throws {
    let p = song()
    let ch = try #require(channel(p, "melody"))
    let a = source(p)
    let b = source(p)
    a.play()
    b.play()
    #expect(render(a, blocks: 150) == render(b, blocks: 150), "the same song, the same audio")
    let gen = b.activeGeneration
    let tick = b.tick
    #expect(b.setVoice(channel: ch, tweak: shaped, useSynth: false))
    let ra = render(a, blocks: 400)
    let rb = render(b, blocks: 400)
    #expect(ra != rb, "the tweak is heard")
    #expect(b.tick > tick && b.tick == a.tick, "the song kept going: no restart")
    #expect(b.activeGeneration == gen, "the same project: no reload")
    // the lanes on that channel changed, every other lane is as it was
    #expect(lanes(a, ch) != lanes(b, ch))
    let others = { (s: WaveDeckSource) in
      (s.latest?.lanes ?? []).filter { $0.channel != ch }.map(\.voiceState)
    }
    #expect(others(a) == others(b))
    // and the swept saw reads its band-limited tables
    let swept = (b.latest?.lanes ?? []).filter { $0.channel == ch && $0.isTonal && !$0.isPluck }
    #expect(!swept.isEmpty && swept.allSatisfy(\.pmOn))
    let tables = swept.filter { !$0.mip.isEmpty }
    #expect(tables.allSatisfy { $0.mipOn })
  }

  @Test func onlyThatChannelIsHeardToChange() throws {
    // with the tweaked channel's lanes silenced on both (its level 0: a section's control nets
    // would unmute muted nets), the two decks stay identical
    let p = song()
    let ch = try #require(channel(p, "melody"))
    let a = source(p)
    let b = source(p)
    for s in [a, b] {
      for lane in s.latest!.lanes where lane.channel == ch {
        lane.baseLevel = 0
        lane.setVoice(
          VoiceLaneParams(
            channel: ch, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr))
      }
      s.play()
    }
    _ = render(a, blocks: 50)
    _ = render(b, blocks: 50)
    b.setVoice(channel: ch, tweak: shaped, useSynth: false)
    let ra = render(a, blocks: 300)
    #expect(ra == render(b, blocks: 300))
    #expect(ra.contains { $0 != 0 }, "the rest of the song plays")
  }

  @Test func resetRestoresTheInstrumentsVoiceBitExactly() throws {
    let p = song()
    let ch = try #require(channel(p, "melody"))
    let bass = try #require(channel(p, "bass"))
    let a = source(p)
    let b = source(p)
    a.play()
    b.play()
    _ = render(a, blocks: 100)
    _ = render(b, blocks: 100)
    b.setVoice(channel: ch, tweak: shaped, useSynth: false)
    b.setVoice(channel: bass, tweak: VoiceTweak(gainDB: -6, lowpass: 300), useSynth: false)
    _ = render(b, blocks: 100)
    #expect(lanes(a) != lanes(b))
    b.setVoice(channel: ch, tweak: VoiceTweak(), useSynth: false)
    b.setVoice(channel: bass, tweak: VoiceTweak(), useSynth: false)
    _ = render(b, blocks: 1)
    #expect(lanes(a) == lanes(b), "every lane back to its prepared values, bit for bit")
    #expect(b.voiceSettings.isEmpty, "a reset leaves nothing to carry")
    // tweaked and reset before the song starts: the very same audio
    let c = source(p)
    let d = source(p)
    d.setVoice(channel: ch, tweak: shaped, useSynth: false)
    _ = render(d, blocks: 1)
    d.setVoice(channel: ch, tweak: VoiceTweak(), useSynth: false)
    c.play()
    d.play()
    #expect(render(c, blocks: 300) == render(d, blocks: 300))
  }

  @Test func useSynthVoicePlaysASampledChannelsSynthVoiceAndBack() throws {
    let p = song("country", 7)
    let a = source(p, opts: .extended(samplers: SamplerBank(sampleRate: sr)))
    let b = source(p, opts: .extended(samplers: SamplerBank(sampleRate: sr)))
    let sampled = try #require(
      b.latest?.lanes.first { $0.sampledSlot >= 0 && $0.channel >= 0 }, "a sampled channel")
    let ch = sampled.channel
    #expect(b.latest?.channelVoice(ch)?.sampled == true)
    a.play()
    b.play()
    _ = render(a, blocks: 40)
    _ = render(b, blocks: 40)
    #expect(b.setVoice(channel: ch, tweak: VoiceTweak(), useSynth: true))
    var synthSounded = false
    let onChannel = (b.latest?.lanes ?? []).filter { $0.channel == ch }
    _ = render(b, blocks: 600) {
      if onChannel.contains(where: { $0.samplerSlot < 0 && $0.active && $0.isTonal }) {
        synthSounded = true
      }
    }
    _ = render(a, blocks: 600)
    #expect(onChannel.filter { $0.sampledSlot >= 0 }.allSatisfy { $0.samplerSlot == -1 })
    #expect(synthSounded, "the channel's synth voice plays its notes")
    #expect(b.voiceSettings[ch]?.useSynth == true)
    // and back to the sample
    b.setVoice(channel: ch, tweak: VoiceTweak(), useSynth: false)
    _ = render(b, blocks: 1)
    #expect(onChannel.allSatisfy { $0.samplerSlot == $0.sampledSlot })
    #expect(lanes(a, ch) == lanes(b, ch))
  }
}

@MainActor
struct VoiceTweakDeckTests {
  /// A deck with a composed song on it, replay-mode (everything inline).
  private func deck() throws -> (DJEngine, Deck, TrackSpec) {
    let dj = try DJEngine(offline: true, sampleRate: sr)
    dj.deterministic = true
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "minimal")
    dj.perform(.load(deck: "A", source: .net(spec)))
    return (dj, dj["A"]!, spec)
  }

  private func step(_ d: Deck, _ blocks: Int = 1) { _ = render(d.wave, blocks: blocks) }

  @Test func tweaksAreDeckActionsAndSurviveARecompileOfTheSong() throws {
    let (dj, d, _) = try deck()
    let melody = try #require(d.roleVoices.first { $0.role.contains("melody") })
    let ch = melody.channel
    dj.perform(.voiceTweak(deck: "A", channel: ch, params: shaped))
    #expect(d.voiceTweak(ch) == shaped)
    #expect(d.voiceSetting(ch)?.instrument == melody.instrument)
    step(d)
    let tweaked = lanes(d.wave, ch)
    let gen = d.wave.latest!.generation
    // a section jump / relocation prepares the song again: the new project carries the tweak
    d.relocate(toTick: 64)
    #expect(d.wave.latest!.generation != gen, "a new project")
    #expect(lanes(d.wave, ch) == tweaked)
    #expect(d.voiceTweak(ch) == shaped)
    dj.perform(.voiceSynth(deck: "A", channel: ch, on: true))
    #expect(d.usesSynthVoice(ch) && d.voiceTweak(ch) == shaped)
    dj.perform(.voiceSynth(deck: "A", channel: ch, on: false))
    // Reset
    dj.perform(.voiceTweak(deck: "A", channel: ch, params: VoiceTweak()))
    #expect(d.voiceSetting(ch) == nil)
  }

  @Test func anotherInstrumentPickKeepsTheOtherChannelsTweaks() throws {
    let (dj, d, _) = try deck()
    let voices = d.roleVoices
    let melody = try #require(voices.first { $0.role.contains("melody") })
    let bass = try #require(voices.first { $0.role.contains("bass") })
    let newBass = try #require(bass.options.first { $0 != bass.instrument })
    dj.perform(.voiceTweak(deck: "A", channel: melody.channel, params: shaped))
    dj.perform(.voiceTweak(deck: "A", channel: bass.channel, params: VoiceTweak(gainDB: -3)))
    step(d)
    let tweaked = lanes(d.wave, melody.channel)
    dj.perform(
      .load(deck: "A", source: d.netSource!.withInstrument(newBass, channel: bass.channel)!))
    #expect(d.voiceTweak(melody.channel) == shaped, "the song's other tweaks stay")
    #expect(lanes(d.wave, melody.channel) == tweaked)
    #expect(d.voiceSetting(bass.channel) == nil, "a new instrument starts from its own voice")
  }

  @Test func aFavoriteReloadOrAnotherSongStartsFromTheInstrumentsOwnVoice() throws {
    let (dj, d, spec) = try deck()
    let ch = try #require(d.roleVoices.first { $0.role.contains("melody") }).channel
    step(d)
    let own = lanes(d.wave, ch)
    dj.perform(.voiceTweak(deck: "A", channel: ch, params: shaped))
    // the same song loaded again (a favorite of it, its share pasted)
    dj.perform(.load(deck: "A", source: d.netSource!))
    #expect(d.voiceSetting(ch) == nil)
    #expect(lanes(d.wave, ch) == own)
    // another song (Generate, auto-next's next version)
    dj.perform(.voiceTweak(deck: "A", channel: ch, params: shaped))
    dj.perform(.load(deck: "A", source: .net(spec.nextVersion)))
    #expect(d.wave.voiceSettings.isEmpty)
  }
}

struct VoiceTweakCodecTests {
  @Test func voiceActionsRoundTrip() {
    let actions: [DeckAction] = [
      .voiceTweak(deck: "A", channel: 3, params: shaped),
      .voiceTweak(deck: "B", channel: 10, params: VoiceTweak(gainDB: -4.5)),
      .voiceTweak(deck: "A", channel: 1, params: VoiceTweak()),
      .voiceSynth(deck: "B", channel: 6, on: true),
      .voiceSynth(deck: "A", channel: 2, on: false),
    ]
    for a in actions {
      #expect(DeckAction(json: a.json) == a, "\(a.json.canonicalJS)")
      #expect(DeckAction(json: try! JSONValue.parse(a.json.canonicalJS)) == a)
      let e = SessionEvent(frame: 1234, kind: .action(a))
      #expect(SessionEvent(json: e.json) == e)
    }
    #expect(
      DeckAction.voiceTweak(deck: "A", channel: 3, params: VoiceTweak(lowpass: 1200)).json
        .canonicalJS
        == #"{"channel":3,"deck":"A","op":"voiceTweak","params":{"lowpass":1200}}"#)
    #expect(DeckAction(json: try! JSONValue.parse(#"{"op":"voiceTweak","deck":"A"}"#)) == nil)
  }

  @Test func aTweakKeepsToItsRanges() throws {
    let t = VoiceTweak(
      json: try JSONValue.parse(
        #"{"attack":-1,"lowpass":10,"distortion":5,"gainDB":100,"bogus":1,"pitchTime":2}"#))
    #expect(t.attack == 0.0005 && t.lowpass == 0 && t.distortion == 1 && t.gainDB == 24)
    #expect(t.pitchTime == 2 && t.decayScale == nil)
    #expect(VoiceTweak(json: t.json) == t)
    #expect(VoiceTweak().isEmpty && !t.isEmpty)
    var u = VoiceTweak()
    u["lowpass"] = 30_000
    #expect(u.lowpass == 20_000)
    u["lowpass"] = nil
    #expect(u.isEmpty)
  }

  @Test func theVoiceItShapes() {
    let base = InstrumentTable.shared.voice(instrument: "laser", group: "melody")
    let v = VoiceTweak(gainDB: 6, lowpass: 2000).applied(to: base)
    #expect(v.lowpass == 2000 && v.attack == base.attack && v.pitchFrom == base.pitchFrom)
    #expect(abs(v.level / base.level - 1.9953) < 1e-3)
    #expect(VoiceTweak().applied(to: base) == base)
  }

  @Test func parametersPutBackWhatTheyDoNotSet() {
    let p = VoiceLaneParams(
      channel: 2, tweak: VoiceTweak(pitchTime: 0.3), useSynth: false,
      voice: InstrumentTable.shared.voice(instrument: "laser", group: "melody"), sampleRate: sr)
    #expect(p.has(VoiceLaneParams.pitch) && !p.has(VoiceLaneParams.level))
    #expect(p.pmOn && p.pitchFrom > p.pitchTo, "a partial sweep fills in from the instrument")
    #expect(
      VoiceLaneParams(channel: 2, tweak: VoiceTweak(), useSynth: false, voice: nil, sampleRate: sr)
        .mask == 0)
  }
}

struct VoiceVariationStoreTests {
  @Test func savesRenamesAndDeletesAnInstrumentsVariations() throws {
    let store = temporaryVoiceVariations()
    #expect(store.all().isEmpty)
    let zap = VoiceVariation(name: "short zap", params: VoiceTweak(pitchTime: 0.08))
    let dark = VoiceVariation(name: " dark ", params: VoiceTweak(lowpass: 600), useSynth: true)
    try store.save(zap, for: "laser")
    try store.save(dark, for: "laser")
    try store.save(VoiceVariation(name: "soft", params: VoiceTweak(gainDB: -6)), for: "pluck")
    #expect(store.list("laser").map(\.name) == ["short zap", "dark"], "in the order saved")
    #expect(store.list("laser")[1].useSynth && store.list("laser")[1].params.lowpass == 600)
    // the same name again replaces it in place
    try store.save(
      VoiceVariation(name: "short zap", params: VoiceTweak(pitchTime: 0.05)), for: "laser")
    #expect(store.list("laser").map(\.name) == ["short zap", "dark"])
    #expect(store.list("laser")[0].params.pitchTime == 0.05)
    // a fresh store over the same file reads it back
    let again = VoiceVariationStore(file: store.file)
    #expect(again.all() == store.all() && again.all().count == 2)
    try store.rename("dark", to: "muffled", for: "laser")
    #expect(store.list("laser").map(\.name) == ["short zap", "muffled"])
    // renaming onto a name in use replaces that one
    try store.rename("muffled", to: "short zap", for: "laser")
    #expect(store.list("laser").map(\.name) == ["short zap"])
    #expect(store.list("laser")[0].params.lowpass == 600)
    try store.delete("short zap", for: "laser")
    #expect(store.list("laser").isEmpty && store.all().keys.sorted() == ["pluck"])
    #expect(zap.label("laser") == "laser · short zap")
  }
}
