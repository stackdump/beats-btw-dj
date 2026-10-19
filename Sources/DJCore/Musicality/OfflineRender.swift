import Foundation

/// A track rendered offline through a deck's net source (`WaveDeckSource`: the runner, its
/// samplers and the master chain), as the app would play it, with nothing on the speakers.
public struct OfflineRender {
  public var sampleRate: Double
  public var left: [Float]
  public var right: [Float]

  /// Render `track` from the top for up to `seconds` (or until the song stops itself).
  public init(track: PreparedTrack, source: WaveDeckSource, seconds: Double) {
    sampleRate = source.sampleRate
    let total = Int(seconds * sampleRate)
    left = [Float](repeating: 0, count: total)
    right = [Float](repeating: 0, count: total)
    source.load(track.prepared)
    source.play()
    let block = 512
    var done = 0
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        while done < total {
          let n = min(block, total - done)
          source.render(
            frames: n, left: l.baseAddress! + done, right: r.baseAddress! + done, startFrame: done)
          done += n
          if done % (block * 64) == 0 { source.drainRetired() }
          if source.hasEnded { break }
        }
      }
    }
    left.removeSubrange(done...)
    right.removeSubrange(done...)
    source.drainRetired()
  }

  public var metrics: AudioMetrics {
    AudioMetrics(left: left, right: right, sampleRate: sampleRate)
  }

  /// RMS (dB) of each section of `project` that the render holds whole, in song order: the
  /// arrangement's level contour (an intro and a breakdown under the drop).
  public func sectionLevels(_ project: Project) -> [(name: String, db: Double)] {
    let tempo = project.tempo > 0 ? project.tempo : 120
    let perStep = sampleRate * 60 / (tempo * 4)
    var out: [(String, Double)] = []
    var step = 0
    for s in project.structure {
      let a = Int(Double(step) * perStep)
      let b = Int(Double(step + s.steps) * perStep)
      step += s.steps
      guard b <= left.count, b > a else { break }
      var sum = 0.0
      for i in a..<b {
        let m = (Double(left[i]) + Double(right[i])) / 2
        sum += m * m
      }
      out.append((s.name, 10 * log10(max(sum / Double(b - a), 1e-20))))
    }
    return out
  }

  /// For each drop gap of `project` (`DJMusicality.dropGaps`) the render holds, the level of
  /// the beat before the drop against the beat before that, below 200 Hz (kick and bass), dB:
  /// about 0 when the rhythm section plays through, well under it when it stops.
  public func preDropDips(_ project: Project) -> [Double] {
    lowDips(project, at: DJMusicality.dropGaps(project), beat: DJMusicality.dropGapSteps)
  }

  /// For each band stop of `project` (`DJMusicality.bandStops`) the render holds, the level of
  /// the beat before the chorus against the beat before that, below 200 Hz (kick, bass, the
  /// low of the pads: under the lead, which plays on), dB: about 0 with the band playing
  /// through, well under it when it stops. Empty outside the song family (`bandStopGenre`).
  public func bandStopDips(_ project: Project, genre: String) -> [Double] {
    guard DJMusicality.bandStopGenre(genre) else { return [] }
    return lowDips(project, at: DJMusicality.bandStops(project), beat: DJMusicality.bandStopSteps)
  }

  /// Below 200 Hz, the level of `beat` steps from each of `starts` against the `beat` steps
  /// before it, dB; starts the render does not hold both sides of are left out.
  func lowDips(_ project: Project, at starts: [Int], beat: Int) -> [Double] {
    guard !starts.isEmpty else { return [] }
    let tempo = project.tempo > 0 ? project.tempo : 120
    let perStep = sampleRate * 60 / (tempo * 4)
    var low = [Double](repeating: 0, count: left.count)
    for i in 0..<left.count { low[i] = (Double(left[i]) + Double(right[i])) / 2 }
    for _ in 0..<2 {
      let b = biquad(type: "lowpass", fc: 200, q: 0.7071, sr: sampleRate)
      var z1 = 0.0
      var z2 = 0.0
      for i in 0..<low.count {
        let v = low[i]
        let y = b[0] * v + z1
        z1 = b[1] * v - b[3] * y + z2
        z2 = b[2] * v - b[4] * y
        low[i] = y
      }
    }
    func level(_ a: Int, _ b: Int) -> Double {
      var s = 0.0
      for i in a..<b { s += low[i] * low[i] }
      return 10 * log10(max(s / Double(max(1, b - a)), 1e-20))
    }
    var out: [Double] = []
    for g in starts {
      let a = Int(Double(g - beat) * perStep)
      let b = Int(Double(g) * perStep)
      let c = Int(Double(g + beat) * perStep)
      guard a >= 0, c <= low.count else { continue }
      out.append(level(b, c) - level(a, b))
    }
    return out
  }

  /// How the high band climbs through each riser window of `project` the render holds whole
  /// (`RiserRise`, `.riser`).
  public func riserRises(_ project: Project) -> [RiserRise] {
    RiserRise.measure(left: left, right: right, sampleRate: sampleRate, project: project)
  }

  /// The riser windows' mean rise (last beat over the first, high band, dB) and mean Spearman
  /// ρ, as `djctl render` reports them; nil without a window in the render.
  public func riserSummary(_ project: Project) -> (riseDB: Double, spearman: Double)? {
    let rises = riserRises(project)
    guard !rises.isEmpty else { return nil }
    let n = Double(rises.count)
    return (rises.map(\.riseDB).reduce(0, +) / n, rises.map(\.spearman).reduce(0, +) / n)
  }

  /// 16-bit PCM WAV, stereo.
  public func wav() -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let frames = left.count
    d.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + frames * 4))
    d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(2)
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate) * 4)
    u16(4)
    u16(16)
    d.append(contentsOf: Array("data".utf8))
    u32(UInt32(frames * 4))
    var pcm = [Int16](repeating: 0, count: frames * 2)
    for i in 0..<frames {
      pcm[2 * i] = Int16(max(-1, min(1, left[i])) * 32767)
      pcm[2 * i + 1] = Int16(max(-1, min(1, right[i])) * 32767)
    }
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
  }
}

/// Level and spectral balance of a stereo render: what gain staging and frequency layout
/// look like without listening.
public struct AudioMetrics: Sendable {
  public var peakDB = -200.0
  public var rmsDB = -200.0
  /// Peak over RMS, dB: low means squashed, very high means spiky and quiet.
  public var crestDB = 0.0
  /// Samples at or over full scale (|x| ≥ 0.999), either channel: clipping at the output.
  public var clipped = 0
  /// Share of the energy in each band (sums to 1): sub < 60 Hz, low 60–250, lowMid 250–2k,
  /// high 2k–6k, air > 6k.
  public var bands: [String: Double] = [:]
  /// RMS of 400 ms windows, dB, 10th and 95th percentile (quiet parts vs the loud ones).
  public var shortTermP10DB = -200.0
  public var shortTermP95DB = -200.0
  /// Side over mid energy, dB (side = (L − R) / 2): −200 for mono, around −10 for a wide mix.
  public var sideDB = -200.0
  /// The same below 150 Hz, where a mix should stay mono (kick and bass in the middle).
  public var lowSideDB = -200.0
  /// Long-term spectrum, slope, 16 kHz bump and mono fold, third-octave (`Spectrum`).
  public var spectrum = Spectrum(left: [], right: [], sampleRate: 0)

  public static let bandEdges: [(String, Double, Double)] = [
    ("sub", 20, 60), ("low", 60, 250), ("lowMid", 250, 2000), ("high", 2000, 6000),
    ("air", 6000, 20000),
  ]

  public init(left: [Float], right: [Float], sampleRate sr: Double) {
    let n = min(left.count, right.count)
    guard n > 0 else { return }
    var peak: Float = 0
    var sum = 0.0
    var mono = [Double](repeating: 0, count: n)
    for i in 0..<n {
      let a = abs(left[i])
      let b = abs(right[i])
      peak = max(peak, max(a, b))
      if a >= 0.999 || b >= 0.999 { clipped += 1 }
      sum += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i])
      mono[i] = (Double(left[i]) + Double(right[i])) / 2
    }
    peakDB = 20 * log10(max(Double(peak), 1e-10))
    rmsDB = 10 * log10(max(sum / Double(2 * n), 1e-20))
    crestDB = peakDB - rmsDB

    let win = Int(0.4 * sr)
    var st: [Double] = []
    var i = 0
    while i + win <= n {
      var s = 0.0
      for k in i..<(i + win) { s += mono[k] * mono[k] }
      st.append(10 * log10(max(s / Double(win), 1e-20)))
      i += win / 2
    }
    // Ignore digital silence (a stopped song's tail) in the percentiles.
    st = st.filter { $0 > -90 }.sorted()
    if !st.isEmpty {
      shortTermP10DB = st[st.count / 10]
      shortTermP95DB = st[min(st.count - 1, st.count * 95 / 100)]
    }

    // Band energies: fourth-order bandpasses (two cascaded RBJ high- and lowpasses).
    var energy: [String: Double] = [:]
    for (name, lo, hi) in Self.bandEdges {
      var x = mono
      for _ in 0..<2 { Self.filter(&x, biquad(type: "highpass", fc: lo, q: 0.7071, sr: sr)) }
      if hi < sr * 0.45 {
        for _ in 0..<2 { Self.filter(&x, biquad(type: "lowpass", fc: hi, q: 0.7071, sr: sr)) }
      }
      energy[name] = x.reduce(0) { $0 + $1 * $1 }
    }
    let total = energy.values.reduce(0, +)
    if total > 0 { bands = energy.mapValues { $0 / total } }

    var side = [Double](repeating: 0, count: n)
    for i in 0..<n { side[i] = (Double(left[i]) - Double(right[i])) / 2 }
    func ratio(_ s: [Double], _ m: [Double]) -> Double {
      let es = s.reduce(0) { $0 + $1 * $1 }
      let em = m.reduce(0) { $0 + $1 * $1 }
      return es > 0 && em > 0 ? 10 * log10(es / em) : -200
    }
    sideDB = ratio(side, mono)
    var lowS = side
    var lowM = mono
    for _ in 0..<2 {
      Self.filter(&lowS, biquad(type: "lowpass", fc: 150, q: 0.7071, sr: sr))
      Self.filter(&lowM, biquad(type: "lowpass", fc: 150, q: 0.7071, sr: sr))
    }
    lowSideDB = ratio(lowS, lowM)
    spectrum = Spectrum(left: left, right: right, sampleRate: sr)
  }

  private static func filter(_ x: inout [Double], _ b: [Double]) {
    var z1 = 0.0
    var z2 = 0.0
    for i in 0..<x.count {
      let v = x[i]
      let y = b[0] * v + z1
      z1 = b[1] * v - b[3] * y + z2
      z2 = b[2] * v - b[4] * y
      x[i] = y
    }
  }

  public var dictionary: [String: Any] {
    [
      "peakDB": round3(peakDB), "rmsDB": round3(rmsDB), "crestDB": round3(crestDB),
      "clippedSamples": clipped, "bands": bands.mapValues(round3),
      "shortTermP10DB": round3(shortTermP10DB), "shortTermP95DB": round3(shortTermP95DB),
      "sideDB": round3(sideDB), "lowSideDB": round3(lowSideDB),
      "spectrumHz": Spectrum.bandsHz, "ltasDB": spectrum.ltasDB.map(round3),
      "slopeDBPerOct": round3(spectrum.slopeDBPerOct), "hfBumpDB": round3(spectrum.hfBumpDB),
      "monoFoldLossDB": spectrum.monoFoldLossDB.map(round3),
      "monoFoldDB": round3(spectrum.monoFoldDB),
    ]
  }
}

/// How many melodic parts sound in one section of a track (`OfflineRender.layersPerSection`):
/// what `.layerBudget` caps, measured from the audio rather than read from the nets.
public struct SectionLayers: Equatable, Sendable {
  public var name: String
  /// The parts (`OfflineRender.layerParts`) at or above `layerFloorDB` against the mix there.
  public var parts: [String]
  /// Each part's level against the section's mix, dB (−200 for silence).
  public var levelsDB: [String: Double]
  public var layers: Int { parts.count }

  public var dictionary: [String: Any] {
    [
      "name": name, "layers": layers, "parts": parts,
      "levelsDB": levelsDB.mapValues { ($0 * 1000).rounded() / 1000 },
    ]
  }
}

extension OfflineRender {
  /// The melodic parts a layer count looks at (`MixBalance`'s names: bass, harmony as pad,
  /// melody as lead, arp).
  public static let layerParts = ["bass", "pad", "lead", "arp"]
  /// A part counts as a layer in a section when its solo is at least this loud against the mix.
  public static let layerFloorDB = -40.0

  /// Each section of `played` (what a deck plays): which melodic parts sound in it. Every part
  /// is rendered alone (`MixBalance.solo`: the other nets' notes out, so slots, mutes and rests
  /// still switch as composed) through the whole song with `opts`' fixes and rest schedule
  /// (`RestSchedule.build`, unless `opts.trackRests`), mono, synth voices, a linear master and
  /// one gain, at `sampleRate`, and its level in each section measured against the mix there,
  /// leaving out each section's first bar (where the last one's tails ring). Sections past
  /// `seconds` are left out. Offline only.
  public static func layersPerSection(
    _ played: Project, opts: WaveOptions, sampleRate: Double = 24_000, seconds: Double? = nil
  ) -> [SectionLayers] {
    var o = opts
    o.samplers = nil
    o.master = "linear"
    o.trackGain = 1
    if o.musicality.contains(.energy) && o.trackEnergy == nil {
      o.trackEnergy = EnergyCurve(project: played)
    }
    if o.musicality.contains(.balance) && o.trackBalance == nil {
      o.trackBalance = MixBalance.trims(
        for: played, fixes: o.musicality, family: MixBalance.family(genre: o.genre),
        hfTilt: o.hfTilt)
    }
    if o.trackRests == nil { o.trackRests = RestSchedule.build(played, fixes: o.musicality) }
    let tempo = played.tempo > 0 ? played.tempo : 120
    let perStep = sampleRate * 60 / (tempo * 4)
    var frames = Int(Double(NoteLog.length(played)) * perStep)
    if let seconds { frames = min(frames, Int(seconds * sampleRate)) }

    // the sections the render holds whole, as (name, first frame, end frame)
    var spans: [(name: String, a: Int, b: Int)] = []
    var step = 0
    for s in played.structure {
      let skip = min(16, s.steps / 4)
      let a = Int(Double(step + skip) * perStep)
      let b = Int(Double(step + s.steps) * perStep)
      step += s.steps
      guard b <= frames else { break }
      if b > a { spans.append((s.name, a, b)) }
    }
    func levels(_ p: Project) -> [Double] {
      let runner = WaveRunner(sampleRate: sampleRate, opts: o)
      runner.load(prepared: WaveRunner.prepare(p, sampleRate: sampleRate, opts: o))
      runner.play()
      var x = [Float](repeating: 0, count: frames)
      x.withUnsafeMutableBufferPointer { b in
        var n = 0
        while n < b.count {
          let m = min(512, b.count - n)
          runner.process(b.baseAddress! + n, nil, frames: m)
          n += m
          if runner.stopped { break }
        }
      }
      return spans.map { s in
        var sum = 0.0
        for i in s.a..<s.b { sum += Double(x[i]) * Double(x[i]) }
        return 10 * log10(max(sum / Double(s.b - s.a), 1e-20))
      }
    }
    let mix = levels(played)
    var solo: [String: [Double]] = [:]
    for name in layerParts { solo[name] = levels(MixBalance.solo(played, name)) }
    return spans.enumerated().map { i, s in
      var rel: [String: Double] = [:]
      for name in layerParts {
        let l = solo[name]![i]
        rel[name] = l <= -150 ? -200 : max(-200, l - mix[i])
      }
      return SectionLayers(
        name: s.name, parts: layerParts.filter { rel[$0]! >= layerFloorDB }, levelsDB: rel)
    }
  }
}
