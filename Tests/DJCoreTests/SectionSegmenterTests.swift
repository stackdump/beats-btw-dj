import Darwin
import Testing

@testable import DJCore

/// A made-up song on a known grid: each section a different chord, level and click pattern,
/// `bars` bars long, at `bpm` from the first sample.
private func sections(_ bars: [Int], bpm: Double, sampleRate sr: Double) -> [Float] {
  let bar = 4 * 60 / bpm
  let total = Int(Double(bars.reduce(0, +)) * bar * sr)
  var x = [Float](repeating: 0, count: total)
  // per section: chord root (Hz), level, a click on every beat (or every other one)
  let roots = [110.0, 164.8, 130.8, 196.0, 146.8, 123.5]
  let levels = [0.15, 0.3, 0.1, 0.25, 0.2, 0.35]
  var start = 0.0
  for (s, n) in bars.enumerated() {
    let root = roots[s % roots.count]
    let level = levels[s % levels.count]
    let a = Int(start * sr)
    let z = min(total, Int((start + Double(n) * bar) * sr))
    for i in a..<z {
      let t = Double(i) / sr
      var v = 0.0
      for (k, ratio) in [1.0, 1.25, 1.5].enumerated() {
        v += sin(2 * Double.pi * root * ratio * t) / Double(k + 1)
      }
      v *= level
      // a click each beat (odd sections: each half beat, brighter)
      let sub = s % 2 == 0 ? 60 / bpm : 30 / bpm
      let since = (t - start).truncatingRemainder(dividingBy: sub)
      let hz = s % 2 == 0 ? 2000.0 : 5000.0
      v += 0.3 * sin(2 * Double.pi * hz * since) * exp(-since / 0.004)
      x[i] = Float(v)
    }
    start += Double(n) * bar
  }
  return x
}

/// The share of `truth` (bar indices) with a found boundary within ±`tol` bars, and the found
/// boundaries with no true start in reach.
private func score(found: [Int], truth: [Int], tol: Int = 1) -> (recall: Double, spurious: Int) {
  let hits = truth.filter { t in found.contains { abs($0 - t) <= tol } }.count
  let spurious = found.filter { f in !truth.contains { abs($0 - f) <= tol } }.count
  return (truth.isEmpty ? 1 : Double(hits) / Double(truth.count), spurious)
}

/// The same, in seconds: `tol` is a bar.
private func score(found: [Double], truth: [Double], tol: Double) -> (
  recall: Double, spurious: Int
) {
  let hits = truth.filter { t in found.contains { abs($0 - t) <= tol } }.count
  let spurious = found.filter { f in !truth.contains { abs($0 - f) <= tol } }.count
  return (truth.isEmpty ? 1 : Double(hits) / Double(truth.count), spurious)
}

/// A render of the whole song and its true section starts in bars (bar 0 left out).
private func renderedSong(_ genre: String, seed: Double, sampleRate sr: Double) -> (
  render: OfflineRender, tempo: Double, starts: [Int]
) {
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  let source = WaveDeckSource(sampleRate: sr, opts: .extended)
  let track = PreparedTrack(spec: spec, sampleRate: sr, opts: .extended)
  var starts: [Int] = []
  var step = 0
  for s in track.project.structure.dropLast() {
    step += s.steps
    starts.append(step / 16)
  }
  let r = OfflineRender(track: track, source: source, seconds: 600)
  return (r, track.project.tempo, starts)
}

@Suite struct SectionSegmenterTests {
  let sr = 22_050.0

  /// Sections of 8, 4, 8, 4 and 8 bars, each its own chord, level and clicks, on the true grid:
  /// every boundary on its bar, nothing else.
  @Test func distinctSectionsSplitOnTheirBars() {
    let bpm = 120.0
    let bars = [8, 4, 8, 4, 8]
    let x = sections(bars, bpm: bpm, sampleRate: sr)
    let grid = (0..<bars.reduce(0, +)).map { Double($0) * 2 }
    let s = SectionSegmenter(mono: x, sampleRate: sr, downbeats: grid)
    #expect(s.barStarts.count == 32)
    #expect(s.boundaries == [8, 12, 20, 24], "\(s.boundaries), novelty \(s.novelty)")
    #expect(s.sectionBars == bars)
    #expect(s.sectionBars.reduce(0, +) == s.barStarts.count)
    #expect(s.boundaryTimes == [16, 24, 40, 48])
  }

  /// The same song through `BeatTracker`'s downbeats: boundaries within a bar of the truth.
  @Test func trackedBarsFindTheSameBoundaries() {
    let bpm = 120.0
    let bars = [8, 4, 8, 4, 8]
    let x = sections(bars, bpm: bpm, sampleRate: sr)
    let s = SectionSegmenter(mono: x, sampleRate: sr)
    #expect(abs(s.bpm - bpm) <= 1, "\(s.bpm) BPM")
    let r = score(found: s.boundaryTimes, truth: [16, 24, 40, 48], tol: 2)
    #expect(r.recall >= 0.75, "\(s.boundaryTimes)")
    #expect(r.spurious <= 1, "\(s.boundaryTimes)")
  }

  /// One unchanging loop has no sections.
  @Test func aSteadyLoopHasNoBoundaries() {
    let x = sections([32], bpm: 120, sampleRate: sr)
    let grid = (0..<32).map { Double($0) * 2 }
    let s = SectionSegmenter(mono: x, sampleRate: sr, downbeats: grid)
    #expect(s.boundaries.isEmpty, "\(s.boundaries)")
    #expect(s.sectionBars == [32])
  }

  @Test func silenceAndShortInputFindNothing() {
    let s = SectionSegmenter(mono: [Float](repeating: 0, count: 1000), sampleRate: sr)
    #expect(s.barStarts.isEmpty && s.boundaries.isEmpty && s.sectionBars.isEmpty)
  }

  /// The kernel is an option and is reported; the dictionary carries what `djctl measure
  /// --sections` prints.
  @Test func kernelIsAnOptionAndReported() {
    let bars = [8, 8, 8, 8]
    let x = sections(bars, bpm: 120, sampleRate: sr)
    let grid = (0..<32).map { Double($0) * 2 }
    let s = SectionSegmenter(mono: x, sampleRate: sr, downbeats: grid, kernelBars: 8)
    #expect(s.kernel == 8)
    #expect(s.boundaries == [8, 16, 24], "\(s.boundaries)")
    let d = s.dictionary
    for k in ["bars", "barSeconds", "kernelBars", "boundaries", "boundarySeconds", "sectionBars"] {
      #expect(d[k] != nil, "\(k)")
    }
    #expect(d["kernelBars"] as? Int == 8)
    #expect(d["sectionBars"] as? [Int] == bars)
  }

  /// Foote novelty on a two-block similarity matrix peaks at the block edge.
  @Test func noveltyPeaksAtABlockEdge() {
    let n = 16
    let sim = (0..<n).map { i in (0..<n).map { j in (i < 8) == (j < 8) ? 1.0 : -1.0 } }
    let nov = SectionSegmenter.novelty(sim, kernel: 4)
    let top = nov.indices.max { nov[$0] < nov[$1] }
    #expect(top == 8, "\(nov)")
    #expect(SectionSegmenter.peaks(nov, radius: 2) == [8])
  }

  /// Our own renders are the ground truth: the project's structure, bar lines from the first
  /// sample. ≥ 70 % of section starts within ±1 bar, ≤ 1 spurious boundary per 16 bars, on the
  /// true grid and on `BeatTracker`'s.
  @Test(arguments: ["techno", "house", "trance", "dnb"])
  func rendersSplitAtTheirSections(genre: String) {
    let (r, tempo, starts) = renderedSong(genre, seed: 4242, sampleRate: sr)
    let bar = 4 * 60 / tempo
    let seconds = Double(r.left.count) / sr
    let count = Int(seconds / bar)
    let truth = starts.filter { $0 < count }
    var mono = [Float](repeating: 0, count: r.left.count)
    for i in mono.indices { mono[i] = 0.5 * (r.left[i] + r.right[i]) }

    let grid = (0..<count).map { Double($0) * bar }
    let known = SectionSegmenter(mono: mono, sampleRate: sr, downbeats: grid)
    let a = score(found: known.boundaries, truth: truth)
    let allowed = max(1, known.barStarts.count / 16)
    print(
      "SectionSegmenter \(genre) grid: truth \(truth), found \(known.boundaries),"
        + " recall \(a.recall), spurious \(a.spurious) of \(allowed) allowed")
    #expect(a.recall >= 0.7, "\(genre): \(known.boundaries) vs \(truth)")
    #expect(a.spurious <= allowed, "\(genre): \(known.boundaries) vs \(truth)")

    let tracked = SectionSegmenter(left: r.left, right: r.right, sampleRate: sr)
    let b = score(
      found: tracked.boundaryTimes, truth: truth.map { Double($0) * bar }, tol: bar * 1.05)
    let allowedB = max(1, tracked.barStarts.count / 16)
    print(
      "SectionSegmenter \(genre) tracked: found \(tracked.boundaryTimes.map(round3)) s,"
        + " recall \(b.recall), spurious \(b.spurious) of \(allowedB) allowed")
    #expect(b.recall >= 0.7, "\(genre) tracked: \(tracked.boundaryTimes)")
    #expect(b.spurious <= allowedB, "\(genre) tracked: \(tracked.boundaryTimes)")
  }
}
