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

  /// Three tracks at known levels (1 kHz sines, linear crossfades), laid out as `SessionMix`
  /// plans them: each comes in 10 s before the one playing stops.
  private func layout(gainsDB: [Double], sampleRate sr: Double = 16_000)
    -> (tracks: [SessionMix.Track], audio: RenderedAudio)
  {
    let spec = synthwave[0]
    var tracks: [SessionMix.Track] = []
    for i in gainsDB.indices {
      let inF = Int(Double(i) * 30 * sr)
      tracks.append(
        SessionMix.Track(
          spec: spec, title: "t\(i)", deck: SessionMix.decks[i % 2], bpm: 120, playedBPM: 120,
          steps: 0, inFrame: inF, outFrame: inF + Int((i + 1 < gainsDB.count ? 40 : 30) * sr)))
    }
    let n = tracks.last!.outFrame + Int(sr)
    var left = [Float](repeating: 0, count: n)
    for (i, t) in tracks.enumerated() {
      let a = 0.25 * pow(10, gainsDB[i] / 20)
      for f in t.inFrame..<t.outFrame {
        // fade in over the first 10 s (not the first track), out over the last 10 s (not the last)
        var g = 1.0
        if i > 0 { g = min(g, Double(f - t.inFrame) / (10 * sr)) }
        if i + 1 < tracks.count { g = min(g, Double(t.outFrame - f) / (10 * sr)) }
        left[f] += Float(a * g * sin(2 * .pi * 1000 * Double(f) / sr))
      }
    }
    return (tracks, RenderedAudio(sampleRate: sr, left: left, right: left))
  }

  @Test func reportMeasuresEachTrackAndEachStep() throws {
    let (tracks, audio) = layout(gainsDB: [0, 1.5, 7.5])
    let r = SessionMix.report(tracks: tracks, audio: audio)
    #expect(r.tracks.map(\.title) == ["t0", "t1", "t2"])
    #expect(r.tracks.map(\.deck) == ["A", "B", "A"])
    // Each alone: the first is the reference, the others its level plus their gain.
    let ref = r.tracks[0].lufs
    #expect(abs(r.tracks[1].lufs - ref - 1.5) < 0.1)
    #expect(abs(r.tracks[2].lufs - ref - 7.5) < 0.1)
    // A 0.25 sine reads about −12 dBTP; the loudest track sets the set's peak.
    #expect(abs(r.tracks[0].truePeak - 20 * log10(0.25)) < 0.1)
    #expect(abs(r.truePeak - r.tracks[2].truePeak) < 0.01)
    // One step per crossfade, into tracks 2 and 3 (0-based 1, 2).
    #expect(r.transitions.map(\.index) == [1, 2])
    #expect(abs(r.transitions[0].step - 1.5) < 0.1)
    #expect(abs(r.transitions[1].step - 6) < 0.1)
    #expect(abs(r.seconds - Double(audio.frames) / audio.sampleRate) < 1e-9)
    #expect(r.lufs > ref && r.lufs < r.tracks[2].lufs)

    // The bar: 6 LU is over 2, and 91 s is under ten minutes.
    let p = r.problems()
    #expect(p.count == 2)
    #expect(p.contains { $0.contains("under 600") })
    #expect(p.contains { $0.contains("transition into 3") })
    #expect(r.problems(minSeconds: 60, maxStep: 6.5).isEmpty)
    // and a ceiling under the peak is a problem
    #expect(r.problems(minSeconds: 60, maxStep: 6.5, ceiling: -20).count == 1)
    #expect(r.lines.count == 3 + 2 + 2)
  }

  @Test func reportOfALevelSetPasses() throws {
    let (tracks, audio) = layout(gainsDB: [0, -1, 0.5])
    let r = SessionMix.report(tracks: tracks, audio: audio)
    #expect(r.transitions.allSatisfy { abs($0.step) <= 2 })
    #expect(r.problems(minSeconds: 60).isEmpty)
    #expect(r.lines.last?.contains("under 600") == true, "only the length misses the bar")
    // Silence alone measures as silence, not as a level.
    let quiet = RenderedAudio(
      sampleRate: audio.sampleRate, left: .init(repeating: 0, count: audio.frames),
      right: .init(repeating: 0, count: audio.frames))
    let q = SessionMix.report(tracks: tracks, audio: quiet)
    #expect(q.tracks.allSatisfy { $0.lufs == -200 && $0.truePeak == -200 })
  }
}
