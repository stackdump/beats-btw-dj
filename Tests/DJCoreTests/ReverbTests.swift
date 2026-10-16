@preconcurrency import AVFoundation
import AudioToolbox
import Testing

@testable import DJCore

/// A short burst of noise, then silence: what a room rings after.
private func burst(seconds: Double, rate: Double) -> SampleBuffer {
  let n = Int(seconds * rate)
  var g = SystemRandomNumberGenerator()
  let l = (0..<n).map { i in i < Int(rate * 0.05) ? Float.random(in: -0.5...0.5, using: &g) : 0 }
  return SampleBuffer(left: l, right: l, sampleRate: rate)
}

private func rms(_ a: ArraySlice<Float>) -> Float {
  a.isEmpty ? 0 : (a.reduce(0) { $0 + $1 * $1 } / Float(a.count)).squareRoot()
}

@MainActor
struct ReverbTests {
  let rate = 48_000.0

  /// A deck playing the burst once (no loop wrap within `seconds`), strip at unity, A only.
  func engine(wet: Double) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: rate)
    let a = try #require(dj["A"])
    a.load(burst(seconds: 4, rate: rate), title: "burst")
    a.volume = 1
    dj.crossfader = 0
    dj.master = 1
    a.reverb.size = 0.6
    a.reverb.wet = wet
    a.setPlaying(true)
    return (dj, a)
  }

  @Test func offIsBypassedAndBitTransparent() throws {
    let (dj, a) = try engine(wet: 0)
    #expect(a.reverb.node.bypass && !a.reverb.isOn)
    try dj.start()
    defer { dj.stop() }
    let out = try renderOffline(dj, frames: Int(rate))
    var l: [Float] = []
    var r: [Float] = []
    _ = a.capture.copy(from: 0, to: Int(rate), left: &l, right: &r)
    #expect(out.count == l.count)
    #expect(zip(out, l).allSatisfy { $0 == $1 }, "the master is the deck's EQ output, unchanged")
  }

  @Test func onItRingsAfterTheSoundStopsAndTakesStayDry() throws {
    let (dj, a) = try engine(wet: 0.5)
    #expect(!a.reverb.node.bypass)
    try dj.start()
    defer { dj.stop() }
    let out = try renderOffline(dj, frames: Int(rate))
    var l: [Float] = []
    var r: [Float] = []
    _ = a.capture.copy(from: 0, to: Int(rate), left: &l, right: &r)
    // 0.3…0.6 s: the burst (and the motor's spin-up) is long over
    let tail = Int(rate * 0.3)..<Int(rate * 0.6)
    #expect(rms(out[tail]) > 1e-3, "the room rings: \(rms(out[tail]))")
    #expect(rms(l[tail]) == 0, "LOOP record hears the deck dry")
  }

  @Test func theKnobsReachTheUnit() throws {
    let (dj, a) = try engine(wet: 0)
    dj.perform(.param(deck: "A", name: "reverbWet", value: 0.4))
    dj.perform(.param(deck: "A", name: "reverbSize", value: 1))
    dj.perform(.param(deck: "A", name: "reverbTone", value: 0))
    #expect(abs(a.reverb.parameter(kReverb2Param_DryWetMix) - 40) < 1e-3)
    #expect(abs(a.reverb.parameter(kReverb2Param_DecayTimeAt0Hz) - 8) < 1e-3)
    #expect(a.reverb.parameter(kReverb2Param_DecayTimeAtNyquist) < 1, "dark: the highs die first")
    dj.perform(.param(deck: "L", name: "reverbWet", value: 0.3))
    #expect(dj.loopChannel.reverb.wet == 0.3 && !dj.loopChannel.reverb.node.bypass)
  }

  @Test func sessionsKeepTheReverbAndOldSetsKeepTheirText() {
    let plain = DeckParams()
    #expect(plain.json["reverbWet"] == nil, "untouched: the canonical text is as before")
    var p = DeckParams()
    p.reverbWet = 0.3
    p.reverbSize = 0.7
    p.reverbTone = 0.2
    let back = DeckParams(json: p.json)
    #expect(back == p)
  }
}
