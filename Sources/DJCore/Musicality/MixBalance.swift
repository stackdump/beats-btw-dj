import Foundation

/// How loud each part of a track is against the whole mix: the gain-staging picture a mixing
/// engineer gets by soloing channels. Each part is rendered alone (every other net's notes
/// taken out, so slots, mutes and sections still switch as composed) over the busiest section,
/// with the deck's fixes, and measured K-weighted like a loudness meter. Offline only.
public enum MixBalance {
  /// The parts measured: drum kinds by note (`drumKind`), tonal parts by group.
  public static let parts = ["kick", "snare", "hats", "bass", "pad", "lead", "arp"]

  /// The part a drum hit (`note` on a drum channel) or a tonal net's `group` belongs to; nil for
  /// what no part covers (stingers, fills, toms).
  static func part(drumNote note: Int?, group: String) -> String? {
    if let note {
      switch drumKind(note) {
      case "kick": return note == 36 || note == 35 ? "kick" : nil
      case "snare", "clap": return "snare"
      case "hat", "openhat": return note == 49 || note == 57 ? nil : "hats"
      default: return nil
      }
    }
    switch group {
    case "bass": return "bass"
    case "harmony", "pad": return "pad"
    case "melody": return "lead"
    case "arp": return "arp"
    default: return nil
    }
  }

  /// The part a lane plays: its drum kind (`kick`, `snare`, `clap`, `hat`, `openhat`, `crash`)
  /// or "tonal" with its group.
  static func part(kind: String, group: String) -> String? {
    switch kind {
    case "kick": return "kick"
    case "snare", "clap": return "snare"
    case "hat", "openhat": return "hats"
    case "tonal": return part(drumNote: nil, group: group)
    default: return nil
    }
  }

  /// `project` with only `part`'s notes left (control nets untouched; fills and crashes,
  /// which are no part's, silent).
  static func solo(_ project: Project, _ keep: String) -> Project {
    var p = project
    for id in p.nets.keys {
      guard var nb = p.nets[id] else { continue }
      if id.hasPrefix("fill-") {
        nb.bindings = OrderedMap()
        p.nets[id] = nb
        continue
      }
      guard nb.role != "control" else { continue }
      var bound = OrderedMap<MidiBinding>()
      for (t, b) in nb.bindings.pairs {
        let group = DJMusicality.part(nb)
        let ch = b.channel != 0 ? b.channel : nb.track.channel
        let which = part(drumNote: isDrumChannel(ch) ? b.note : nil, group: group)
        if which == keep { bound[t] = b }
      }
      nb.bindings = bound
      p.nets[id] = nb
    }
    return p
  }

  /// Where each part should sit against the others (`DJMusicality.Fixes.balance`), K-weighted
  /// dB: the kick and bass carry a groove, the lead sits just under them, snare and pad behind,
  /// the arp and hats as colour. A dance-mix rule of thumb; genres without a kick are balanced
  /// among the parts they have. `targets.json`'s `balance.default` (`MixTargets`): kick 0,
  /// bass −3, lead −4, snare −6, pad −7, arp −8, hats −10.
  public static let targetDB: [String: Double] = MixTargets.shared.balanceDB()
  /// The targets.json balance entry a family plays to (`GrooveTemplate.familyNames`): its own
  /// `balance.families` block when there is one, else jazz borrows chill's (the
  /// [RULE-OF-THUMB] jazz / lofi entry: bass −1, pad −4, lead −4, snare −8, hats −14, kick −2,
  /// arp the default's), else "default". nil family (raw nets, no genre) = "default".
  public static func entry(family: String?) -> String {
    let blocks = MixTargets.shared.balance.families
    guard let family else { return "default" }
    if blocks[family] != nil { return family }
    if let f = borrowed[family], blocks[f] != nil { return f }
    return "default"
  }
  /// Families with no block of their own that play to another's.
  static let borrowed = ["jazz": "chill"]

  /// The balance targets for `family`: `targetDB` with its entry's parts (`entry(family:)`).
  public static func targets(family: String?) -> [String: Double] {
    let e = entry(family: family)
    return e == "default" ? targetDB : MixTargets.shared.balanceDB(family: e)
  }

  /// The family a genre's balance is looked up under (`BeatsTables.family(of:)`'s name); nil
  /// for no genre.
  public static func family(genre: String?) -> String? {
    guard let genre else { return nil }
    let i = BeatsTables.shared.family(of: genre)
    let names = GrooveTemplate.familyNames
    return names.indices.contains(i) ? names[i] : nil
  }

  /// A part moves at most this far (`balance.maxTrimDB`).
  public static let maxTrimDB = MixTargets.shared.balance.maxTrimDB.value!
  /// The rate the parts are measured at for `trims`.
  static let probeRate = 22_050.0

  /// The trim (dB) for each part of `project` that puts the parts in `family`'s targets'
  /// relation (`targets(family:)`; nil = `targetDB`), as
  /// near as `maxTrimDB` allows: each part soloed through the loudness probe (`Loudness.measure`:
  /// two bars of the busiest section, the voices `fixes` shape, at `probeRate`), then moved toward its target
  /// around the median of where they all are (so the mix as a whole moves little; `.loudness`
  /// sets its level after). Empty when fewer than two parts play.
  /// `hfTilt`: measure the hats through a tilt (diagnostics). The deck's own trims leave it nil:
  /// `.hfTilt` takes the hats' top off and means to leave the rest of them where it was
  /// (`lowersTheHatsTop`). Trims that heard the tilt (lofi's hats 5 dB under their untilted
  /// level) lifted the whole hat part back by up to that much and brought the 12.5 / 16 kHz
  /// bump back: synthwave 3.3 → 3.9 dB, synthwave sampled 1.3 → 2.1, bossa 1.4 → 2.1
  /// (HFTiltTests.everyGenreFallsWithNoBump, limit 2). The loudness probe does hear the tilt
  /// (`Loudness.gain(hfTilt:)`): that sets the level, not the hats' share of it.
  public static func trims(
    for project: Project, fixes: DJMusicality.Fixes = [], family: String? = nil,
    hfTilt: HFTilt? = nil
  ) -> [String: Double] {
    let targetDB = targets(family: family)
    let start = Loudness.busiestStart(project)
    var level: [String: Double] = [:]
    for name in parts {
      // (at a rate that hears hats: the loudness probe's 8 kHz does not)
      if let l = Loudness.measure(
        solo(project, name), start: start, fixes: fixes, hfTilt: hfTilt, sampleRate: probeRate)
      {
        level[name] = l
      }
    }
    guard level.count >= 2 else { return [:] }
    let offsets = level.map { $0.value - targetDB[$0.key]! }.sorted()
    let centre = offsets[offsets.count / 2]
    var out: [String: Double] = [:]
    for (name, l) in level {
      out[name] = min(maxTrimDB, max(-maxTrimDB, centre + targetDB[name]! - l))
    }
    return out
  }

  /// How far a mix is from `family`'s balance (`targets(family:)`; nil = `targetDB`), dB: the
  /// standard deviation of each part's level less its target (0 = every part exactly where it
  /// should be against the others).
  public static func error(_ levels: [String: Double], family: String? = nil) -> Double? {
    let targetDB = targets(family: family)
    let d = levels.compactMap { k, v in targetDB[k].map { v - $0 } }
    guard d.count >= 2 else { return nil }
    let mean = d.reduce(0, +) / Double(d.count)
    return (d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count)).squareRoot()
  }

  /// Each part's K-weighted level against the whole mix (dB; 0 = as loud as everything
  /// together), over `bars` bars of the busiest section of `played` (what a deck plays) with
  /// `opts`' fixes, rendered at `sampleRate`, mono, through a linear master. Parts that do not
  /// play there are left out.
  ///
  /// `samplers`: the sampled path, offline — the parts `opts` (a deck's, with its voicing seed)
  /// picks sampled instruments for play them from this bank, at the bank's rate, through the
  /// deck's unclipped master (`limit`: the voices at the master gain, the samplers beside
  /// them). nil: every part on its synth voice.
  public static func measure(
    _ played: Project, opts: WaveOptions, bars: Int = 8, sampleRate: Double = 24_000,
    samplers: SamplerBank? = nil
  ) -> [String: Double] {
    let start = Loudness.busiestStart(played)
    let sampleRate = samplers?.sampleRate ?? sampleRate
    let o = soloOptions(played, opts: opts, samplers: samplers)
    func level(_ p: Project) -> Double? {
      let runner = WaveRunner(sampleRate: sampleRate, opts: o)
      runner.load(
        prepared: WaveRunner.prepare(p, sampleRate: sampleRate, opts: o, startTick: start))
      // every slot of the bank renders each block: what the last render left ringing stops
      if let samplers { silence(samplers) }
      runner.play()
      let tempo = played.tempo > 0 ? played.tempo : 120
      let frames = Int(Double(bars) * 4 * 60 / tempo * sampleRate)
      var buf = [Float](repeating: 0, count: 512)
      var k = KWeighting(sampleRate: sampleRate)
      var sum = 0.0
      var n = 0
      buf.withUnsafeMutableBufferPointer { b in
        while n < frames {
          let m = min(512, frames - n)
          runner.process(b.baseAddress!, nil, frames: m)
          for i in 0..<m {
            let y = k.process(Double(b[i]))
            sum += y * y
          }
          n += m
          if runner.stopped { break }
        }
      }
      guard n > 0, sum > 1e-12 * Double(n) else { return nil }
      return 10 * log10(sum / Double(n))
    }
    guard let mix = level(played) else { return [:] }
    var out: [String: Double] = [:]
    for name in parts {
      if let l = level(solo(played, name)) { out[name] = l - mix }
    }
    return out
  }
}

extension MixBalance {
  /// The options every solo of `played` renders with (`measure`, `Translation`): `opts` on
  /// `samplers` (nil: synth voices, through a linear master), at one gain, with the whole
  /// track's energy curve and balance trims, so each part sits at its place in the mix.
  static func soloOptions(_ played: Project, opts: WaveOptions, samplers: SamplerBank?)
    -> WaveOptions
  {
    var o = opts
    o.samplers = samplers
    o.master = samplers == nil ? "linear" : "limit"
    // one gain and the whole track's energy curve for every solo, so each sits at its place in
    // the mix (measured from a solo, both would differ)
    o.trackGain = 1
    if o.musicality.contains(.energy) && o.trackEnergy == nil {
      o.trackEnergy = EnergyCurve(project: played)
    }
    if o.musicality.contains(.balance) && o.trackBalance == nil {
      o.trackBalance = trims(for: played, fixes: o.musicality, family: family(genre: o.genre))
    }
    return o
  }

  /// Stereo renders of the whole mix ("mix") and of each part of `parts` soloed, over `bars`
  /// bars of the busiest section of `played`, with `measure`'s options (`soloOptions`). Parts
  /// silent there are left out. Offline.
  public static func stereoSolos(
    _ played: Project, opts: WaveOptions, bars: Int = 8, sampleRate: Double = 24_000,
    samplers: SamplerBank? = nil
  ) -> (sampleRate: Double, renders: [String: (left: [Float], right: [Float])]) {
    let start = Loudness.busiestStart(played)
    let sampleRate = samplers?.sampleRate ?? sampleRate
    let o = soloOptions(played, opts: opts, samplers: samplers)
    let tempo = played.tempo > 0 ? played.tempo : 120
    let frames = Int(Double(bars) * 4 * 60 / tempo * sampleRate)
    func render(_ p: Project) -> (left: [Float], right: [Float])? {
      let runner = WaveRunner(sampleRate: sampleRate, opts: o)
      runner.load(
        prepared: WaveRunner.prepare(p, sampleRate: sampleRate, opts: o, startTick: start))
      if let samplers { silence(samplers) }
      runner.play()
      var left = [Float](repeating: 0, count: frames)
      var right = left
      var n = 0
      left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
          while n < frames {
            let m = min(512, frames - n)
            runner.process(l.baseAddress! + n, r.baseAddress! + n, frames: m)
            n += m
            if runner.stopped { break }
          }
        }
      }
      var energy = 0.0
      for i in 0..<n { energy += Double(left[i] * left[i] + right[i] * right[i]) }
      guard n > 0, energy > 1e-12 * Double(n) else { return nil }
      return (Array(left[0..<n]), Array(right[0..<n]))
    }
    var out: [String: (left: [Float], right: [Float])] = [:]
    out["mix"] = render(played)
    for name in parts {
      if let r = render(solo(played, name)) { out[name] = r }
    }
    return (sampleRate, out)
  }
}

extension MixBalance {
  /// What `djctl render --balance` reports: the parts' levels against the mix, the genre's
  /// family, the targets.json entry it was held to (`entry(family:)`) and how far off it is.
  public struct Report: Equatable, Sendable {
    public var levels: [String: Double]
    public var family: String?
    public var entry: String
    public var targets: [String: Double]
    public var errorDB: Double?

    public init(levels: [String: Double], genre: String?) {
      self.levels = levels
      family = MixBalance.family(genre: genre)
      entry = MixBalance.entry(family: family)
      targets = MixBalance.targets(family: family)
      errorDB = MixBalance.error(levels, family: family)
    }
  }
}

extension MixBalance {
  /// Offline: sound off and notes off on every slot `bank` plays (CC 120, 123), then the
  /// slots rendered for `flushSeconds` and the output dropped, so the next render starts
  /// silent. (The controllers only take effect in the next render, and AUSampler fades its
  /// voices out over a few blocks: without the flush, a solo after the mix began with the
  /// mix's notes, −31 dB in the first block and a tail ~60 ms later, enough to give a part
  /// that never plays in the window a level of −50…−68 dB.)
  static func silence(_ bank: SamplerBank) {
    let live = bank.beginBlock()
    var m = live
    while m != 0 {
      let i = m.trailingZeroBitCount
      m &= m - 1
      bank.send(i, 0xB0, 120, 0, at: 0)
      bank.send(i, 0xB0, 123, 0, at: 0)
    }
    var l = [Float](repeating: 0, count: 512)
    var r = l
    for _ in 0..<Int((flushSeconds * bank.sampleRate / 512).rounded(.up)) {
      l.withUnsafeMutableBufferPointer { lb in
        r.withUnsafeMutableBufferPointer { rb in
          bank.renderAll(live, frames: 512, lb.baseAddress!, rb.baseAddress!)
        }
      }
    }
    bank.endBlock()
  }

  /// How long `silence` renders the bank to let it go quiet.
  static let flushSeconds = 0.25
}

/// `.balance` on sampled parts (ROADMAP 6.6): a sampler slot plays at a gain of its own, the
/// part's trim less how far the instrument sits from its synth voice on that part's probe
/// (`SamplerBank.slotPartLevelDB`), so a sampled part lands where its trimmed synth voice
/// would. `WaveRunner.prepare` sets it (`WaveProject.slotGain`); the runner renders each slot
/// with a gain through its scratch pair (`flushSamplers`).
public enum SampledBalance {
  /// A slot moves at most this far (dB) either way.
  public static let rangeDB = 12.0

  /// The gain (dB) for a slot playing a part trimmed `trimDB` whose instrument sits
  /// `partLevelDB` from its synth voice (nil: not measured, so the trim alone), within
  /// ± `rangeDB`.
  public static func gainDB(trimDB: Double, partLevelDB: Double?) -> Double {
    min(rangeDB, max(-rangeDB, trimDB - (partLevelDB ?? 0)))
  }

  /// Where that sampler then sits against its trimmed synth voice, linear: what the loudness
  /// probe (which can't play samplers) plays the synth voice at in its place. Unmeasured, the
  /// instrument is taken at the palette's average (`Loudness.sampledPartDB`).
  public static func probeLevel(
    trimDB: Double, partLevelDB: Double?, group: String, gainDB: Double
  ) -> Double {
    let level =
      partLevelDB ?? Loudness.sampledPartDB[group] ?? Loudness.sampledPartDB["melody"]!
    return pow(10, (level + gainDB - trimDB) / 20)
  }
}
