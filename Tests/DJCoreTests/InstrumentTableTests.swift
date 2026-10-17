import Darwin
import Testing

@testable import DJCore

struct InstrumentTableTests {
  let sr = 48_000.0
  let table = InstrumentTable.shared
  /// Entries with their own synth engine (the rest only add a sampler; SamplerTests).
  var plucked: [String] {
    table.names.filter { table.voice(instrument: $0, group: "melody").engine == "pluck" }
  }

  /// A guitar-ish phrase: a strummed chord, then single notes.
  static let phrase: [(note: Int, at: Double, seconds: Double)] = [
    (48, 0, 0.5), (52, 0.02, 0.5), (55, 0.04, 0.5), (60, 0.06, 0.5), (64, 0.5, 0.25),
    (67, 0.75, 0.25), (72, 1.0, 0.5),
  ]

  /// Does the entry give the instrument a voice of its own (not just a sampler)?
  func hasVoice(_ name: String) -> Bool {
    table.voice(instrument: name, group: "melody") != tonalVoice(instrument: name, group: "melody")
  }

  func render(_ name: String, _ notes: [(note: Int, at: Double, seconds: Double)], _ s: Double)
    -> [Float]
  {
    WaveRunner.audition(
      table.voice(instrument: name, group: "melody"), notes: notes, sampleRate: sr, seconds: s)
  }

  @Test func everyEntryIsABeatsInstrumentWithAKnownEngine() {
    var used = Set<String>()
    for set in BeatsTables.shared.instrumentSets.values {
      for pool in set.values { used.formUnion(pool) }
    }
    #expect(plucked.count >= 8)
    for n in table.names {
      #expect(used.contains(n), "\(n) is an instrument beats' generator picks")
      #expect(["table", "pluck"].contains(table.voice(instrument: n, group: "melody").engine))
    }
  }

  @Test func theParityPathIgnoresTheTable() {
    let plain = tonalVoice(instrument: "acoustic-guitar", group: "melody")
    #expect(plain.engine == "table")
    #expect(table.voice(instrument: "acoustic-guitar", group: "melody").engine == "pluck")
    #expect(
      table.voice(instrument: "supersaw", group: "melody")
        == tonalVoice(instrument: "supersaw", group: "melody"))
  }

  @Test(arguments: [
    "acoustic-guitar", "electric-guitar", "distorted-guitar", "harpsichord", "pluck",
    "bright-pluck",
  ])
  func stringsPlayInTune(_ name: String) {
    for note in [40, 52, 64, 76] {  // E2 82 Hz … E5 659 Hz: the guitar's range
      let a = render(name, [(note, 0, 1)], 0.5)
      let f = partialPeak(a[960..<20160], near: midiHz(note), sampleRate: sr)
      #expect(
        abs(cents(f, midiHz(note))) < 5, "\(name) note \(note): \(cents(f, midiHz(note))) cents")
    }
  }

  @Test func stringsRingAndDie() {
    for name in plucked {
      let a = render(name, [(57, 0, 2)], 3)
      let early = rmsDB(a[0..<2400])
      let late = rmsDB(a[(a.count - 4800)...])
      #expect(early > -40, "\(name) sounds (\(early) dB)")
      #expect(early - late > 20, "\(name) decays (\(early) → \(late) dB)")
    }
    // a palm-muted string dies much faster than a sustaining distorted one
    func t20(_ name: String) -> Int {
      let a = render(name, [(57, 0, 2)], 3)
      let ref = rmsDB(a[2400..<4800])
      var i = 4800
      while i + 2400 < a.count && rmsDB(a[i..<(i + 2400)]) > ref - 20 { i += 2400 }
      return i
    }
    #expect(t20("muted-pluck") * 3 < t20("distorted-guitar"))
  }

  @Test func levelsSitWithTheLeadVoice() {
    let lead = WaveRunner.audition(
      tonalVoice(instrument: "supersaw", group: "melody"), notes: Self.phrase, sampleRate: sr,
      seconds: 2)
    let ref = rmsDB(lead[...])
    // every entry with a voice of its own, not just the strings: a new one must sit in the mix
    for name in table.names where hasVoice(name) {
      let db = rmsDB(render(name, Self.phrase, 2)[...])
      #expect(abs(db - ref) < 3, "\(name) at \(db) dB vs lead \(ref) dB")
    }
  }

  /// The melody instruments that all fell into the default saw (beats' `tonalVoice`) now each
  /// sound like themselves: none renders the same as the plain saw lead.
  @Test func melodyLeadsNoLongerShareOneSaw() {
    let saw = WaveRunner.audition(
      tonalVoice(instrument: "supersaw", group: "melody"), notes: Self.phrase, sampleRate: sr,
      seconds: 2)
    let names = [
      "flute", "trumpet", "sax", "brass", "sync-lead", "lead", "duo-lead", "detuned-saw",
      "distorted-lead", "hoover", "wobble-lead", "screech", "big-saw", "trance-lead", "talkbox",
      "tape-lead", "scream-lead", "laser",
    ]
    for name in names {
      #expect(hasVoice(name), "\(name) has its own voice")
      #expect(render(name, Self.phrase, 2) != saw, "\(name) is not the plain saw")
    }
  }

  /// A laser is a zap: each note starts 12× high and dives exponentially to 0.42× over 0.4 s
  /// (beats' stinger one-shot: 3200 → 110 Hz at C4), then dies. Pitch by zero crossings (two
  /// per cycle of a saw): a bright sweep through kilohertz fools an autocorrelation by octaves.
  @Test func laserZaps() {
    let a = render("laser", [(60, 0, 0.5)], 0.5)
    let voice = table.voice(instrument: "laser", group: "melody")
    #expect(voice.pitchTime == 0.4 && voice.pitchFrom > voice.pitchTo)
    func expected(_ t: Double) -> Double {
      midiHz(60) * voice.pitchFrom * pow(voice.pitchTo / voice.pitchFrom, t / voice.pitchTime)
    }
    func measured(_ t: Double, _ span: Double) -> Double {
      let lo = Int(t * sr)
      let hi = Int((t + span) * sr)
      var crossings = 0
      for i in (lo + 1)..<hi where (a[i - 1] < 0) != (a[i] < 0) { crossings += 1 }
      return Double(crossings) / 2 / span
    }
    var last = Double.infinity
    for (t, span) in [(0.01, 0.01), (0.05, 0.02), (0.1, 0.03), (0.2, 0.05)] {
      let f = measured(t, span)
      let want = expected(t + span / 2)
      #expect(abs(cents(f, want)) < 100, "at \(t) s: \(f) Hz vs \(want) Hz")
      #expect(f < last, "it falls")
      last = f
    }
    #expect(rmsDB(a[Int(0.45 * sr)...]) < rmsDB(a[0..<4800]) - 20, "and dies")
  }

  @Test func sitarBends() {
    let a = render("sitar", [(57, 0, 2)], 0.8)
    let fs = stride(from: 2400, to: 26_400, by: 1200).map {
      fundamental(a[$0..<($0 + 4800)], sampleRate: sr)
    }
    let spread = cents(fs.max()!, fs.min()!)
    #expect(spread > 10 && spread < 80, "vibrato spread \(spread) cents")
    let guitar = render("acoustic-guitar", [(57, 0, 2)], 0.8)
    let gs = stride(from: 2400, to: 26_400, by: 1200).map {
      fundamental(guitar[$0..<($0 + 4800)], sampleRate: sr)
    }
    #expect(cents(gs.max()!, gs.min()!) < 5)
  }

  @Test func auditionsAreDeterministic() {
    #expect(render("electric-guitar", Self.phrase, 1) == render("electric-guitar", Self.phrase, 1))
  }

  @Test func appTracksGetTheirStrings() {
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let p = compose(genre: "country", overrides: .object(ov))
    let ext = WaveRunner.prepare(p, sampleRate: sr, opts: .extended)
    let plain = WaveRunner.prepare(p, sampleRate: sr)
    let instruments = p.nets.values.compactMap { $0.track.instrument }
    if instruments.contains(where: { table.entries[$0] != nil }) {
      #expect(ext.lanes.contains { $0.isPluck })
    }
    #expect(!plain.lanes.contains { $0.isPluck })
  }
}
