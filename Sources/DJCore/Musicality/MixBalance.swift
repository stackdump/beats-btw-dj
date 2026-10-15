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
  /// among the parts they have.
  public static let targetDB: [String: Double] = [
    "kick": 0, "bass": -3, "lead": -4, "snare": -6, "pad": -7, "arp": -8, "hats": -10,
  ]
  /// A part moves at most this far.
  public static let maxTrimDB = 6.0
  /// The rate the parts are measured at for `trims`.
  static let probeRate = 22_050.0

  /// The trim (dB) for each part of `project` that puts the parts in `targetDB`'s relation, as
  /// near as `maxTrimDB` allows: each part soloed through the loudness probe (`Loudness.measure`:
  /// two bars of the busiest section, the voices `fixes` shape, at `probeRate`), then moved toward its target
  /// around the median of where they all are (so the mix as a whole moves little; `.loudness`
  /// sets its level after). Empty when fewer than two parts play.
  public static func trims(for project: Project, fixes: DJMusicality.Fixes = []) -> [String: Double]
  {
    let start = Loudness.busiestStart(project)
    var level: [String: Double] = [:]
    for name in parts {
      // (at a rate that hears hats: the loudness probe's 8 kHz does not)
      if let l = Loudness.measure(
        solo(project, name), start: start, fixes: fixes, sampleRate: probeRate)
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

  /// How far a mix is from `targetDB`'s balance, dB: the standard deviation of each part's
  /// level less its target (0 = every part exactly where it should be against the others).
  public static func error(_ levels: [String: Double]) -> Double? {
    let d = levels.compactMap { k, v in targetDB[k].map { v - $0 } }
    guard d.count >= 2 else { return nil }
    let mean = d.reduce(0, +) / Double(d.count)
    return (d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count)).squareRoot()
  }

  /// Each part's K-weighted level against the whole mix (dB; 0 = as loud as everything
  /// together), over `bars` bars of the busiest section of `played` (what a deck plays) with
  /// `opts`' fixes, rendered at `sampleRate`, mono, through a linear master. Parts that do not
  /// play there are left out.
  public static func measure(
    _ played: Project, opts: WaveOptions, bars: Int = 8, sampleRate: Double = 24_000
  ) -> [String: Double] {
    let start = Loudness.busiestStart(played)
    var o = opts
    o.samplers = nil
    o.master = "linear"
    // one gain and the whole track's energy curve for every solo, so each sits at its place in
    // the mix (measured from a solo, both would differ)
    o.trackGain = 1
    if o.musicality.contains(.energy) && o.trackEnergy == nil {
      o.trackEnergy = EnergyCurve(project: played)
    }
    if o.musicality.contains(.balance) && o.trackBalance == nil {
      o.trackBalance = trims(for: played, fixes: o.musicality)
    }
    func level(_ p: Project) -> Double? {
      let runner = WaveRunner(sampleRate: sampleRate, opts: o)
      runner.load(
        prepared: WaveRunner.prepare(p, sampleRate: sampleRate, opts: o, startTick: start))
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
