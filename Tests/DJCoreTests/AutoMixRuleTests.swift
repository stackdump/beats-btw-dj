import Testing

@testable import DJCore

/// A context like a playing techno song's (Wander's planner tests' shape), at the mix tempo.
private func context(
  _ spec: TrackSpec = TrackSpec(genre: "techno", seed: 42, structure: "standard"),
  locks: Set<String> = [], mixBPM: Double? = nil
) -> WanderContext {
  let roles = ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"]
  let voices = [
    WanderVoice(
      roles: ["kick", "snare", "hihat"], channel: 10, instrument: "drums",
      options: ["drums", "drums-909"]),
    WanderVoice(
      roles: ["bass"], channel: 2, instrument: "sub-bass", options: ["sub-bass", "acid"]),
    WanderVoice(roles: ["melody"], channel: 1, instrument: "lead", options: ["lead", "pluck"]),
    WanderVoice(roles: ["arp"], channel: 4, instrument: "arp", options: ["arp", "bell"]),
  ]
  var c = WanderContext(
    deck: "A", spec: spec, isLoop: spec.structure == nil, roles: roles, rolesOn: Set(roles),
    disabledRoles: [], stemsMuted: [], lockedActions: [], locks: locks, voices: voices,
    anchorBPM: nil, key: nil)
  if locks.contains("tempo") { c.anchorBPM = Wander.bpm(of: spec) }
  if locks.contains("key"), let g = BeatsTables.shared.genres[spec.genre] {
    c.key = WanderKey(scale: g.scaleName, rootPC: (g.rootNote + 3) % 12, offset: 3)
  }
  c.mixBPM = mixBPM ?? Wander.bpm(of: spec)
  return c
}

/// The key the outgoing deck plays (techno's root, moved by `offset`).
private func key(_ genre: String = "techno", offset: Int = 0) -> WanderKey {
  let g = BeatsTables.shared.genres[genre]!
  return WanderKey(scale: g.scaleName, rootPC: (g.rootNote + offset + 12) % 12, offset: offset)
}

struct AutoMixRuleTests {
  @Test func theActionsRoundTripThroughJSON() throws {
    let actions: [DeckAction] = [
      .autoMix(on: true, bars: 8, every: 0), .autoMix(on: false, bars: 32, every: 16),
      .autoMixNow, .autoMixDefer(handoff: 3),
    ]
    for a in actions {
      #expect(DeckAction(json: a.json) == a, "\(a.json.canonicalJS)")
      #expect(DeckAction.jsonOps.contains(a.json["op"]!.string!))
    }
    #expect(
      DeckAction.autoMix(on: true, bars: 8, every: 0).json.canonicalJS
        == #"{"bars":8,"every":0,"on":true,"op":"autoMix"}"#)
    // decode clamps to the offered lengths and phrases, with the defaults
    let odd = DeckAction(json: try JSONValue.parse(#"{"op":"autoMix","on":true,"bars":7,"every":5}"#))
    #expect(odd == .autoMix(on: true, bars: 8, every: 0))
    let bare = DeckAction(json: try JSONValue.parse(#"{"op":"autoMix"}"#))
    #expect(bare == .autoMix(on: false, bars: 8, every: 0))
    #expect(DeckAction(json: try JSONValue.parse(#"{"op":"autoMixDefer"}"#)) == nil)
    #expect(DeckAction.autoMix(on: true, bars: 8, every: 0).summary == "auto-mix on · 8 bars · to the outro")
    #expect(DeckAction.autoMixNow.summary == "mix now")
    #expect(DeckAction.autoMixDefer(handoff: 3).summary == "auto-mix deferred #3")
  }

  @Test func theSettingsRideInASessionOnlyWhenSet() throws {
    let plain = Session(
      sampleRate: 48_000, frames: 0, decks: [:], params: [:], crossfader: 0.5, master: 0.8,
      events: [])
    #expect(plain.json["mixer"]?["autoMix"] == nil, "older sessions keep their text and CID")
    var s = plain
    s.autoMix = AutoMixState(settings: AutoMixSettings(on: true, bars: 16, every: 4), handoffs: 2)
    let back = try Session.decode(s.canonical, cid: s.cid)
    #expect(back.autoMix.settings == AutoMixSettings(on: true, bars: 16, every: 4))
    #expect(back.autoMix.handoffs == 2)
    #expect(back == s)
  }

  @Test func wandersDrawsAreUnchanged() {
    // `plan(_:step:)` is the overload over every kind the locks leave, from its own stream
    let c = context()
    for step in 0..<200 {
      var rng = WanderRandom(spec: c.spec, step: step)
      #expect(Wander.plan(c, step: step) == Wander.plan(c, random: &rng, kinds: Wander.kinds(c)))
    }
  }

  @Test func theIncomingIsAPureFunctionOfTheOutgoingAndTheCounter() {
    let c = context()
    var differs = 0
    var notWanders = 0
    for n in 0..<40 {
      let a = AutoMix.plan(c, n: n, key: key())
      #expect(a != nil)
      #expect(a == AutoMix.plan(c, n: n, key: key()), "same configuration and counter")
      if a?.spec != AutoMix.plan(c, n: n + 1, key: key())?.spec { differs += 1 }
      if case .swap(let w)? = Wander.plan(c, step: n)?.action, w == a?.spec {
      } else {
        notWanders += 1
      }
      #expect(a?.from == BeatsCID.shareCID(c.spec.payload))
    }
    #expect(differs >= 38, "the counter moves the draw (\(differs)/40)")
    #expect(notWanders >= 38, "salted apart from Wander's step n (\(notWanders)/40)")
  }

  @Test func aHandOffBringsANewTrack() {
    let c = context()
    var kinds: [String: Int] = [:]
    for n in 0..<300 {
      guard let p = AutoMix.plan(c, n: n, key: key()), let spec = p.spec else {
        Issue.record("no plan at \(n)")
        continue
      }
      kinds[p.kind, default: 0] += 1
      #expect(["seed", "instrument", "genre"].contains(p.kind))
      #expect(spec != c.spec)
      #expect(spec.seed != c.spec.seed || spec.genre != c.spec.genre)
    }
    // Wander's weights renormalised: seed 20 : instrument 9 : genre 5 (59 / 26 / 15 %)
    let seed = Double(kinds["seed"] ?? 0) / 300
    let genre = Double(kinds["genre"] ?? 0) / 300
    #expect(abs(seed - 20.0 / 34) < 0.08, "seed \(seed)")
    #expect(abs(genre - 5.0 / 34) < 0.08, "genre \(genre)")
  }

  @Test func genreHopsStayInTheTempoWindow() {
    for (genre, bpm) in [("techno", nil), ("house", 129.0), ("trance", nil), ("dnb", nil)] {
      let spec = TrackSpec(genre: genre, seed: 7, structure: "standard")
      let c = context(spec, mixBPM: bpm)
      for n in 0..<200 {
        guard let p = AutoMix.plan(c, n: n, key: nil), p.kind == "genre", let s = p.spec else {
          continue
        }
        let g = BeatsTables.shared.genres[s.genre]!
        let m = Deck.tempoMatch(base: g.bpm, target: c.mixBPM!)
        #expect(!m.clamped && m.mult == 1, "\(genre) → \(s.genre) at \(c.mixBPM!)")
      }
      // the tempo lock narrows it to ±6 % of its anchor
      let locked = context(spec, locks: ["tempo"], mixBPM: bpm)
      for n in 0..<200 {
        guard let p = AutoMix.plan(locked, n: n, key: nil), p.kind == "genre", let s = p.spec else {
          continue
        }
        let g = BeatsTables.shared.genres[s.genre]!
        #expect(abs(g.bpm / locked.anchorBPM! - 1) <= WanderLock.tempoTolerance)
      }
    }
  }

  @Test func locksHold() {
    // the genre lock: same genre always
    for n in 0..<100 {
      let p = AutoMix.plan(context(locks: ["genre"]), n: n, key: key())
      #expect(p?.spec?.genre == "techno" && p?.kind != "genre")
    }
    // the instruments lock (here as the union of both decks' locks): no instrument move, and
    // every voice rides along
    for n in 0..<60 {
      let p = AutoMix.plan(context(locks: ["instruments", "genre"]), n: n, key: key())
      #expect(p?.kind == "seed")
      let tracks = p?.spec?.layers["tracks"]?.object
      #expect(tracks?["2"]?["instrument"]?.string == "sub-bass")
    }
    // keep:bass on a same-genre hand-off carries the bass line's seed
    for n in 0..<40 {
      let p = AutoMix.plan(context(locks: ["genre", WanderLock.keep("bass")]), n: n, key: key())
      #expect(p?.spec?.partSeeds["bass"] == 42)
    }
    // the key lock pins its key, not a compatible one
    let k = context(locks: ["key"])
    for n in 0..<40 {
      #expect(AutoMix.plan(k, n: n, key: key())?.spec?.pinnedKeyOffset == 3)
    }
    // the palette and kit carry
    var pal = context()
    pal.palette = "synthwave"
    pal.channels = [1, 2, 4, 10]
    for n in 0..<20 {
      #expect(AutoMix.plan(pal, n: n, key: key())?.spec?.palette == "synthwave")
    }
    // everything kept: nothing to draw
    #expect(
      !AutoMix.canDraw(
        context(locks: Set(["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"].map(WanderLock.keep)))))
  }

  @Test func theKeyIsCompatible() {
    let out = key(offset: 2)
    var seen = Set<Int>()
    for n in 0..<200 {
      guard let p = AutoMix.plan(context(), n: n, key: out), let s = p.spec,
        let g = BeatsTables.shared.genres[s.genre]
      else { continue }
      if g.scaleName == out.scale {
        let off = s.pinnedKeyOffset
        #expect(off != nil && (-5...6).contains(off!))
        let pc = ((g.rootNote + (off ?? 0)) % 12 + 12) % 12
        let d = (pc - out.rootPC + 12) % 12
        #expect([0, 7, 5].contains(d), "root \(pc) against \(out.rootPC)")
        seen.insert(d)
      } else {
        #expect(s.pinnedKeyOffset == nil, "another scale keeps the variety pass's own key")
      }
    }
    #expect(seen == [0, 5, 7])
  }
}
