import Foundation

/// Does a mix translate (ROADMAP 6.6)? Each part, soloed (`MixBalance.stereoSolos`), played
/// through the curves of the devices people listen on, and folded to mono: how much of it is
/// left, K-weighted, against its own full-range level. A part more than `flagDB` under is
/// flagged on that device: a 45 Hz sub bass vanishes on a phone, a saw on the same note keeps
/// its harmonics; a part whose channels cancel (L = −R) vanishes in mono. The curves are
/// approximations of a class of device, each naming where it comes from (`Device.source`),
/// not a measurement of one; the listening log's `device` column is what a person heard.
/// Offline only (`djctl render --translate`).
public enum Translation {
  /// A part this far (dB) under its full-range level on a device, or in mono, is flagged.
  public static let flagDB = 12.0
  /// The floor a level difference is clamped to (a part that cancels completely).
  public static let floorDB = -100.0

  /// One device's playback curve: optional Butterworth high- and lowpass (order 2 or 4), RBJ
  /// shelves, and a fold to mono for a single speaker.
  public struct Device: Sendable {
    public var name: String
    /// Where the curve comes from (it is an approximation of a class of device).
    public var source: String
    public var highpassHz: Double? = nil
    public var highpassOrder = 4
    public var lowpassHz: Double? = nil
    public var lowpassOrder = 2
    /// (corner Hz, gain dB), RBJ shelf at slope 1.
    public var lowShelf: (hz: Double, db: Double)? = nil
    public var highShelf: (hz: Double, db: Double)? = nil
    /// One speaker: (L + R) / 2 on both channels.
    public var mono = false
  }

  /// A phone's speaker: no bass under a few hundred Hz, a dull top, one channel.
  public static let phone = Device(
    name: "phone",
    source:
      "ROADMAP 6.6's phone check: a phone speaker approximated as a 4th-order Butterworth "
      + "highpass at 350 Hz, 2nd-order lowpass at 9 kHz, folded to mono",
    highpassHz: 350, highpassOrder: 4, lowpassHz: 9000, lowpassOrder: 2, mono: true)
  /// Over-ear headphones: the bass lift of a consumer headphone target.
  public static let headphones = Device(
    name: "headphones",
    source:
      "Harman over-ear target (Olive & Welti, 2018), approximated as a +4 dB low shelf at "
      + "105 Hz and a −3 dB high shelf at 10 kHz; stereo",
    lowShelf: (105, 4), highShelf: (10000, -3))
  /// Small near-field monitors: flat, with a ported woofer's bass roll-off.
  public static let monitors = Device(
    name: "monitors",
    source:
      "a 5-inch ported near-field monitor, approximated as flat above a 4th-order Butterworth "
      + "highpass at 50 Hz (its −3 dB point); stereo",
    highpassHz: 50, highpassOrder: 4)

  public static let devices = [phone, headphones, monitors]

  /// One part through one device.
  public struct DeviceLevel: Sendable {
    /// K-weighted level against the part's own full-range level, dB (0 = nothing lost).
    public var levelDB: Double
    /// Integrated loudness through the device, LUFS (−200: silent).
    public var lufs: Double
    public var flagged: Bool
  }

  /// One part's translation.
  public struct PartReport: Sendable {
    public var part: String
    /// The part's full-range K-weighted level against the whole mix, dB (nil without a mix).
    public var vsMixDB: Double?
    /// Its full-range integrated loudness, LUFS.
    public var lufs: Double
    /// Per device (`Device.name`).
    public var devices: [String: DeviceLevel]
    /// Energy of (L + R) / 2 against the mean of L² and R², dB: 0 for a centred part, −3 for
    /// uncorrelated channels, `floorDB` when L = −R.
    public var monoFoldLossDB: Double
    /// The devices it is flagged on, and "mono" when the fold loses more than `flagDB`.
    public var flags: [String]

    public var dictionary: [String: Any] {
      var d: [String: Any] = [
        "lufs": round3(lufs), "monoFoldLossDB": round3(monoFoldLossDB), "flags": flags,
        "devices": devices.mapValues {
          ["levelDB": round3($0.levelDB), "lufs": round3($0.lufs), "flagged": $0.flagged]
        },
      ]
      if let vsMixDB { d["vsMixDB"] = round3(vsMixDB) }
      return d
    }
  }

  /// `left` / `right` through `device`'s curve.
  public static func apply(
    _ device: Device, left: [Float], right: [Float], sampleRate sr: Double
  ) -> (left: [Float], right: [Float]) {
    let n = min(left.count, right.count)
    var l = Array(left[0..<n])
    var r = Array(right[0..<n])
    if device.mono {
      for i in 0..<n {
        let m = (l[i] + r[i]) * 0.5
        l[i] = m
        r[i] = m
      }
    }
    for f in filters(device, sampleRate: sr) {
      var fl = f
      var fr = f
      for i in 0..<n {
        l[i] = Float(fl.process(Double(l[i])))
        r[i] = Float(fr.process(Double(r[i])))
      }
    }
    return (l, r)
  }

  /// K-weighted mean square over both channels, dB (`floorDB` × 2 for silence).
  public static func kLevelDB(left: [Float], right: [Float], sampleRate sr: Double) -> Double {
    var kl = KWeighting(sampleRate: sr)
    var kr = KWeighting(sampleRate: sr)
    var sum = 0.0
    let n = min(left.count, right.count)
    for i in 0..<n {
      let a = kl.process(Double(left[i]))
      let b = kr.process(Double(right[i]))
      sum += a * a + b * b
    }
    guard n > 0, sum > 0 else { return 2 * floorDB }
    return 10 * log10(sum / Double(n))
  }

  /// Energy of (L + R) / 2 against the mean of L² and R², dB, clamped to `floorDB`.
  public static func monoFoldLossDB(left: [Float], right: [Float]) -> Double {
    var mono = 0.0
    var stereo = 0.0
    for i in 0..<min(left.count, right.count) {
      let l = Double(left[i])
      let r = Double(right[i])
      mono += (l + r) * (l + r) / 4
      stereo += (l * l + r * r) / 2
    }
    guard stereo > 0 else { return 0 }
    guard mono > 0 else { return floorDB }
    return max(floorDB, 10 * log10(mono / stereo))
  }

  /// One part's report from its stereo render; `mixDB` the whole mix's `kLevelDB`.
  public static func analyse(
    part: String, left: [Float], right: [Float], sampleRate sr: Double, mixDB: Double? = nil
  ) -> PartReport {
    let full = kLevelDB(left: left, right: right, sampleRate: sr)
    var per: [String: DeviceLevel] = [:]
    var flags: [String] = []
    for d in devices {
      let (l, r) = apply(d, left: left, right: right, sampleRate: sr)
      let level = max(floorDB, kLevelDB(left: l, right: r, sampleRate: sr) - full)
      let flagged = level < -flagDB
      per[d.name] = DeviceLevel(
        levelDB: level, lufs: IntegratedLoudness.lufs(left: l, right: r, sampleRate: sr),
        flagged: flagged)
      if flagged { flags.append(d.name) }
    }
    let fold = monoFoldLossDB(left: left, right: right)
    if fold < -flagDB { flags.append("mono") }
    return PartReport(
      part: part, vsMixDB: mixDB.map { full - $0 },
      lufs: IntegratedLoudness.lufs(left: left, right: right, sampleRate: sr), devices: per,
      monoFoldLossDB: fold, flags: flags)
  }

  /// Every part of `renders` (`MixBalance.stereoSolos`: "mix" plus the parts), in
  /// `MixBalance.parts` order; the mix is the reference for `vsMixDB`.
  public static func report(
    _ renders: [String: (left: [Float], right: [Float])], sampleRate sr: Double
  ) -> [PartReport] {
    let mix = renders["mix"].map { kLevelDB(left: $0.left, right: $0.right, sampleRate: sr) }
    let names =
      MixBalance.parts.filter { renders[$0] != nil }
      + renders.keys.filter { $0 != "mix" && !MixBalance.parts.contains($0) }.sorted()
    return names.map { name in
      let r = renders[name]!
      return analyse(part: name, left: r.left, right: r.right, sampleRate: sr, mixDB: mix)
    }
  }

  /// `djctl render --translate`: each part of `played` soloed (synth voices without
  /// `samplers`) and reported, plus the device curves' sources.
  public static func measure(
    _ played: Project, opts: WaveOptions, bars: Int = 8, samplers: SamplerBank? = nil
  ) -> [String: Any] {
    let (sr, renders) = MixBalance.stereoSolos(
      played, opts: opts, bars: bars, sampleRate: 48_000, samplers: samplers)
    let parts = report(renders, sampleRate: sr)
    var out: [String: Any] = [:]
    for p in parts { out[p.part] = p.dictionary }
    return [
      "parts": out, "flagDB": flagDB,
      "flagged": parts.filter { !$0.flags.isEmpty }.map {
        "\($0.part): \($0.flags.joined(separator: ","))"
      },
      "devices": Dictionary(uniqueKeysWithValues: devices.map { ($0.name, $0.source) }),
    ]
  }

  /// The biquads of `device`, in order.
  static func filters(_ device: Device, sampleRate sr: Double) -> [Biquad] {
    var out: [Biquad] = []
    // Butterworth: 2nd order one section at Q 0.7071, 4th order two at 0.5412 / 1.3066
    func qs(_ order: Int) -> [Double] { order >= 4 ? [0.541_196, 1.306_563] : [0.707_107] }
    if let hz = device.highpassHz {
      out += qs(device.highpassOrder).map {
        Biquad(biquad(type: "highpass", fc: hz, q: $0, sr: sr))
      }
    }
    if let hz = device.lowpassHz {
      out += qs(device.lowpassOrder).map { Biquad(biquad(type: "lowpass", fc: hz, q: $0, sr: sr)) }
    }
    if let s = device.lowShelf { out.append(.shelf(low: true, hz: s.hz, db: s.db, sr: sr)) }
    if let s = device.highShelf { out.append(.shelf(low: false, hz: s.hz, db: s.db, sr: sr)) }
    return out
  }

  /// A transposed direct form II biquad (normalised: a0 = 1).
  struct Biquad {
    let b0, b1, b2, a1, a2: Double
    var s1 = 0.0, s2 = 0.0

    /// From `biquad(type:fc:q:sr:)`'s [b0, b1, b2, a1, a2].
    init(_ c: [Double]) {
      b0 = c[0]
      b1 = c[1]
      b2 = c[2]
      a1 = c[3]
      a2 = c[4]
    }

    /// RBJ cookbook low / high shelf, shelf slope 1.
    static func shelf(low: Bool, hz: Double, db: Double, sr: Double) -> Biquad {
      let a = pow(10, db / 40)
      let w = 2 * Double.pi * min(hz, sr * 0.45) / sr
      let c = cos(w)
      let alpha = sin(w) / 2 * 2.squareRoot()
      let sa = 2 * a.squareRoot() * alpha
      let s: Double = low ? 1 : -1  // the sign that differs between the two
      let a0 = (a + 1) + s * (a - 1) * c + sa
      return Biquad([
        a * ((a + 1) - s * (a - 1) * c + sa) / a0,
        s * 2 * a * ((a - 1) - s * (a + 1) * c) / a0,
        a * ((a + 1) - s * (a - 1) * c - sa) / a0,
        -s * 2 * ((a - 1) + s * (a + 1) * c) / a0,
        ((a + 1) + s * (a - 1) * c - sa) / a0,
      ])
    }

    mutating func process(_ x: Double) -> Double {
      let y = b0 * x + s1
      s1 = b1 * x - a1 * y + s2
      s2 = b2 * x - a2 * y
      return y
    }
  }
}
