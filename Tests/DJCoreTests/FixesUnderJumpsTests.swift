import Testing

@testable import DJCore

// ROADMAP 6.7, the fixes under performance: every musicality pass and runner fix a track plays
// with from its top must still play after a section jump, a skip to the next track and a copy
// onto the other deck. A jump prepares the song again from a tick (`Deck.sameSongOptions`); what
// continuous play has is the project the song was prepared with, so the jumped project is held
// to that one, field by field (`divergences`), and two of them are rendered (`loudness`).
//
// Found this way and fixed in `sameSongOptions`: a jump prepared with no genre (`.extended` has
// none; only `PreparedTrack` ran `forGenre`), so it lost the jazz brushes, the dnb / dubstep /
// trap sub-octave and the HF tilt on the hats, and a song whose `.balance` trims were all zero
// (nil on its project, so not carried) measured them again in the default family.

/// The dance family (every genre beats files there), the chill family, and jazz for the brushes.
private let dance = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "speedcore", "garage", "trap",
]
private let chill = ["lofi", "ambient"]
private let genres = dance + chill + ["jazz"]
private let seed = 42.0

private func spec(_ genre: String, seed: Double = seed) -> TrackSpec {
  TrackSpec(genre: genre, seed: seed, structure: "standard")
}

/// What one lane plays with, beyond the state it runs: where it sits, which voice, which
/// sampled instrument (by name: another deck's bank numbers its slots differently), and every
/// fix's per-lane setting.
private struct LanePrint: Equatable {
  var net: String
  var kind: String
  var channel: Int
  var instrument: String
  var sampler: String?
  var voice: VoiceSpec
  var pan: Double
  var spread: [Double]
  var level: Double
  var kitVelocity: Double
  var tilt: Bool
  var subOctave: Bool
  var pluck: Bool
  var mip: Bool
  var unison: [Double]
  var filter: Double
  var ducks: Bool
  var isKick: Bool
  var send: Double
  var shimmer: Double
  var echo: Double
  var rest: RestSchedule.Class
  var harmonyGroup: Int
  var choke: Double

  init(_ lane: Lane, bank: SamplerBank?) {
    net = lane.netId
    kind = lane.kind
    channel = lane.channel
    instrument = lane.instrument
    sampler =
      lane.samplerSlot >= 0 ? bank?.source(of: lane.samplerSlot).map { "\($0)" } ?? "?" : nil
    voice = lane.voice
    pan = lane.pan
    spread = lane.voiceSpread
    level = lane.baseLevel
    kitVelocity = lane.kitVelocity
    tilt = lane.tiltOn
    subOctave = !lane.subPhase.isEmpty
    pluck = lane.isPluck
    mip = lane.mipOn
    unison = [lane.uniDown, lane.uniUp] + lane.uniWidth
    filter = lane.fAmount
    ducks = lane.ducks
    isKick = lane.isKick
    send = lane.send
    shimmer = lane.shimmerSend
    echo = lane.echoSend
    rest = lane.restClass
    harmonyGroup = lane.harmonyGroup
    choke = lane.chokeMul
  }
}

/// The classes of fix in which `jumped` plays differently from `song` (the same song, another
/// start), each with what differs. Empty: the jump plays every fix the song does.
private func divergences(
  _ jumped: WaveProject, _ song: WaveProject, bank a: SamplerBank?, _ b: SamplerBank? = nil
) -> [String] {
  var out: [String] = []
  func check(_ name: String, _ same: Bool, _ detail: @autoclosure () -> String = "") {
    if !same { out.append(detail().isEmpty ? name : "\(name): \(detail())") }
  }
  // loudness ± 0.5 dB (10^(0.5/20))
  let ratio = jumped.gain / max(song.gain, 1e-9)
  check("loudness", ratio < 1.0593 && ratio > 1 / 1.0593, "\(jumped.gain) vs \(song.gain)")
  check("energy", jumped.energy == song.energy)
  check("duck", jumped.duckDepth == song.duckDepth)
  check("rests", jumped.songRests == song.songRests)
  check("tail", jumped.tail == song.tail)
  check("section harmony", jumped.harmony == song.harmony)
  check("room", jumped.space == song.space, "\(String(describing: jumped.space))")
  check("echo", jumped.echo == song.echo)
  check(
    "trims", jumped.balance == song.balance, "\(jumped.balance ?? [:]) vs \(song.balance ?? [:])")
  check("feel", jumped.feel == song.feel)
  check("drift", jumped.drift == song.drift)
  check("voice design", jumped.voiceDesign == song.voiceDesign)
  check("brake", jumped.turntableBrake == song.turntableBrake)
  check("riser", (jumped.riser == nil) == (song.riser == nil))
  // per sampler slot, by the instrument it plays
  func slots(_ p: WaveProject, _ bank: SamplerBank?) -> [String: [Float]] {
    var m: [String: [Float]] = [:]
    for lane in p.lanes where lane.samplerSlot >= 0 && lane.samplerSlot < 64 {
      let name = bank?.source(of: lane.samplerSlot).map { "\($0)" } ?? "?"
      m[name] = [p.slotGain[lane.samplerSlot], p.slotWidth[lane.samplerSlot]]
    }
    return m
  }
  check("slot gain / width", slots(jumped, a) == slots(song, b ?? a))
  let jl = jumped.lanes.map { LanePrint($0, bank: a) }
  let sl = song.lanes.map { LanePrint($0, bank: b ?? a) }
  guard jl.count == sl.count else {
    out.append("lanes: \(jl.count) vs \(sl.count)")
    return out
  }
  for (x, y) in zip(jl, sl) where x != y {
    var what: [String] = []
    if x.net != y.net || x.kind != y.kind || x.channel != y.channel { what.append("lane") }
    if x.instrument != y.instrument || x.sampler != y.sampler { what.append("sampler pick") }
    if x.voice != y.voice {
      what.append(x.kind == "kick" ? "kick tune" : x.kind == "snare" ? "brushes" : "voice")
    }
    if x.pan != y.pan || x.spread != y.spread { what.append("pans") }
    if x.level != y.level || x.kitVelocity != y.kitVelocity { what.append("trims") }
    if x.tilt != y.tilt { what.append("hf tilt") }
    if x.subOctave != y.subOctave { what.append("sub-octave") }
    if x.pluck != y.pluck || x.mip != y.mip || x.unison != y.unison || x.filter != y.filter {
      what.append("sound design")
    }
    if x.ducks != y.ducks || x.isKick != y.isKick { what.append("duck") }
    if x.send != y.send || x.shimmer != y.shimmer || x.echo != y.echo { what.append("sends") }
    if x.rest != y.rest { what.append("gaps / rests") }
    if x.harmonyGroup != y.harmonyGroup { what.append("section harmony") }
    if x.choke != y.choke { what.append("choke") }
    out.append("\(y.net)/\(y.kind): \(what.joined(separator: ", "))")
  }
  return out
}

/// Jump `deck` into each of the song's first three sections and compare each jump with the
/// project its song started with. Returns every divergence, labelled by section.
@MainActor
private func jumpDivergences(_ deck: Deck, against song: WaveProject, bank: SamplerBank?) async
  -> [String]
{
  var out: [String] = []
  let secs = deck.sections
  for index in 0..<min(3, secs.count) {
    guard await deck.jumpToSection(index), let jumped = deck.wave.latest else {
      out.append("section \(index): did not jump")
      continue
    }
    if jumped.startTick != secs[index].startTick || jumped.trackSerial != song.trackSerial {
      out.append("section \(index): not the same song at its start")
    }
    out += divergences(jumped, song, bank: bank).map {
      "section \(index) \(secs[index].name): \($0)"
    }
  }
  return out
}

@MainActor
@Suite(.serialized)
struct FixesUnderJumpsTests {
  /// Every fix the song plays from its top, a jump into each of its first three sections plays
  /// too: 12 genres, dance and chill among them, at seed 42.
  @Test(arguments: genres)
  func sectionJumpsKeepEveryFix(_ genre: String) async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    #expect(await deck.generate(spec(genre)))
    let song = try #require(deck.wave.latest)
    #expect(deck.sections.count >= 3)
    let found = await jumpDivergences(deck, against: song, bank: deck.wave.samplers)
    #expect(found.isEmpty, "\(genre): \(found.joined(separator: "; "))")
  }

  /// The jump options themselves: the genre's own settings, as `PreparedTrack` prepared the song.
  @Test(arguments: ["jazz", "dnb", "techno", "lofi"])
  func sameSongOptionsCarryTheGenre(_ genre: String) async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    #expect(await deck.generate(spec(genre)))
    let o = deck.sameSongOptions(deck.waveOptions)
    let fresh = WaveOptions.extended(samplers: nil).forGenre(genre)
    #expect(o.genre == genre)
    #expect(o.brushes == fresh.brushes)
    #expect(o.subOctave == fresh.subOctave)
    #expect(o.hfTilt == fresh.hfTilt)
    #expect(o.feel == fresh.feel)
    #expect(o.voiceDesign == fresh.voiceDesign)
    #expect(o.duckDepth == fresh.duckDepth)
    if genre == "jazz" { #expect(o.brushes) }
    if genre == "dnb" { #expect(o.subOctave) }
  }

  /// A jump plays as loud as the song does from the same tick (± 0.5 dB, rendered): the song
  /// restarted there as a prepared track (`PreparedTrack.restarted`, its own options) on one
  /// engine, the deck's section jump on another.
  @Test(arguments: ["techno", "lofi"])
  func jumpsRenderAsLoudAsTheSong(_ genre: String) async throws {
    for index in 0..<3 {
      // fresh engines for every section: both decks start stopped, so each load is at once
      let ref = try DJEngine(decks: ["A"], offline: true)
      let live = try DJEngine(decks: ["A"], offline: true)
      let r = try #require(ref["A"])
      let l = try #require(live["A"])
      #expect(await l.generate(spec(genre)))
      let secs = l.sections
      guard secs.indices.contains(index) else { continue }
      let track = PreparedTrack(
        spec: spec(genre), sampleRate: ref.sampleRate,
        opts: .extended(samplers: r.wave.samplers, roleFilter: nil))
      r.loadNet(track.restarted(atTick: secs[index].startTick))
      #expect(await l.jumpToSection(index))
      r.setPlaying(true)
      l.setPlaying(true)
      try ref.start()
      try live.start()
      defer {
        ref.stop()
        live.stop()
      }
      let frames = Int(6 * ref.sampleRate)
      let da = rmsDB(try renderOffline(ref, frames: frames)[...])
      let db = rmsDB(try renderOffline(live, frames: frames)[...])
      #expect(da > -60, "\(genre) section \(index): the reference plays")
      #expect(abs(da - db) < 0.5, "\(genre) section \(index): \(da) vs \(db) dB")
    }
  }

  /// The next track handed over by the skip button plays every fix a fresh prepare of it does,
  /// and so do jumps inside it.
  @Test(arguments: ["techno", "lofi"])
  func skipToNextTrackKeepsEveryFix(_ genre: String) async throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    dj.deterministic = true  // the compose and the hand-over run inline
    let deck = try #require(dj["A"])
    #expect(await deck.generate(spec(genre)))
    deck.queueNext(spec(genre, seed: seed + 1))
    deck.skipToNextTrack()
    let next = try #require(deck.wave.latest)
    let nextSpec = try #require(deck.currentSpec)
    #expect(nextSpec.seed == seed + 1)
    let other = try DJEngine(decks: ["A"], offline: true)
    let bank = try #require(other["A"]).wave.samplers
    let fresh = PreparedTrack(
      spec: nextSpec, sampleRate: other.sampleRate,
      opts: .extended(samplers: bank, roleFilter: nil))
    let found = divergences(next, fresh.prepared, bank: deck.wave.samplers, bank)
    #expect(found.isEmpty, "\(genre) skip: \(found.joined(separator: "; "))")
    dj.deterministic = false
    let jumps = await jumpDivergences(deck, against: next, bank: deck.wave.samplers)
    #expect(jumps.isEmpty, "\(genre) skip, then jumps: \(jumps.joined(separator: "; "))")
  }

  /// A deck copied onto the other (`copyDeck`: its source prepared on that deck's bank) plays
  /// every fix the original does, and so do jumps inside the copy.
  @Test(arguments: ["techno", "lofi"])
  func copyDeckKeepsEveryFix(_ genre: String) async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true)
    let a = try #require(dj["A"])
    let b = try #require(dj["B"])
    #expect(await a.generate(spec(genre)))
    let song = try #require(a.wave.latest)
    let source = try #require(a.netSource)
    let copy = try #require(
      PreparedTrack(
        source: source, sampleRate: dj.sampleRate,
        opts: .extended(samplers: b.wave.samplers, roleFilter: b.roleFilter)))
    b.loadNet(copy)
    let copied = try #require(b.wave.latest)
    let found = divergences(copied, song, bank: b.wave.samplers, a.wave.samplers)
    #expect(found.isEmpty, "\(genre) copy: \(found.joined(separator: "; "))")
    let jumps = await jumpDivergences(b, against: copied, bank: b.wave.samplers)
    #expect(jumps.isEmpty, "\(genre) copy, then jumps: \(jumps.joined(separator: "; "))")
  }
}
