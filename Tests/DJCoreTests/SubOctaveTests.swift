import Darwin
import Testing

@testable import DJCore

// `DJMusicality.Fixes.subOctave`: a sine an octave under the synth basses of dnb, dubstep and
// trap (`SubOctave`, `WaveOptions.subOctave`), measured on mono renders of one-note projects
// through a linear master. 120 BPM.

private let sr = 48_000.0

private func bassNote(_ note: Int, steps: Int = 8, group: String = "bass") -> Project {
  var p = Project()
  p.tempo = 120
  var n = NetBundle.ring(64)
  n.bind(0, note: note, channel: 6, velocity: 100, duration: 0)
  n.bindings["t0"]?.durationSteps = steps
  n.track.channel = 6
  n.track.group = group
  p.nets[group] = n
  return p
}

private func render(
  _ p: Project, _ fixes: DJMusicality.Fixes, sub: Bool, seconds: Double = 1.0
) -> [Float] {
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.subOctave = sub
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var out = [Float](repeating: 0, count: Int(seconds * sr))
  out.withUnsafeMutableBufferPointer { b in
    var off = 0
    while off < b.count {
      let n = min(256, b.count - off)
      r.process(b.baseAddress! + off, nil, frames: n)
      off += n
    }
  }
  return out
}

private func window(_ x: [Float], _ a: Double, _ b: Double) -> ArraySlice<Float> {
  x[Int(a * sr)..<Int(b * sr)]
}

struct SubOctaveTests {
  /// On for dnb, dubstep and trap when the deck's fixes hold it; off for every other genre, and
  /// never on the parity path (`WaveOptions()` holds no fixes).
  @Test func theGenresThatPlayIt() {
    for g in ["dnb", "dubstep", "trap"] {
      #expect(WaveOptions.extended.forGenre(g).subOctave, "\(g)")
      #expect(!WaveOptions().forGenre(g).subOctave, "\(g) parity")
    }
    for g in ["techno", "house", "trance", "ambient", "jazz"] {
      #expect(!WaveOptions.extended.forGenre(g).subOctave, "\(g)")
    }
    #expect(DJMusicality.Fixes.all.contains(.subOctave))
    #expect(DJMusicality.Fixes.named["subOctave"] == .subOctave)
    #expect(Loudness.voiceFixes.contains(.subOctave))
    #expect(!WaveOptions().subOctave)
  }

  /// A bass on A2 (110 Hz) gains a sine on A1 (55 Hz), in tune, about 6 dB under its
  /// fundamental; the note itself is unchanged.
  @Test func aBassNoteGetsItsSubOctave() {
    let f0 = midiHz(45)
    let p = bassNote(45)
    let before = render(p, .subOctave, sub: false)
    let after = render(p, .subOctave, sub: true)
    let w = { (x: [Float]) in window(x, 0.05, 0.45) }
    let subBefore = toneDB(w(before), f0 / 2, sampleRate: sr)
    let subAfter = toneDB(w(after), f0 / 2, sampleRate: sr)
    #expect(subAfter - subBefore > 20, "sub \(subBefore) → \(subAfter) dB")
    let pitch = partialPeak(w(after), near: f0 / 2, sampleRate: sr)
    #expect(abs(cents(pitch, f0 / 2)) < 5, "sub at \(pitch) Hz")
    let fund = toneDB(w(after), f0, sampleRate: sr)
    #expect(abs(fund - toneDB(w(before), f0, sampleRate: sr)) < 0.5)
    // −6 dB under the voice's oscillator: beats' table's fundamental is its own level
    #expect(fund - subAfter > -1 && fund - subAfter < 12, "fund \(fund), sub \(subAfter)")
  }

  /// A note whose sub would sit under 30 Hz (A1, 55 Hz: a 27.5 Hz sub) plays without one.
  @Test func noSubUnderThirtyHertz() {
    let p = bassNote(33)
    #expect(
      sameSamples(render(p, .subOctave, sub: false), render(p, .subOctave, sub: true)) == .identical
    )
    // B1 (61.7 Hz) has one
    let q = bassNote(35)
    #expect(
      sameSamples(render(q, .subOctave, sub: false), render(q, .subOctave, sub: true)) != .identical
    )
  }

  /// Only the bass: a melody note is untouched, and so is everything without the fix.
  @Test func onlyTheBass() {
    let lead = bassNote(57, group: "melody")
    #expect(
      sameSamples(render(lead, .subOctave, sub: false), render(lead, .subOctave, sub: true))
        == .identical)
    let bass = bassNote(45)
    #expect(sameSamples(render(bass, [], sub: false), render(bass, [], sub: true)) == .identical)
  }

  /// A dnb track's synth bass lanes get a sub; a techno track's don't.
  @Test func dnbsBassHasOneTechnosDoesNot() {
    let dnb = PreparedTrack(
      spec: TrackSpec(genre: "dnb", seed: 42, structure: "minimal"), sampleRate: sr)
    #expect(dnb.opts.subOctave)
    #expect(dnb.prepared.lanes.contains { !$0.subPhase.isEmpty })
    for lane in dnb.prepared.lanes where !lane.subPhase.isEmpty {
      #expect(lane.isTonal && !lane.isPluck)
      #expect(lane.subPhase.count == lane.poly)
    }
    let techno = PreparedTrack(
      spec: TrackSpec(genre: "techno", seed: 42, structure: "minimal"), sampleRate: sr)
    #expect(!techno.opts.subOctave)
    #expect(!techno.prepared.lanes.contains { !$0.subPhase.isEmpty })
  }
}
