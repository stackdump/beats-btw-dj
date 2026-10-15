import Darwin
import Testing

@testable import DJCore

private let synthwave = [
  TrackSpec(genre: "synthwave", seed: 1984, structure: "standard"),
  TrackSpec(genre: "synthwave", seed: 2077, structure: "standard"),
]

private func actions(_ s: Session) -> [(frame: Int, action: DeckAction)] {
  s.events.compactMap {
    if case .action(let a) = $0.kind { return ($0.frame, a) }
    return nil
  }
}

struct SessionMixTests {
  @Test func twoTracksMixInOrder() throws {
    let mix = try SessionMix(synthwave, xfade: 20)
    let s = mix.session
    let ev = actions(s)
    #expect(ev.count == s.events.count, "a mix is all actions, no MIDI")

    // Events are written in frame order, on engine-block boundaries, inside the session.
    #expect(s.events.map(\.frame) == s.events.map(\.frame).sorted())
    #expect(s.events.allSatisfy { $0.frame % SessionMix.grain == 0 })
    #expect(s.events.allSatisfy { $0.frame >= 0 && $0.frame < s.frames })

    // The story: A plays; B syncs to its bar, plays, the crossfader ramps 0 → 1, A stops; B
    // plays out.
    #expect(ev.first?.frame == 0)
    #expect(ev.first?.action == .play(deck: "A", on: true))
    let sync = try #require(ev.first { $0.action == .sync(deck: "B", align: "bar") })
    let playB = try #require(ev.first { $0.action == .play(deck: "B", on: true) })
    let stopA = try #require(ev.first { $0.action == .play(deck: "A", on: false) })
    let stopB = try #require(ev.first { $0.action == .play(deck: "B", on: false) })
    #expect(sync.frame < playB.frame && playB.frame < stopA.frame && stopA.frame < stopB.frame)

    let fader: [(frame: Int, value: Double)] = ev.compactMap {
      if case .crossfader(let v) = $0.action { return ($0.frame, v) }
      return nil
    }
    #expect(fader.count == Int(20 / SessionMix.rampStep))
    #expect(fader.map(\.value) == fader.map(\.value).sorted(), "B is crossfader 1: it rises")
    #expect(fader.last?.value == 1)
    #expect(fader.allSatisfy { $0.frame > playB.frame && $0.frame < stopA.frame })

    // The ramp is the crossfade: `xfade` seconds from B's start.
    let rampFrames = Double(fader.last!.frame - playB.frame) / s.sampleRate
    #expect(abs(rampFrames - 20) < 0.05)

    // The planned tracks agree with the events, and the last one ends the set.
    let t = mix.tracks
    #expect(t.map(\.deck) == ["A", "B"])
    #expect(t[0].inFrame == 0 && t[0].outFrame == stopA.frame)
    #expect(t[1].inFrame == playB.frame && t[1].outFrame == stopB.frame)
    #expect(s.frames > stopB.frame)
    #expect(
      s.frames - stopB.frame <= Int(s.sampleRate) + SessionMix.grain, "about a second of tail")

    // Both songs are whole and the first plays at its own tempo.
    #expect(t.allSatisfy { $0.seconds > 60 })
    #expect(t[0].playedBPM == t[0].bpm)
    #expect(mix.title == "\(t[0].title) into \(t[1].title)")
    #expect(s.decks["A"] == .net(synthwave[0]) && s.decks["B"] == .net(synthwave[1]))
    #expect(s.crossfader == 0)
  }

  @Test func thirdTrackReloadsTheFreedDeck() throws {
    let specs = synthwave + [TrackSpec(genre: "synthwave", seed: 7, structure: "standard")]
    let mix = try SessionMix(specs, xfade: 20)
    let ev = actions(mix.session)
    #expect(mix.tracks.map(\.deck) == ["A", "B", "A"])
    let load = try #require(
      ev.first { if case .load(deck: "A", _) = $0.action { return true } else { return false } })
    // Loaded after A's first track was stopped, before the third one syncs.
    let sync = try #require(ev.last { $0.action == .sync(deck: "A", align: "bar") })
    #expect(load.frame > mix.tracks[0].outFrame && load.frame < sync.frame)
    #expect(mix.tracks[2].inFrame > mix.tracks[1].inFrame)
    #expect(mix.session.events.map(\.frame) == mix.session.events.map(\.frame).sorted())
    // The crossfader runs back toward A on the second transition.
    let faders: [Double] = ev.compactMap {
      if case .crossfader(let v) = $0.action { return v }
      return nil
    }
    #expect(faders.count == 2 * Int(20 / SessionMix.rampStep))
    #expect(faders.last == 0)
  }

  @Test func roundTripsThroughTheStoreWithAStableCID() throws {
    let h = StoreHarness()
    let mix = try SessionMix(synthwave, xfade: 20)
    let (cid, url) = try h.store.save(mix.session)
    #expect(cid == mix.session.cid && url.lastPathComponent == "\(cid).json")

    // Loaded back it is the same session, with the same name.
    let back = try h.store.load(cid: cid)
    #expect(back == mix.session)
    #expect(back.cid == cid)
    #expect(h.store.list() == [cid])

    // The plan is deterministic: planning again is the same file, and the JSON re-encodes
    // to the same bytes.
    let again = try SessionMix(synthwave, xfade: 20)
    #expect(again.session.cid == cid)
    #expect(try h.store.save(again.session).url == url && h.store.list().count == 1)
    #expect(try Session(json: JSONValue.parse(back.json.jsStringified)).cid == cid)

    // A different crossfade is a different set.
    #expect(try SessionMix(synthwave, xfade: 12).session.cid != cid)
  }

  @Test func refusesWhatItCannotMix() throws {
    #expect(throws: SessionMixError.tooFewTracks) { try SessionMix([synthwave[0]]) }
    #expect(throws: SessionMixError.unknownGenre("nope")) {
      try SessionMix([synthwave[0], TrackSpec(genre: "nope", seed: 1, structure: "standard")])
    }
    // A song with no sections is an endless loop: there is no end to mix out of.
    let loop = TrackSpec(genre: "synthwave", seed: 1, structure: nil)
    #expect(throws: (any Error).self) { try SessionMix([loop, synthwave[1]]) }
  }
}
