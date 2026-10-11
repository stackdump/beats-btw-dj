// ModelEngine, part 2: kernels. scope-model.js `analyseHit`, `renderKernels`, `laneKernelSpecs`,
// `laneKernelTable`, `kernelFor` and the kernel cache.
//
// A KERNEL is what one hit of a part looks like in the 33 rows of the model (5 bands, then 28
// log-spaced spectrogram bins): the energy per row (`r`) and how long it rings (`tau`, the
// energy-centroid time). It is measured once, by rendering one hit of the REAL instrument with
// the REAL synth (`WaveRunner`, the engine the decks play) and taking one 32768-point FFT.
//
// "Fx dry" in this engine. The JS renders with the reverb/delay sends at 0 and the channel
// strip unity. The Swift wave engine has no reverb or delay at all (`WaveRunner` is voices
// summed through a master curve), no macro is running in a fresh runner, and the net executes
// one transition once. What is left to choose is the master curve: `WaveOptions.master` is
// `"soft"` (tanh(0.8·x)) or `"linear"`. The kernel is rendered `"linear"`: the voice itself,
// pre-tanh, which is also what the scope-model.js header derives the energy sum for
// ("pre-tanh the master is a filtered marked point process"). The 0.8 of the soft master (its
// small-signal gain, tanh(g·x) ≈ g·x) is not part of the kernel: `ModelEngine` puts it in the
// FX gain (`ModelEngine.sourceGain`), where the deck's own faders are, so a kernel is
// independent of everything downstream of the voice. tanh's saturation of loud hits is not
// modelled (scope-model.js models filters and gains only, no compressor or limiter either).
//
// Segment layout, as the JS: the hit sounds at HIT_AT = 20 ms into a segment, the FFT window
// starts at the segment start and is FFT_N = 32768 samples long at 44.1 kHz (0.743 s). So `tau`
// includes the 20 ms head: it is `max(0.02, Σ x²·i / Σ x² / sr)` with i counted from the segment
// start, as written in the JS, and a part that rings for nothing has tau 0.02 (0.1 if silent).

import Accelerate
import Foundation
import Synchronization

/// One measured hit.
public struct ModelKernel: Equatable, Sendable {
  /// Energy per row: `2·Σ|X_k|²/N` over the row's FFT bins (NR values: 5 bands, then 28 bins).
  public var r: [Float]
  /// Energy-centroid time in seconds (>= 0.02, or 0.1 for silence).
  public var tau: Double

  public init(r: [Float], tau: Double) {
    self.r = r
    self.tau = tau
  }
}

/// One kernel to measure: a note of a part, at a length, on an instrument.
public struct ModelKernelSpec: Hashable, Sendable {
  /// `inst|note|durMs|patchHash` (scope-model.js `kernelKey`).
  public var key: String
  public var instrument: String
  /// The track group the voice is shaped by (`tonalVoice`'s `group`); "main"/"stinger" mean none.
  public var group: String
  /// The MIDI channel (10...15 are drums).
  public var channel: Int
  public var note: Int
  /// Note length in ms (a multiple of 10 in 40...700).
  public var durMs: Int

  public var drum: Bool { isDrumChannel(channel) }

  public init(
    key: String, instrument: String, group: String, channel: Int, note: Int, durMs: Int
  ) {
    self.key = key
    self.instrument = instrument
    self.group = group
    self.channel = channel
    self.note = note
    self.durMs = durMs
  }
}

/// The kernels of one part (lane), ready to look up by note. scope-model.js `laneKernelTable`.
public struct ModelKernelTable: Equatable, Sendable {
  /// The representative notes, ascending (drums: up to 8 distinct kit notes; tonal: up to 3).
  public let notes: [Int]
  /// `ln(max(1e-20, r))` per representative note, NR values each, as Float32 like the JS.
  public let logR: [Float]
  public let n: Int
  public let drum: Bool
  /// The length the kernels were rendered at (the JS `specs[0].durMs || 200`).
  public let durMs: Int
  /// `max(0.03, mean tau)`.
  public let tau: Double
  /// Drum tables: the voice (`drumKind`) each representative note plays, in the same order.
  public let kinds: [String]

  public init(notes: [Int], logR: [Float], drum: Bool, durMs: Int, tau: Double) {
    precondition(logR.count == notes.count * ModelGrid.nr, "logR is NR values per note")
    self.notes = notes
    self.logR = logR
    n = notes.count
    self.drum = drum
    self.durMs = durMs
    self.tau = tau
    kinds = drum ? notes.map { drumKind($0) } : []
  }

  /// scope-model.js `kernelFor`: write the kernel energies of `note` into `out[0 ..< NR]`.
  /// Tonal parts interpolate between the representative notes in LOG energy by pitch (clamped
  /// outside). Drum parts never blend: they take the representative that plays the SAME VOICE as
  /// `note` (`drumKind`: the engine plays 37 as a snare, 44 as a hat), the nearest of those; a
  /// voice with no representative takes the NEAREST note (the lower one on a tie), which is all
  /// the JS does. Allocation-free when `out` is uniquely referenced.
  public func kernelFor(note: Int, into out: inout [Float]) {
    let nr = ModelGrid.nr
    if drum {
      var best = 0
      var bd = Int.max
      let kind = drumKind(note)
      for i in 0..<n where kinds[i] == kind {
        let d = abs(notes[i] - note)
        if d < bd {
          bd = d
          best = i
        }
      }
      if bd == Int.max {  // no representative of this voice: the nearest note
        for i in 0..<n {
          let d = abs(notes[i] - note)
          if d < bd {
            bd = d
            best = i
          }
        }
      }
      let o = best * nr
      for j in 0..<nr { out[j] = Float(exp(Double(logR[o + j]))) }
      return
    }
    if n == 1 || note <= notes[0] {
      for j in 0..<nr { out[j] = Float(exp(Double(logR[j]))) }
      return
    }
    if note >= notes[n - 1] {
      let o = (n - 1) * nr
      for j in 0..<nr { out[j] = Float(exp(Double(logR[o + j]))) }
      return
    }
    var i = 0
    while i < n - 2 && note > notes[i + 1] { i += 1 }
    let w = Double(note - notes[i]) / Double(max(1, notes[i + 1] - notes[i]))
    let a = i * nr
    let b = (i + 1) * nr
    for j in 0..<nr {
      let la = Double(logR[a + j])
      let lb = Double(logR[b + j])
      out[j] = Float(exp(la + (lb - la) * w))
    }
  }
}

/// Kernels by key, at most `capacity` of them (oldest evicted first). Thread-safe: the
/// background render job writes while the main thread reads.
///
/// The JS keeps an unbounded Map in memory and persists only the newest 400 to localStorage
/// (`CACHE_MAX`); SPEC says "cache 400", so here 400 caps the memory cache itself (stricter than
/// the JS) and persisting to disk is not implemented (a kernel costs a few ms to render). The cap
/// cannot strand a lane set: a lane needs at most 5 kernels (a drum lane one per voice, a tonal
/// lane three), 32 lanes per deck, two decks on a master feed, so one lane set is at most
/// 2 x 32 x 5 = 320 and the oldest entries to go are those of earlier songs.
public final class ModelKernelCache: Sendable {
  public static let defaultCapacity = 400
  /// The cache the app uses, shared by every `ModelEngine`.
  public static let shared = ModelKernelCache()

  private struct Store {
    var map: [String: ModelKernel] = [:]
    var order: [String] = []
  }
  private let store = Mutex(Store())
  public let capacity: Int

  public init(capacity: Int = ModelKernelCache.defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  public func kernel(for key: String) -> ModelKernel? { store.withLock { $0.map[key] } }
  public func contains(_ key: String) -> Bool { store.withLock { $0.map[key] != nil } }
  public var count: Int { store.withLock { $0.map.count } }
  /// Keys, oldest first.
  public var keys: [String] { store.withLock { $0.order } }

  /// Add (or replace, keeping its age, as a JS Map does) a kernel; over capacity the oldest go.
  public func insert(_ kernel: ModelKernel, for key: String) {
    store.withLock { s in
      if s.map.updateValue(kernel, forKey: key) == nil { s.order.append(key) }
      while s.order.count > capacity {
        s.map[s.order.removeFirst()] = nil
      }
    }
  }

  public func removeAll() {
    store.withLock {
      $0.map.removeAll()
      $0.order.removeAll()
    }
  }
}

/// scope-model.js, the kernel half.
public enum ModelKernels {
  /// The offline render: 44.1 kHz, a 32768-sample window, one hit per 0.8 s segment, the hit 20 ms in.
  public static let sampleRate = 44100.0
  public static let fftN = 32768
  public static let segmentSeconds = 0.8
  public static let hitAt = 0.02
  /// Velocity the kernels are rendered at; deposits scale by (vel/100)².
  public static let velocity = 100
  /// Bump when the render recipe changes, so cached kernels of the old recipe are not used.
  public static let recipeVersion = 1

  // MARK: analysis

  /// scope-model.js `analyseHit`: energies per row and the energy-centroid time of one rendered
  /// hit. `data[start ..< start + 32768]` is the window (zero past the end of `data`), `sr` its
  /// sample rate.
  public static func analyseHit(_ data: [Float], start: Int = 0, sampleRate sr: Double)
    -> ModelKernel
  {
    let n = fftN
    var x = [Double](repeating: 0, count: n)
    var e = 0.0
    var et = 0.0
    for i in 0..<n {
      let v = start + i < data.count && start + i >= 0 ? Double(data[start + i]) : 0
      x[i] = v
      let x2 = v * v
      e += x2
      et += x2 * Double(i)
    }
    let tau = e > 0 ? max(0.02, et / e / sr) : 0.1
    let power = binPower(x)
    var r = [Float](repeating: 0, count: ModelGrid.nr)
    let df = sr / Double(n)
    for j in 0..<ModelGrid.nr {
      let edge = ModelGrid.edges[j]
      let k0 = max(1, Int((edge.lo / df).rounded(.down)))
      let k1 = min(n / 2, max(k0 + 1, Int((edge.hi / df).rounded(.down))))
      var p = 0.0
      var k = k0
      while k < k1 {
        p += power[k]
        k += 1
      }
      r[j] = Float(2 * p / Double(n))
    }
    return ModelKernel(r: r, tau: tau)
  }

  /// |X_k|² for k = 0 ..< N/2 of a real signal of N = 32768 samples. `vDSP_fft_zripD` returns
  /// twice the DFT (see AnalyserFFT), so the squared magnitude is a quarter of re² + im²; bin 0
  /// holds DC (real) and Nyquist (imaginary) packed together, so it is not a power.
  static func binPower(_ x: [Double]) -> [Double] {
    let n = x.count
    let half = n / 2
    var re = [Double](repeating: 0, count: half)
    var im = [Double](repeating: 0, count: half)
    for i in 0..<half {
      re[i] = x[2 * i]
      im[i] = x[2 * i + 1]
    }
    var power = [Double](repeating: 0, count: half)
    re.withUnsafeMutableBufferPointer { rp in
      im.withUnsafeMutableBufferPointer { ip in
        var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
        vDSP_fft_zripD(
          FFTSetupBox.shared.setup, &split, 1, vDSP_Length(n.trailingZeroBitCount),
          FFTDirection(kFFTDirection_Forward))
      }
    }
    for k in 1..<half { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
    return power
  }

  private final class FFTSetupBox: @unchecked Sendable {
    static let shared = FFTSetupBox()
    let setup: FFTSetupD
    init() {
      setup = vDSP_create_fftsetupD(
        vDSP_Length(ModelKernels.fftN.trailingZeroBitCount), FFTRadix(kFFTRadix2))!
    }
  }

  // MARK: keys

  /// The voice a spec plays, resolved as `WaveRunner` resolves it for a net on that channel.
  static func voice(for spec: ModelKernelSpec) -> VoiceSpec {
    spec.drum
      ? drumVoice(kind: drumKind(spec.note), instrument: spec.instrument)
      : tonalVoice(instrument: spec.instrument, group: spec.group)
  }

  /// A stable text of everything the sound depends on: the voice's parameters and the recipe
  /// (the JS hashes the instrument's config and its normalisation gain).
  static func patchFingerprint(_ v: VoiceSpec) -> String {
    let nums = [
      v.f1, v.f0, v.sweepTau, v.fc, v.q, v.tone, v.toneMix, v.level, v.attack, v.decayScale,
      v.maxDecay,
    ]
    let words = [v.kind, v.carrier, v.filter, v.wave]
    let pulse = (v.pulse.alpha + v.pulse.tau)
    let all = words + nums.map { "\($0)" } + pulse.map { "\($0)" }
    return "v\(recipeVersion)|\(Int(sampleRate))|\(fftN)|\(segmentSeconds)|\(hitAt)|\(velocity)|"
      + all.joined(separator: ",")
  }

  /// scope-model.js `patchHash`: base-36 of the 32-bit string hash of the fingerprint.
  static func patchHash(_ v: VoiceSpec) -> String {
    String(UInt32(bitPattern: strHash(patchFingerprint(v))), radix: 36)
  }

  /// `inst|note|durMs|patchHash`.
  public static func kernelKey(
    instrument: String, group: String, channel: Int, note: Int, durMs: Int
  ) -> String {
    let probe = ModelKernelSpec(
      key: "", instrument: instrument, group: group, channel: channel, note: note, durMs: durMs)
    return "\(instrument)|\(note)|\(durMs)|\(patchHash(voice(for: probe)))"
  }

  // MARK: per-lane kernel sets

  /// scope-model.js `laneKernelSpecs`: drums -> one kernel per drum VOICE the lane plays (the
  /// lowest note of each `drumKind`, at most 8); tonal -> up to three representative notes
  /// (lowest, median, highest) to interpolate between. The length is the median of the lane's
  /// note lengths, rounded to 10 ms and clamped to 40...700 (200 without any).
  ///
  /// The JS takes the 8 lowest kit notes, because each note is its own sample there. This engine
  /// plays a drum note through `drumKind` (35 and 36 are one kick, 42...46 one hat), so notes
  /// that share a voice share a kernel and a kit needs at most 5.
  ///
  /// A lane with no note list but a range (one built from the engine's layout) is taken to play
  /// every note of its range if it is a drum lane, else its lowest and highest note. A lane with
  /// neither gets kick 36 / middle C 60. (The 48...72 that `ScopeLaneSet` reports for a lane
  /// with no notes at all is read as a range: such a lane never fires, so what its kernels are
  /// does not matter, whereas a layout lane that really spans 48...72 is not mistaken for none.)
  public static func laneKernelSpecs(for lane: ScopeLane) -> [ModelKernelSpec] {
    let notes = lane.notes.sorted()
    let present: [Int]
    if !notes.isEmpty {
      present = notes
    } else if lane.lo <= lane.hi {
      if lane.drum {
        let lo = max(0, min(127, lane.lo))
        let hi = max(lo, min(127, lane.hi))
        present = Array(lo...hi)
      } else {
        present = lane.lo == lane.hi ? [lane.lo] : [lane.lo, lane.hi]
      }
    } else {
      present = [lane.drum ? 36 : 60]
    }
    let reps: [Int]
    if lane.drum {
      var voices = Set<String>()
      reps = Array(present.filter { voices.insert(drumKind($0)).inserted }.prefix(8))
    } else {
      var seen: [Int] = []
      for n in [present[0], present[present.count >> 1], present[present.count - 1]]
      where !seen.contains(n) {
        seen.append(n)
      }
      reps = seen
    }
    let durs = lane.durationsMs.sorted()
    let median = durs.isEmpty ? 200 : durs[durs.count >> 1]
    // Math.round(dur / 10) * 10: halves go up (the lengths are positive). Clamped in Double, so
    // an absurd or infinite length cannot trap the Int conversion.
    let rounded = (median.isNaN ? 200 : (median / 10 + 0.5).rounded(.down) * 10)
    let dur = Int(max(40, min(700, rounded)))
    return reps.map { note in
      ModelKernelSpec(
        key: kernelKey(
          instrument: lane.instrument, group: lane.group, channel: lane.channel, note: note,
          durMs: dur),
        instrument: lane.instrument, group: lane.group, channel: lane.channel, note: note,
        durMs: dur)
    }
  }

  /// scope-model.js `laneKernelTable`: a lane's interpolation table from cached kernels, nil
  /// if any is missing.
  public static func laneKernelTable(
    _ specs: [ModelKernelSpec], drum: Bool, cache: ModelKernelCache
  ) -> ModelKernelTable? {
    var notes: [Int] = []
    var logR: [Float] = []
    var tau = 0.0
    for s in specs {
      guard let k = cache.kernel(for: s.key) else { return nil }
      notes.append(s.note)
      for j in 0..<ModelGrid.nr { logR.append(Float(log(max(1e-20, Double(k.r[j]))))) }
      tau += k.tau
    }
    return ModelKernelTable(
      notes: notes, logR: logR, drum: drum, durMs: specs.first?.durMs ?? 200,
      tau: max(0.03, tau / Double(max(1, specs.count))))
  }

  // MARK: rendering

  /// Render one hit of `spec` with the real synth and analyse it. Runs on the calling thread
  /// (the wave engine, offline); keep it off the main and audio threads.
  public static func renderHit(_ spec: ModelKernelSpec) -> ModelKernel {
    analyseHit(renderHitSamples(spec), start: 0, sampleRate: sampleRate)
  }

  /// The 32768-sample window `renderHit` analyses: one hit of `spec`, `hitAt` seconds in.
  ///
  /// A one-net project (a place holding one token, an arc to one transition bound to the note
  /// at velocity 100 and the spec's length in ms) goes through `WaveRunner.prepare`, so the
  /// voice is picked exactly as for a deck: `drumVoice(drumKind(note), instrument)` on a drum
  /// channel, `tonalVoice(instrument, group)` otherwise. The tick clock fires the transition on
  /// the first sample after `play()`; the output (linear master, see the file header) is
  /// written `hitAt` seconds into the window.
  static func renderHitSamples(_ spec: ModelKernelSpec) -> [Float] {
    var net = NetBundle()
    net.track = Track(
      channel: spec.channel, instrument: spec.instrument,
      group: spec.group.isEmpty ? nil : spec.group)
    net.places["p"] = Place(initial: [1])
    net.transitions["t"] = Transition()
    net.arcs = [Arc(source: "p", target: "t", weight: [1], inhibit: false)]
    net.bindings["t"] = MidiBinding(
      note: spec.note, channel: spec.channel, velocity: velocity, duration: spec.durMs,
      durationSteps: 0)
    var project = Project()
    project.nets["k"] = net
    var opts = WaveOptions()
    opts.master = "linear"
    let runner = WaveRunner(sampleRate: sampleRate, opts: opts)
    runner.load(prepared: WaveRunner.prepare(project, sampleRate: sampleRate, opts: opts))
    runner.play()
    var data = [Float](repeating: 0, count: fftN)
    let head = Int((hitAt * sampleRate).rounded())
    data.withUnsafeMutableBufferPointer { p in
      runner.process(p.baseAddress! + head, nil, frames: fftN - head)
    }
    return data
  }

  private final class Counter: Sendable {
    let next = Atomic<Int>(0)
    let done = Atomic<Int>(0)
  }

  /// scope-model.js `renderKernels`: render every spec the cache does not have (once per key)
  /// and add it. Synchronous: it returns when they are all in. `workers` > 1 renders that many
  /// at once (the kernels are independent; the background job uses one so as not to compete with
  /// the audio and the UI, tests and `ModelEngine.prepared` use the cores). `isCancelled` is
  /// asked before each kernel. Returns how many were rendered.
  @discardableResult
  public static func renderKernels(
    _ specs: [ModelKernelSpec], into cache: ModelKernelCache, workers: Int = 1,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) -> Int {
    var seen = Set<String>()
    var todo: [ModelKernelSpec] = []
    for s in specs where !cache.contains(s.key) && seen.insert(s.key).inserted { todo.append(s) }
    guard !todo.isEmpty else { return 0 }
    let count = Counter()
    let work = todo
    let run = { @Sendable in
      while true {
        let i = count.next.add(1, ordering: .relaxed).oldValue
        if i >= work.count || isCancelled() { return }
        cache.insert(renderHit(work[i]), for: work[i].key)
        count.done.add(1, ordering: .relaxed)
      }
    }
    if workers <= 1 || work.count == 1 {
      run()
    } else {
      DispatchQueue.concurrentPerform(iterations: min(workers, work.count)) { _ in run() }
    }
    return count.done.load(ordering: .relaxed)
  }
}
