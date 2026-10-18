@preconcurrency import AVFoundation
import Testing

@testable import DJCore

// One loudness (LevelMatch.swift): a generated track, a sample, a stock loop and a take of
// either all land at `LevelMatch.referenceLUFS` at unity knobs.

private let sr = 48_000.0

/// `seconds` of three sines (100 Hz, 1 kHz, 5 kHz: energy across the spectrum, a "full mix"
/// to `SampleLevel`), each at `amplitude`, plus a spike of `spike` at the middle if given.
private func tones(
  _ amplitude: Float, seconds: Double = 4, hz: [Double] = [100, 1000, 5000], spike: Float? = nil
) -> SampleBuffer {
  let n = Int(seconds * sr)
  var l = [Float](repeating: 0, count: n)
  for i in 0..<n {
    var s = 0.0
    for f in hz { s += sin(2 * Double.pi * f * Double(i) / sr) }
    l[i] = amplitude * Float(s)
  }
  if let spike { l[n / 2] = spike }
  return SampleBuffer(left: l, right: l, sampleRate: sr)
}

/// Render a deck's source block (pre-EQ, pre-fader: what the deck plays) for `seconds`.
private func play(_ deck: Deck, seconds: Double) -> (left: [Float], right: [Float]) {
  var l: [Float] = []
  var r: [Float] = []
  var done = 0
  let total = Int(seconds * sr)
  while done < total {
    let n = min(512, total - done)
    let b = renderThroughBufferList(deck, frames: n)
    l += b.left
    r += b.right
    done += n
  }
  return (l, r)
}

private func lufs(_ x: (left: [Float], right: [Float])) -> Double {
  IntegratedLoudness.integrated(left: x.left, right: x.right, sampleRate: sr) ?? -200
}

private func peakDB(_ x: (left: [Float], right: [Float])) -> Double {
  let p = max(x.left.map(abs).max() ?? 0, x.right.map(abs).max() ?? 0)
  return ampDB(Double(max(p, 1e-10)))
}

/// The calibration surveys below are measurements (minutes, and the sampled ones depend on
/// what this Mac has installed), not checks: with `DJ_LEVEL_SURVEY=1` set, `LevelSurveyTests`
/// prints their numbers (docs/musicality-notes.md §10; a release build takes about three
/// minutes, a debug one far longer).
private let surveying = ProcessInfo.processInfo.environment["DJ_LEVEL_SURVEY"] != nil

/// The genres the surveys play (the matrix's first ten).
private let surveyGenres = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz", "funk",
]

private func meanSD(_ x: [Double]) -> (mean: Double, sd: Double) {
  guard !x.isEmpty else { return (0, 0) }
  let m = x.reduce(0, +) / Double(x.count)
  let v = x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
  return (m, v.squareRoot())
}

private func f1(_ x: Double) -> String { String(format: "%.1f", x) }

@MainActor
struct LevelMatchTests {
  // MARK: the meter

  /// BS.1770's own check: a 1 kHz sine at −20 dBFS on both channels reads −20 + 3 + 0.69 −
  /// 0.69 ≈ −17 LUFS (K-weighting is ~0 dB at 1 kHz, two channels add 3 dB).
  @Test func aSineReadsWhereBS1770SaysItShould() throws {
    let b = tones(0.1, hz: [997])  // −20 dBFS peak = −23 dBFS RMS
    let l = try #require(
      IntegratedLoudness.integrated(left: b.left, right: b.right, count: b.length, sampleRate: sr))
    #expect(abs(l - (-23.01 + 3.01 - 0.691 + 0.691)) < 0.3, "\(l)")
    // silence is nil, not −∞
    let quiet = [Float](repeating: 0, count: 48_000)
    #expect(IntegratedLoudness.integrated(left: quiet, right: quiet, sampleRate: sr) == nil)
  }

  // MARK: net decks

  /// Every genre's whole song, played by a deck on the app's path, lands at the reference
  /// (±1.5 LU), with its peaks under 0 dBFS (the limiter's ceiling, −1). Synth voices (the
  /// sampled ones depend on what this Mac has installed; `djctl render` measures those).
  @Test(arguments: ["techno", "house", "trance", "dnb", "lofi", "jazz"])
  func aNetTrackPlaysAtTheReference(genre: String) throws {
    let rate = 24_000.0
    let source = WaveDeckSource(sampleRate: rate, opts: .extended)
    let track = PreparedTrack(
      spec: TrackSpec(genre: genre, seed: 4242, structure: "standard"), sampleRate: rate,
      opts: .extended)
    let r = OfflineRender(track: track, source: source, seconds: 400)
    let l = try #require(
      IntegratedLoudness.integrated(left: r.left, right: r.right, sampleRate: rate))
    #expect(abs(l - LevelMatch.referenceLUFS) < 1.5, "\(genre): \(l) LUFS")
    #expect(r.metrics.peakDB < 0, "\(genre): peak \(r.metrics.peakDB) dBFS")
    #expect(r.metrics.peakDB <= PeakLimiter.ceilingDB + 0.01)
    // and the drums keep their attack: the limiter is mostly idle
    let st = try #require(source.limiter).statistics()
    #expect(st.percentilesDB[0] <= 0.5, "\(genre): median gain reduction \(st.percentilesDB[0]) dB")
  }

  /// The parity path is beats': no limiter, beats' tanh, no loudness gain.
  @Test func theParityPathHasNoLimiter() {
    #expect(WaveDeckSource(sampleRate: sr, opts: WaveOptions()).limiter == nil)
    #expect(WaveOptions().master == "soft")
    #expect(WaveDeckSource(sampleRate: sr, opts: .extended).limiter != nil)
    #expect(WaveOptions.extended.master == "limit")
  }

  // MARK: the limiter

  @Test func theLimiterHoldsTheCeilingAndPassesQuietAudioUntouched() {
    let lim = PeakLimiter(sampleRate: sr)
    let n = 48_000
    var l = (0..<n).map { Float(2 * sin(2 * Double.pi * 100 * Double($0) / sr)) }  // +6 dBFS
    var r = l
    let ceiling = Float(pow(10, PeakLimiter.ceilingDB / 20))
    lim.process(&l, &r, frames: n)
    #expect((l.map(abs).max() ?? 0) <= ceiling + 1e-6)
    #expect(lim.gainReductionDB > 6)
    // quiet: the input exactly, `lookahead` samples late
    let q = PeakLimiter(sampleRate: sr)
    let x = (0..<4096).map { Float(0.3 * sin(Double($0) * 0.05)) }
    var a = x
    var b = x
    q.process(&a, &b, frames: x.count)
    #expect(Array(a[q.lookahead...]) == Array(x[..<(x.count - q.lookahead)]))
    #expect(q.gainReductionDB == 0)
  }

  // MARK: sample decks

  @Test func aSampleLoadsAtTheReference() throws {
    let dj = try DJEngine(offline: true, sampleRate: sr)
    let a = try #require(dj["A"])
    let quiet = tones(0.01)  // about −30 LUFS, peak −30 dBFS: room to lift it
    let level = quiet.level
    #expect(!level.partial)
    dj.perform(.param(deck: "A", name: "autoGain", value: 1))  // the app's default; off in DJCore
    a.load(quiet, title: "quiet")
    #expect(a.autoGainDB == level.autoGainDB && a.autoGainDB > 0)
    a.setPlaying(true)
    let out = play(a, seconds: 3)
    let measured = lufs((Array(out.left[24_000...]), Array(out.right[24_000...])))
    let expected = min(LevelMatch.referenceLUFS, try #require(level.lufs) + LevelMatch.maxGainDB)
    #expect(abs(measured - expected) < 0.5, "\(measured) LUFS")
    #expect(peakDB(out) <= LevelMatch.samplePeakCeilingDB + 0.01)
  }

  @Test func theAutoGainIsClampedAndCappedByThePeak() throws {
    // near silence: at most +12 dB
    let silent = tones(0.0005).level
    #expect(silent.autoGainDB == LevelMatch.maxGainDB)
    // very loud: at most −12 dB
    let hot = tones(0.33, seconds: 4).level
    #expect(hot.autoGainDB >= -LevelMatch.maxGainDB && hot.autoGainDB < 0)
    // quiet but with a peak near full scale: not lifted past −1 dBFS
    let spiky = tones(0.01, spike: 0.95).level
    #expect(spiky.autoGainDB <= max(0, LevelMatch.samplePeakCeilingDB - spiky.peakDB) + 0.01)
    #expect(spiky.autoGainDB < 1)
    // digital silence: no gain
    let zero = SampleBuffer(left: [Float](repeating: 0, count: 48_000), sampleRate: sr)
    #expect(zero.level.lufs == nil && zero.level.autoGainDB == 0)
  }

  /// A loop with one band of a mix (a sub bass, or hats) is aimed under a full mix.
  @Test func partialLoopsSitUnderAFullMix() throws {
    let bass = tones(0.01, hz: [60]).level
    #expect(bass.partial && bass.lowShare > 0.9)
    #expect(bass.targetLUFS == LevelMatch.referenceLUFS + LevelMatch.partialOffsetDB)
    let hats = tones(0.01, hz: [7000, 9000]).level
    #expect(hats.partial && hats.highShare > 0.5)
    let full = tones(0.01).level
    #expect(!full.partial && full.targetLUFS == LevelMatch.referenceLUFS)
  }

  @Test func autoGainOffPlaysTheAudioAsItIs() throws {
    let dj = try DJEngine(offline: true, sampleRate: sr)
    let a = try #require(dj["A"])
    dj.perform(.param(deck: "A", name: "autoGain", value: 0))
    #expect(!a.autoGain)
    let b = tones(0.01)
    a.load(b, title: "as is")
    #expect(a.autoGainDB == 0 && a.sampleLevel != nil)
    a.setPlaying(true)
    let out = play(a, seconds: 0.5)
    // full speed from the start is not guaranteed (motor spin-up), so compare levels
    #expect(abs(peakDB(out) - b.level.peakDB) < 0.2)
    // on again: the gain glides in
    dj.perform(.param(deck: "A", name: "autoGain", value: 1))
    #expect(a.autoGainDB == b.level.autoGainDB)
  }

  @Test func theSettingIsADeckParamThatRoundTrips() throws {
    var p = DeckParams()
    #expect(!p.autoGain, "off by default, as Deck's")
    #expect(p.json["autoGain"] == nil, "default off the wire: old sessions keep their CID")
    p.autoGain = true
    #expect(p.json["autoGain"] == .bool(true))
    #expect(DeckParams(json: p.json).autoGain == true)
    #expect(DeckParams(json: DeckParams().json).autoGain == false)
    #expect(try DJEngine(offline: true, sampleRate: sr)["A"]?.autoGain == false)
    let act = DeckAction.param(deck: "A", name: "autoGain", value: 0)
    #expect(DeckAction(json: act.json) == act)
  }

  /// A session from before level matching has no `autoGain` key: it replays its sample at the
  /// sample's own level, byte for byte what it played; one recorded with it on is levelled.
  @Test func anOldSessionWithoutTheKeyReplaysAsBefore() throws {
    let rate = 24_000.0
    func session(_ params: DeckParams?) -> Session {
      Session(
        sampleRate: rate, frames: 24_000,
        decks: ["A": .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil)],
        params: params.map { ["A": $0] } ?? [:], crossfader: 0.5, master: 1,
        events: [SessionEvent(frame: 0, kind: .action(.play(deck: "A", on: true)))])
    }
    let old = session(DeckParams())
    #expect(!old.canonical.contains("autoGain"))
    let revived = try Session.decode(old.canonical, cid: old.cid)
    #expect(revived.params["A"]?.autoGain == false)
    let replay = try SessionPlayer(session: revived).render()
    #expect(replay.left.contains { $0 != 0 })
    // the same as no params at all, and as the setting off
    var off = DeckParams()
    off.autoGain = false
    #expect(try SessionPlayer(session: session(nil)).render().left == replay.left)
    #expect(try SessionPlayer(session: session(off)).render().left == replay.left)
    // on: the demo loop is levelled, so it plays differently
    #expect(DemoLoop.make(sampleRate: rate).level.autoGainDB != 0)
    var on = DeckParams()
    on.autoGain = true
    let levelled = session(on)
    #expect(levelled.canonical.contains("autoGain") && levelled.cid != old.cid)
    #expect(try SessionPlayer(session: levelled).render().left != replay.left)
  }

  /// The same buffer always measures the same: the gain is derived, never recorded.
  @Test func theAutoGainIsAPureFunctionOfTheAudio() {
    let a = tones(0.02)
    let b = tones(0.02)
    #expect(a.level == b.level)
    #expect(a.level == SampleLevel(a))
  }

  // MARK: takes

  /// A take of a net deck is the deck after its EQ (flat here), so on another deck (no
  /// auto-gain: a clip keeps the level it was taken at) it plays at the net deck's loudness.
  @Test func aTakeOfANetDeckPlaysAtTheDecksLevel() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    let out = AVAudioPCMBuffer(
      pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: 512)!
    func run(to frame: Int) throws {
      while dj.frame < frame {
        _ = try dj.engine.renderOffline(AVAudioFrameCount(min(512, frame - dj.frame)), to: out)
        for d in dj.allDecks {
          d.turntable.drainRetired()
          d.service()
        }
        dj.serviceLoopTakes()
      }
    }
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(
        genre: "techno", seed: 4242, structure: nil, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let bar = 96_000
    try run(to: 2 * bar + 100)
    #expect(dj.loopRecord("A", on: true, bars: 2))
    #expect(dj.loopRecord("A", on: false))  // a tap: exactly the 2 bars
    let count = dj.clips.count
    while dj.clips.count == count && dj.frame < 8 * bar { try run(to: dj.frame + 512) }
    let clip = try #require(dj.clips.last)
    let take = (
      Array(UnsafeBufferPointer(start: clip.buffer.left, count: clip.buffer.length)),
      Array(UnsafeBufferPointer(start: clip.buffer.right, count: clip.buffer.length))
    )
    // the deck's own loudness over the same span (its meter, pre-EQ = post-flat-EQ)
    let deckLUFS = a.shortTermLUFS
    let takeLUFS = lufs(take)
    #expect(abs(takeLUFS - deckLUFS) < 1.5, "take \(takeLUFS), deck \(deckLUFS)")
    // on B: no auto-gain on a clip, and it sounds at the take's level
    a.setPlaying(false)
    dj.perform(.clip(deck: "B", id: clip.id))
    let b = try #require(dj["B"])
    #expect(b.sampleLevel == nil && b.autoGainDB == 0)
    b.setPlaying(true)
    let start = b.renderedFrames
    try run(to: dj.frame + 2 * bar + 24_000)
    var l: [Float] = []
    var r: [Float] = []
    _ = b.capture.copy(from: start + 24_000, to: start + 24_000 + 2 * bar, left: &l, right: &r)
    // (within 1 LU, not 0.5: the clip is seeked onto A's beat at a fractional sample, and the
    // turntable's interpolation there softens the top that K-weighting counts — measured
    // −0.75 LU at a half-sample phase, with the peak unchanged)
    #expect(abs(lufs((l, r)) - takeLUFS) < 1, "B \(lufs((l, r))), take \(takeLUFS)")
  }
}

/// What the level calibration was set from. Each prints a table; they assert only that they
/// measured something (DJ_LEVEL_SURVEY, above).
@MainActor
struct LevelSurveyTests {
  /// `Loudness.sampledPartDB`: each part soloed (seed 4242, 40 s, standard structure, no
  /// loudness gain, no limiter) on the deck's sampled instrument and on its synth voice, under
  /// the default palette (Studio). Parts that stay synth voices (a `keepSynth` pick, or nothing
  /// installed) are left out.
  @Test(.enabled(if: surveying, "a measurement: DJ_LEVEL_SURVEY=1"))
  func sampledPartsAgainstTheirSynthVoices() throws {
    let rate = 24_000.0
    var byGroup: [String: [Double]] = [:]
    var lines: [String] = []
    for genre in surveyGenres {
      var row = genre.padding(toLength: 10, withPad: " ", startingAt: 0)
      for group in ["bass", "harmony", "melody", "arp"] {
        func render(sampled: Bool) -> (lufs: Double?, sampled: Bool) {
          var deckOpts = WaveOptions.extended
          deckOpts.master = "linear"
          let source = WaveDeckSource(sampleRate: rate, opts: deckOpts)
          var o = WaveOptions.extended(
            samplers: sampled ? source.samplers : nil, seed: 4242,
            roleFilter: RoleFilter(solo: [group]))
          o.master = "linear"
          o.trackGain = 1
          let track = PreparedTrack(
            spec: TrackSpec(genre: genre, seed: 4242, structure: "standard"), sampleRate: rate,
            opts: o)
          let r = OfflineRender(track: track, source: source, seconds: 40)
          return (
            IntegratedLoudness.integrated(left: r.left, right: r.right, sampleRate: rate),
            track.prepared.sampledGroups.values.contains(group)
          )
        }
        let s = render(sampled: true)
        guard s.sampled, let sl = s.lufs, let yl = render(sampled: false).lufs else {
          row += "      —"
          continue
        }
        byGroup[group, default: []].append(sl - yl)
        row += String(format: " %6.1f", sl - yl)
      }
      lines.append(row)
    }
    print("sampled − synth, LU (seed 4242, 40 s)\ngenre        bass   harm    mel    arp")
    for l in lines { print(l) }
    for g in ["bass", "harmony", "melody", "arp"] {
      let x = byGroup[g] ?? []
      let (m, sd) = meanSD(x)
      print(
        "\(g): \(f1(m)) ± \(f1(sd)) LU over \(x.count) genres; now \(Loudness.sampledPartDB[g] ?? Loudness.sampledPartDB["melody"]!)"
      )
    }
    #expect(!byGroup.isEmpty, "no part played on a sampler: nothing installed?")
  }

  /// `Loudness.targetDB` and `range` against whole songs as a deck plays them (seed 4242,
  /// standard structure, to the end): integrated loudness, peak, the gain the probe chose (and
  /// whether `range` held it), and the limiter's gain reduction. Synth voices, then sampled.
  @Test(.enabled(if: surveying, "a measurement: DJ_LEVEL_SURVEY=1"))
  func wholeSongsAgainstTheReference() throws {
    let rate = 24_000.0
    for sampled in [false, true] {
      print(
        (sampled ? "sampled" : "synth")
          + ": genre  LUFS  peak  gain(dB)  GR p50/p95/p99/max  limited%")
      var all: [Double] = []
      for genre in surveyGenres {
        let source = WaveDeckSource(sampleRate: rate, opts: .extended)
        let track = PreparedTrack(
          spec: TrackSpec(genre: genre, seed: 4242, structure: "standard"), sampleRate: rate,
          opts: .extended(samplers: sampled ? source.samplers : nil, seed: 4242))
        let r = OfflineRender(track: track, source: source, seconds: 400)
        guard let l = IntegratedLoudness.integrated(left: r.left, right: r.right, sampleRate: rate)
        else { continue }
        all.append(l)
        let g = track.prepared.gain
        let clamp =
          g >= Loudness.range.max - 1e-9 ? " (max)" : g <= Loudness.range.min + 1e-9 ? " (min)" : ""
        let st = try #require(source.limiter).statistics()
        let p = st.percentilesDB
        print(
          "  \(genre.padding(toLength: 10, withPad: " ", startingAt: 0)) \(f1(l)) \(f1(r.metrics.peakDB)) "
            + "\(f1(ampDB(g)))\(clamp)  \(p.map(f1).joined(separator: "/"))/\(f1(st.maxDB))  "
            + "\(f1(100 * st.limitedShare))")
      }
      let (m, sd) = meanSD(all)
      print(
        "  mean \(f1(m)) ± \(f1(sd)) LUFS, \(f1(all.min() ?? 0))…\(f1(all.max() ?? 0)); "
          + "reference \(LevelMatch.referenceLUFS)")
      #expect(!all.isEmpty)
    }
  }

  /// The loop channel ("L") at its defaults against a deck at the centred crossfader, on the
  /// master: a take of a net deck (the deck's own level, `aTakeOfANetDeckPlaysAtTheDecksLevel`)
  /// looped on L alone, against the deck alone. A/B take the crossfader's equal-power −3 dB at
  /// the centre and L none (`DJEngine.crossfadeGain`); L's trim starts at −3 dB to match
  /// (`DJEngine.loopChannelGain`; 2.9 LU over A before it, `LoopChannelLevelTests` holds it).
  @Test(.enabled(if: surveying, "a measurement: DJ_LEVEL_SURVEY=1"))
  func theLoopChannelAgainstACentredDeck() async throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    #expect(dj.crossfader == 0.5)
    let out = AVAudioPCMBuffer(pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: 512)!
    var capL: [Float] = []
    var capR: [Float] = []
    var capturing = false
    func run(to frame: Int) throws {
      while dj.frame < frame {
        _ = try dj.engine.renderOffline(AVAudioFrameCount(min(512, frame - dj.frame)), to: out)
        if capturing, let ch = out.floatChannelData {
          let k = Int(out.frameLength)
          capL += UnsafeBufferPointer(start: ch[0], count: k)
          capR += UnsafeBufferPointer(start: ch[out.format.channelCount > 1 ? 1 : 0], count: k)
        }
        for d in dj.allDecks {
          d.turntable.drainRetired()
          d.service()
        }
        dj.serviceLoopTakes()
      }
    }
    let a = try #require(dj["A"])
    await a.generate(
      TrackSpec(
        genre: "techno", seed: 4242, structure: nil, extra: JSONObject([("bpm", .number(120))])))
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    let bar = 96_000
    try run(to: 2 * bar + 100)
    #expect(dj.loopRecord("A", on: true, bars: 2))
    #expect(dj.loopRecord("A", on: false))
    let count = dj.clips.count
    while dj.clips.count == count && dj.frame < 8 * bar { try run(to: dj.frame + 512) }
    let clip = try #require(dj.clips.last)
    let take = (
      Array(UnsafeBufferPointer(start: clip.buffer.left, count: clip.buffer.length)),
      Array(UnsafeBufferPointer(start: clip.buffer.right, count: clip.buffer.length))
    )
    // a new take loops on L at once: out of it first, so the master holds A alone
    dj.setLooping(clip.id, false)
    while dj.loopState(clip.id) != .off && dj.frame < 40 * bar { try run(to: dj.frame + 512) }
    try run(to: dj.frame + bar)
    // A on the master, 4 bars, and before its fader
    let aStart = a.renderedFrames
    capturing = true
    try run(to: dj.frame + 4 * bar)
    capturing = false
    let aOut = lufs((capL, capR))
    var pl: [Float] = []
    var pr: [Float] = []
    _ = a.capture.copy(from: aStart, to: aStart + 4 * bar, left: &pl, right: &pr)
    let aPre = lufs((pl, pr))
    // A out; the take looping on L, 4 bars once it sounds (and A's tail has gone)
    a.setPlaying(false)
    dj.playClip(clip.id, on: dj.loopChannel.name)
    while dj.loopState(clip.id) != .on && dj.frame < 40 * bar { try run(to: dj.frame + 512) }
    #expect(dj.loopState(clip.id) == .on)
    try run(to: dj.frame + 2 * bar)
    capL = []
    capR = []
    capturing = true
    try run(to: dj.frame + 4 * bar)
    capturing = false
    let lOut = lufs((capL, capR))
    let takeLUFS = lufs(take)
    print(
      "loop channel: A pre-fader \(f1(aPre)), A on the master \(f1(aOut)) (crossfader 0.5, "
        + "trim \(a.trim), volume \(a.volume)); take \(f1(takeLUFS)), L on the master "
        + "\(f1(lOut)) (trim \(dj.loopChannel.trim), volume \(dj.loopChannel.volume)); "
        + "gap L − A \(String(format: "%.2f", lOut - aOut)) LU, channel gains alone "
        + "\(String(format: "%.2f", (lOut - takeLUFS) - (aOut - aPre))) dB; strip volumes A "
        + "\(a.strip.outputVolume), L \(dj.loopChannel.strip.outputVolume), master \(dj.master)")
    #expect(lOut > -100 && aOut > -100)
  }
}
