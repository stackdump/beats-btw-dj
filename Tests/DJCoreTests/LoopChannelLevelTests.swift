import Foundation
import Testing

@testable import DJCore

// The loop channel ("L") sits level with A/B at the centred crossfader: A/B take the
// crossfader's equal-power −3 dB there (`DJEngine.crossfadeGain`) and L none, so L's trim starts
// at −3 dB (`DJEngine.loopChannelGain`). New sessions and journals record it; old ones replay at
// the unity they were recorded with.

private func loudness(_ l: [Float], _ r: [Float], _ rate: Double) -> Double {
  IntegratedLoudness.integrated(left: l, right: r, sampleRate: rate) ?? -200
}

@MainActor
struct LoopChannelLevelTests {
  @Test func theLoopChannelStartsAtTheCentredCrossfadersGain() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let l = dj.loopChannel
    let a = try #require(dj["A"])
    #expect(dj.crossfader == 0.5)
    #expect(l.gain == DJEngine.loopChannelGain)
    #expect(abs(l.trim - dj.crossfadeGain("A")) < 1e-12)
    #expect(abs(ampDB(l.trim) - (-3.01)) < 0.01, "\(ampDB(l.trim)) dB")
    // the decks keep their unity trim; at unity faders the strips match
    #expect(a.gain == 0.5 && a.trim == 1)
    #expect(abs(l.strip.outputVolume - a.strip.outputVolume) < 1e-6)
  }

  /// The gap on the master, measured: the demo loop on A with auto-gain (at the reference), a
  /// two-bar take of it looping on L, unity faders, crossfader centred. A alone (L muted) for
  /// four bars, then L alone (A muted) for four. Before the change L played 2.9 LU over A.
  @Test func aTakeOnTheLoopChannelSitsLevelWithACentredDeck() throws {
    let rate = 22_050.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj.deterministic = true
    try dj.start()
    defer { dj.stop() }
    let conductor = OfflineConductor(engine: dj, router: ControllerRouter(engine: dj))
    let bar = Int(rate * 2) / OfflineConductor.blockFrames  // blocks per 120 bpm bar
    let a = try #require(dj["A"])
    var aL: [Float] = []
    var aR: [Float] = []
    var lL: [Float] = []
    var lR: [Float] = []
    for b in 0..<(16 * bar) {
      let (l, r) = try conductor.step {
        switch b {
        case 0:
          dj.perform(.param(deck: "A", name: "autoGain", value: 1))
          dj.perform(
            .load(
              deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil)
            ))
          dj.perform(.play(deck: "A", on: true))
          dj.loopChannel.mute = true  // the take loops on L at once: A alone first
        case bar + bar / 2: dj.perform(.loopRecord(deck: "A", on: true, bars: 2))
        case bar + bar / 2 + 2: dj.perform(.loopRecord(deck: "A", on: false))
        case 9 * bar:
          a.mute = true
          dj.loopChannel.mute = false
        default: break
        }
      }
      if (5 * bar..<9 * bar).contains(b) {
        aL += l
        aR += r
      }
      if (11 * bar..<15 * bar).contains(b) {
        lL += l
        lR += r
      }
    }
    let clip = try #require(dj.clips.last)
    #expect(dj.loopState(clip.id) == .on)
    #expect(a.autoGainDB != 0)
    let aOut = loudness(aL, aR, rate)
    let lOut = loudness(lL, lR, rate)
    let gap = lOut - aOut
    print(
      "loop channel: A on the master \(String(format: "%.2f", aOut)) LUFS, L "
        + "\(String(format: "%.2f", lOut)); gap L − A \(String(format: "%.2f", gap)) LU (trim "
        + "\(dj.loopChannel.trim), crossfade A \(dj.crossfadeGain("A")))")
    #expect(aOut > -60 && lOut > -60)
    #expect(abs(gap) < 1, "gap \(gap) LU")
  }

  /// A session written before L's trim was recorded has no `mixer.loopGain`: it decodes to the
  /// unity it was played at, re-encodes to the same text and CID, and replays L at unity.
  @Test func aSessionRecordedBeforeTheChangeKeepsTheOldTrim() throws {
    let old = """
      {"decks":{"A":{"params":{"autoAdvance":false,"eqHigh":0.5,"eqLow":0.5,"eqMid":0.5,\
      "filter":0.5,"gain":0.5,"pitch":0,"quantize":"off","volume":0.8},"source":{"kind":"none"}}},\
      "events":[],"frames":4410,"mixer":{"crossfader":0.5,"master":0.8},"sampleRate":22050,\
      "schema":"dj-vevr-se/session/v1"}
      """
    let s = try Session.decode(old)
    #expect(s.loopGain == Session.legacyLoopGain && s.loopGain == 0.5)
    #expect(s.json["mixer"]?["loopGain"] == nil)
    #expect(s.canonical == (try JSONValue.parse(old)).canonicalJS)
    #expect(try Session.decode(s.canonical, cid: s.cid) == s)
    let player = SessionPlayer(session: s)
    var replayed: [Double] = []
    player.onBlock = { dj, _ in replayed.append(dj.loopChannel.gain) }
    _ = try player.render()
    #expect(!replayed.isEmpty && replayed.allSatisfy { $0 == 0.5 })
  }

  /// A new recording carries L's trim, on the wire and back through a replay.
  @Test func aNewSessionRecordsTheLoopChannelsTrim() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let s = try SessionRecorder.start(on: dj).finish()
    #expect(s.loopGain == DJEngine.loopChannelGain)
    #expect(s.json["mixer"]?["loopGain"]?.double == DJEngine.loopChannelGain)
    let back = try Session.decode(s.canonical, cid: s.cid)
    #expect(back.loopGain == DJEngine.loopChannelGain)
    // a trim the user moved records as it was
    dj.loopChannel.gain = 0.7
    #expect(try SessionRecorder.start(on: dj).finish().loopGain == 0.7)
    let player = SessionPlayer(session: back)
    var replayed: [Double] = []
    player.onBlock = { dj, _ in replayed.append(dj.loopChannel.gain) }
    _ = try player.render()
    #expect(!replayed.isEmpty && replayed.allSatisfy { $0 == DJEngine.loopChannelGain })
  }

  /// A journal checkpoint holds L's params (the trim always among them): an old one restores
  /// unity, a new one the engine's −3 dB.
  @Test func aJournalCheckpointRestoresTheLoopChannelsTrim() throws {
    let live = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let state = JournalState(engine: live)
    #expect(state.loopChannel.gain == DJEngine.loopChannelGain)
    var oldState = try #require(JournalState(json: state.json))
    #expect(oldState.loopChannel.gain == DJEngine.loopChannelGain)
    oldState.loopChannel.gain = 0.5  // what a checkpoint from before the change holds
    let fresh = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let restoredOld = try #require(JournalState(json: oldState.json))
    restoredOld.restore(into: fresh) { _ in nil }
    #expect(fresh.loopChannel.gain == 0.5)
    let fresh2 = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    fresh2.loopChannel.gain = 0.9
    state.restore(into: fresh2) { _ in nil }
    #expect(fresh2.loopChannel.gain == DJEngine.loopChannelGain)
  }
}
