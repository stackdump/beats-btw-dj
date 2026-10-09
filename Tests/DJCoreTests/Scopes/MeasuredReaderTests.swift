import Darwin
import Testing

@testable import DJCore

// The measured side (MeasuredReader): the bin tables and the power sum against scope.js run by
// node, the frame ring, the per-bar accumulation by hand, and the whole path from a feed: a 1 kHz
// sine played by a deck must light the row that contains 1 kHz and nothing three octaves away.

/// The dB array of the oracle: -150 + ((37 k) % 101) * 0.75, with -inf at multiples of 11, exactly
/// -200 at multiples of 13 and -199.75 at multiples of 17.
func oracleDecibels() -> [Float] {
  (0..<2048).map { k in
    var db = -150 + Double((k * 37) % 101) * 0.75
    if k % 11 == 0 {
      db = -.infinity
    } else if k % 13 == 0 {
      db = -200
    } else if k % 17 == 0 {
      db = -199.75
    }
    return Float(db)
  }
}

func sineWindow(hz: Double, rate: Double, amp: Double = 0.5, count: Int = 4096) -> [Float] {
  (0..<count).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / rate)) }
}

/// Index of the spectrogram row (0 = lowest) that contains `hz`.
func spectroRow(containing hz: Double) -> Int {
  (0..<ModelGrid.ns).first { hz >= ModelGrid.specEdges[$0] && hz < ModelGrid.specEdges[$0 + 1] }!
}

struct MeasuredBinsTests {
  @Test func theRowBinRangesAreTheJsTablesAtEveryRate() {
    for (sr, lo, hi) in [
      (44100.0, SpectroOracle.binLo44100, SpectroOracle.binHi44100),
      (48000.0, SpectroOracle.binLo48000, SpectroOracle.binHi48000),
      (22050.0, SpectroOracle.binLo22050, SpectroOracle.binHi22050),
    ] {
      let b = MeasuredBins(sampleRate: sr)
      #expect(b.lo == lo, "lo at \(sr)")
      #expect(b.hi == hi, "hi at \(sr)")
      #expect(b.lo.count == 33 && b.hi.count == 33)
    }
  }

  @Test func byHandAt44100() {
    // df = 44100 / 4096 = 10.766 Hz. sub = 20 ... 80 Hz: round(1.86) = 2 ... round(7.43) = 7.
    // The lowest spectrogram row is 30 ... 37.5 Hz: round(2.79) = 3 ... round(3.48) = 3, which is
    // not above 3: the row is the single bin 3 ... 4.
    let b = MeasuredBins(sampleRate: 44100)
    #expect(b.lo[0] == 2 && b.hi[0] == 7)
    #expect(b.lo[5] == 3 && b.hi[5] == 4)
    // the top: 6 ... 16 kHz, capped at the 2048 bins (16 kHz is bin 1486)
    #expect(b.lo[4] == 557 && b.hi[4] == 1486)
    #expect(b.hi.allSatisfy { $0 <= 2048 } && b.lo.allSatisfy { $0 >= 1 })
  }

  @Test func rowsAboveNyquistAreEmptyAndReadSilence() {
    let b = MeasuredBins(sampleRate: 22050)
    let top = ModelGrid.nr - 1  // 15 ... 16 kHz at a rate whose Nyquist is 11 kHz
    #expect(b.lo[top] > b.hi[top], "lo \(b.lo[top]) hi \(b.hi[top])")
    let p = b.power(decibels: [Float](repeating: 0, count: 2048))  // 0 dB everywhere
    #expect(p[top] == 0, "an empty range sums nothing")
    #expect(p[0] > 0)
  }

  @Test func aNonsenseRateCountsAs44100() {
    for r in [0.0, -1, .nan, .infinity] {
      #expect(MeasuredBins(sampleRate: r).lo == MeasuredBins(sampleRate: 44100).lo)
    }
  }

  @Test func theRowPowerIsTheSumOfTenToTheDbOverTenAndSkipsMinusTwoHundred() {
    for (sr, want) in [
      (44100.0, SpectroOracle.power44100), (22050.0, SpectroOracle.power22050),
    ] {
      let got = MeasuredBins(sampleRate: sr).power(decibels: oracleDecibels())
      for j in 0..<33 {
        #expect(abs(Double(got[j]) - want[j]) <= 1e-6 * want[j], "row \(j) at \(sr)")
      }
    }
  }

  @Test func silenceAndTheMinusTwoHundredFloorAddNothing() {
    let b = MeasuredBins(sampleRate: 44100)
    var db = [Float](repeating: -.infinity, count: 2048)
    #expect(b.power(decibels: db).allSatisfy { $0 == 0 })
    db = [Float](repeating: -200, count: 2048)
    #expect(b.power(decibels: db).allSatisfy { $0 == 0 }, "-200 itself is skipped (db > -200)")
    db[10] = -199.99  // counts, as 10^(-19.999)
    db[11] = -250
    let p = b.power(decibels: db)
    let want = pow(10, -19.999)
    // bin 10 belongs to low (7 ..< 23), lomid starts at 23, and spectro rows 9 ..< 11 (index 9)
    #expect(abs(Double(p[1]) - want) < 1e-3 * want, "low band: \(p[1]) vs \(want)")
    #expect(p[0] == 0 && p[2] == 0)
    #expect(p.filter { $0 > 0 }.count == 2, "the band and one spectrogram row")
    // 0 dB in one bin is exactly 1
    db = [Float](repeating: -.infinity, count: 2048)
    db[100] = 0
    let one = b.power(decibels: db)
    #expect(one[2] == 1 && one.filter { $0 > 0 }.count == 2, "lomid 23 ..< 186 and one bin row")
  }
}

struct MeasuredFrameRingTests {
  @Test func itKeepsTheNewestFiveHundredAndTwelveFrames() {
    var r = MeasuredFrameRing()
    #expect(r.isEmpty && r.count == 0)
    for i in 0..<600 {
      r.push(time: Double(i), values: (0..<28).map { Float(i * 100 + $0) })
    }
    #expect(r.count == 512)
    #expect(r.time(newest: 1) == 599 && r.time(newest: 512) == 88)
    #expect(r.value(newest: 1, row: 27) == Float(59900 + 27))
    #expect(r.value(newest: 512, row: 3) == Float(8800 + 3))
    // every frame in between is in order
    for k in 1..<512 { #expect(r.time(newest: k) == r.time(newest: k + 1) + 1) }
    r.removeAll()
    #expect(r.isEmpty)
  }

  @Test func aShortOrLongRowListIsPaddedOrCut() {
    var r = MeasuredFrameRing()
    r.push(time: 1, values: [1, 2, 3])
    #expect(r.value(newest: 1, row: 2) == 3 && r.value(newest: 1, row: 3) == 0)
    r.push(time: 2, values: [Float](repeating: 7, count: 40))
    #expect(r.value(newest: 1, row: 27) == 7)
  }
}

@MainActor
struct MeasuredReaderIngestTests {
  private func anchor(time: Double = 9.5, step: Int = 32) -> ScopeAnchor {
    ScopeAnchor(time: time, frame: 0, step: step, tempo: 120, generation: 1)
  }

  @Test func aSineLightsItsRowAndItsBandAndTheSumsAddUp() {
    let r = MeasuredReader()
    // 0.5 at 1 kHz; at 10 s the anchor (9.5 s = step 32) puts it at step 32 + 0.5 / 0.125 = 36
    r.ingest(
      window: sineWindow(hz: 1000, rate: 44100), sampleRate: 44100, time: 10,
      anchor: anchor(), tickSec: 0.125)
    #expect(r.reads == 1 && r.frames.count == 1)
    // the bar: step 36 is bar 2
    #expect(r.maxBar == 2 && r.measCnt[2] == 1 && r.measFrom == 36 && r.measAt == 36)
    let o = 2 * 6
    let bands = (0..<5).map { r.measBars[o + $0] }
    // 1 kHz is in lomid (250 ... 2000 Hz) and the rest of the bands are ~nothing
    #expect(bands[2] > 0.999 * bands.reduce(0, +), "\(bands)")
    #expect(abs(r.measBars[o + 5] - bands.reduce(0, +)) < 1e-12, "E is the sum of the bands")
    // units: Σ |X_k|^2 over the spectrum of a Blackman-windowed sine of amplitude A is
    // (A/2)^2 · mean(w^2), mean(w^2) = 0.42^2 + 0.25^2 · 2 + 0.04^2 · 2 = 0.3046
    let want = 0.25 * 0.25 * 0.3046
    #expect(abs(r.measBars[o + 5] / want - 1) < 0.01, "E \(r.measBars[o + 5]) vs \(want)")
    // the frame: the row that contains 1 kHz is the loudest, in dB
    let row = spectroRow(containing: 1000)
    #expect(row == 15)
    let frame = (0..<28).map { r.frames.value(newest: 1, row: $0) }
    #expect(frame.indices.max { frame[$0] < frame[$1] } == row)
    #expect(r.frames.time(newest: 1) == 10)
    // the frame is 10 log10(p + 1e-20), p the power of the row
    #expect(abs(Double(frame[row]) - 10 * log10(Double(r.power[5 + row]) + 1e-20)) < 1e-4)
    // three octaves away (below 125 Hz, above 8 kHz) the rows are far below the 50 dB range
    for j in 0..<28 where ModelGrid.specEdges[j + 1] <= 125 || ModelGrid.specEdges[j] >= 8000 {
      #expect(frame[j] < frame[row] - 50, "row \(j): \(frame[j]) vs \(frame[row])")
    }
    // measDb reads the mean back
    let e = r.measDb(bar: 2, row: 5)!
    #expect(abs(e - 10 * log10(r.measBars[o + 5])) < 1e-9)
    #expect(r.measDb(bar: 3, row: 5) == nil && r.measDb(bar: -1, row: 0) == nil)
    #expect(r.measDb(bar: 2, row: 6) == nil)
  }

  @Test func readsInOneBarAreSummedAndCounted() {
    let r = MeasuredReader()
    let w = sineWindow(hz: 1000, rate: 44100)
    // the anchor makes t = 10, 10.25, 10.5 steps 36, 38, 40 (bar 2: 32 ... 47) and 11.5 step 48
    for t in [10.0, 10.25, 10.5, 11.5] {
      r.ingest(window: w, sampleRate: 44100, time: t, anchor: anchor(), tickSec: 0.125)
    }
    #expect(r.measCnt[2] == 3 && r.measCnt[3] == 1 && r.maxBar == 3)
    #expect(r.measFrom == 36, "the first step read")
    #expect(r.measAt == 48, "the latest")
    // the same sine each time: the mean over the bar is one read's power
    #expect(abs(r.measBars[2 * 6 + 5] / 3 - r.measBars[3 * 6 + 5]) < 1e-9 * r.measBars[3 * 6 + 5])
    #expect(abs(r.measDb(bar: 2, row: 5)! - r.measDb(bar: 3, row: 5)!) < 1e-6)
    // measFrom keeps the smallest step even if a later read lands earlier (a scrub back)
    r.ingest(window: w, sampleRate: 44100, time: 9.75, anchor: anchor(), tickSec: 0.125)
    #expect(r.measFrom == 34 && r.measAt == 34)
  }

  @Test func theBarComesFromTheStepAtTheTimeOfTheRead() {
    let r = MeasuredReader()
    let w = [Float](repeating: 0, count: 4096)
    func bar(_ time: Double, step: Int = 32, tickSec: Double = 0.125) -> Int {
      r.resetBars()
      r.ingest(
        window: w, sampleRate: 44100, time: time, anchor: anchor(step: step), tickSec: tickSec)
      return r.maxBar
    }
    // anchor: step 32 at 9.5 s. One step is 0.125 s. Step 47.875 is the last of bar 2, 48 bar 3.
    #expect(bar(9.5 + 15 * 0.125 + 0.1) == 2, "step 47.8")
    #expect(bar(9.5 + 16 * 0.125) == 3, "step 48")
    #expect(bar(9.5) == 2 && r.measFrom == 32)
    // before the anchor: step 31.x is bar 1 (the anchor at-or-before is the oldest, the JS)
    #expect(bar(9.4) == 1)
    // a faster tick: step = 32 + 0.5 / 0.0625 = 40: still bar 2; 1.5 s later: 32 + 24 = 56 -> bar 3
    #expect(bar(10, tickSec: 0.0625) == 2)
    #expect(bar(11, tickSec: 0.0625) == 3)
  }

  @Test func readsWithoutABarStillMakeFrames() {
    let r = MeasuredReader()
    let w = sineWindow(hz: 500, rate: 44100)
    // no anchor: nothing to say what bar it is
    r.ingest(window: w, sampleRate: 44100, time: 1, anchor: nil, tickSec: 0.125)
    #expect(r.maxBar == -1 && r.measFrom == .infinity && r.measAt == -1)
    #expect(r.measCnt.allSatisfy { $0 == 0 } && r.measBars.allSatisfy { $0 == 0 })
    #expect(r.frames.count == 1 && r.reads == 1)
    // before the song (step -108) and beyond bar 1023 (step 16416) do not count either
    r.ingest(window: w, sampleRate: 44100, time: 1, anchor: anchor(step: -40), tickSec: 0.125)
    r.ingest(
      window: w, sampleRate: 44100, time: 1, anchor: anchor(step: 16 * 1024 + 100), tickSec: 0.125)
    #expect(r.maxBar == -1 && r.frames.count == 3)
    // the last bar that fits: step 16373
    r.ingest(
      window: w, sampleRate: 44100, time: 9.5, anchor: anchor(step: 16 * 1023 + 5), tickSec: 0.125)
    #expect(r.maxBar == 1023 && r.measCnt[1023] == 1)
    // a tick of 0 seconds makes the step infinite: no bar, no trap
    r.ingest(window: w, sampleRate: 44100, time: 10, anchor: anchor(), tickSec: 0)
    #expect(r.measCnt.reduce(0, +) == 1 && r.frames.count == 5)
    // a time that is not a number is not a read at all
    r.ingest(window: w, sampleRate: 44100, time: .nan, anchor: anchor(), tickSec: 0.125)
    #expect(r.frames.count == 5 && r.reads == 5)
  }

  @Test func silenceIsMinusTwoHundredDecibelsInEveryRow() {
    let r = MeasuredReader()
    r.ingest(
      window: [Float](repeating: 0, count: 4096), sampleRate: 44100, time: 10, anchor: anchor(),
      tickSec: 0.125)
    #expect(r.power.allSatisfy { $0 == 0 })
    for j in 0..<28 { #expect(r.frames.value(newest: 1, row: j) == -200, "10 log10(1e-20)") }
    #expect(r.measCnt[2] == 1, "the read still counts for its bar (step 36)")
    #expect(r.measDb(bar: 2, row: 5) == nil, "but has no level")
  }

  @Test func aShortWindowIsPaddedAtTheFrontLikeAnUnderfilledAnalyser() {
    let r = MeasuredReader()
    let full = sineWindow(hz: 1000, rate: 44100)
    let tail = Array(full.suffix(1000))
    let a = MeasuredReader()
    r.ingest(window: tail, sampleRate: 44100, time: 1, anchor: nil, tickSec: 0.125)
    a.ingest(
      window: [Float](repeating: 0, count: 3096) + tail, sampleRate: 44100, time: 1, anchor: nil,
      tickSec: 0.125)
    #expect(r.power == a.power)
  }

  @Test func theSampleRateSetsTheBins() {
    // the same 1 kHz sine at 22.05 kHz is bin 186 ... and the row is still the one with 1 kHz
    let r = MeasuredReader()
    r.ingest(
      window: sineWindow(hz: 1000, rate: 22050), sampleRate: 22050, time: 1, anchor: nil,
      tickSec: 0.125)
    #expect(r.bins.sampleRate == 22050)
    let frame = (0..<28).map { r.frames.value(newest: 1, row: $0) }
    #expect(frame.indices.max { frame[$0] < frame[$1] } == 15)
    for j in 0..<28 where ModelGrid.specEdges[j + 1] <= 125 || ModelGrid.specEdges[j] >= 8000 {
      #expect(frame[j] < frame[15] - 50, "row \(j)")
    }
  }

  @Test func theBarsResetButTheFramesAreAnExplicitMatter() {
    let r = MeasuredReader()
    r.ingest(
      window: sineWindow(hz: 1000, rate: 44100), sampleRate: 44100, time: 10, anchor: anchor(),
      tickSec: 0.125)
    r.resetBars()
    #expect(r.maxBar == -1 && r.measFrom == .infinity && r.measAt == -1)
    #expect(r.measBars.allSatisfy { $0 == 0 } && r.measCnt.allSatisfy { $0 == 0 })
    #expect(r.frames.count == 1, "frames are keyed by time, not by song")
    r.reset()
    #expect(r.frames.isEmpty)
  }
}

@MainActor
struct MeasuredReaderFeedTests {
  /// Deck A plays a 1 kHz sine from a sample buffer (22.05 kHz, like the rig).
  private func sineRig() throws -> ScopeRig {
    let rig = try ScopeRig(net: [], samples: ["A"], play: false)
    let n = 22050 * 20
    let buffer = SampleBuffer(
      left: (0..<n).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 22050)) },
      sampleRate: 22050)
    rig.dj["A"]!.load(buffer, title: "1 kHz")
    rig.dj["A"]!.setPlaying(true)
    return rig
  }

  /// Render in 0.1 s steps, pumping and updating the reader as a 10 Hz UI would.
  private func run(
    _ rig: ScopeRig, _ feed: ScopeFeed, _ reader: MeasuredReader, seconds: Double,
    measured: Bool = true
  ) {
    for _ in 0..<Int((seconds * 10).rounded()) {
      rig.render(seconds: 0.1)
      rig.hub.pump()
      reader.update(feed: feed, enabled: measured)
    }
  }

  @Test func aSineThroughADeckLightsTheRowWithItsFrequencyAndNothingThreeOctavesAway() throws {
    let rig = try sineRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 2)
    #expect(reader.reads >= 15, "a read for every step that had new audio: \(reader.reads)")
    // the image the Spectro mode draws from these frames, at its last slice (the newest frame)
    let axis = feed.timeAxis(x0: 0, w: 100)
    let img = SpectroImage.measured(frames: reader.frames, t0: axis.t0, win: axis.win)
    #expect(img.peakDb.isFinite)
    let row = spectroRow(containing: 1000)
    let c = 159  // tc = tNow: the frame read at the last update
    // the loudest cell of the window is in this row (another frame may be a fraction of a dB
    // above the newest one: 240 is within 3 dB of the top)
    #expect(
      img.level(c, 27 - row) >= 240, "the 1 kHz row is the loudest cell: \(img.level(c, 27 - row))"
    )
    #expect(
      (0..<28).allSatisfy { img.level(c, 27 - $0) <= img.level(c, 27 - row) },
      "and no other row is above it")
    for j in 0..<28 where ModelGrid.specEdges[j + 1] <= 125 || ModelGrid.specEdges[j] >= 8000 {
      #expect(img.level(c, 27 - j) == 0, "row \(j) (\(Int(ModelGrid.specEdges[j])) Hz) is black")
    }
    // the neighbours fall off with the Blackman skirt, within a couple of rows
    #expect(img.level(c, 27 - row - 3) < 100 && img.level(c, 27 - row + 3) < 100)
  }

  @Test func theMasterTapMeasuresTheSameSine() throws {
    let rig = try sineRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 2)
    let frame = (0..<28).map { reader.frames.value(newest: 1, row: $0) }
    #expect(frame.indices.max { frame[$0] < frame[$1] } == 15, "\(frame)")
  }

  @Test func notMeasuredMeansNoFftNoRingNoReads() throws {
    let rig = try sineRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 1, measured: false)
    #expect(
      reader.reads == 0 && reader.frames.isEmpty
        && reader.analyser.linearMagnitudes().allSatisfy { $0 == 0 })
    run(rig, feed, reader, seconds: 1)
    let reads = reader.reads
    #expect(reads >= 8)
    run(rig, feed, reader, seconds: 1, measured: false)
    #expect(reader.reads == reads, "off again: nothing read")
  }

  @Test func twoUpdatesWithoutNewAudioReadOnce() throws {
    let rig = try sineRig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 0.5)
    let reads = reader.reads
    reader.update(feed: feed, enabled: true)
    reader.update(feed: feed, enabled: true)
    rig.hub.pump()
    reader.update(feed: feed, enabled: true)
    #expect(reader.reads == reads, "the engine did not move: no new frame")
    rig.render(seconds: 0.1)
    rig.hub.pump()
    reader.update(feed: feed, enabled: true)
    reader.update(feed: feed, enabled: true)
    #expect(reader.reads == reads + 1)
  }

  @Test func reEnablingStartsAFreshCoverageWindow() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 3)
    #expect(reader.maxBar >= 2 && reader.measFrom < 40)
    let first = reader.measFrom
    run(rig, feed, reader, seconds: 0.5, measured: false)
    #expect(reader.measFrom == first, "off: untouched")
    run(rig, feed, reader, seconds: 0.5)
    #expect(
      reader.measFrom > first + 10,
      "on again: the first step seen is a later one: \(reader.measFrom)")
    #expect(reader.measAt > reader.measFrom)
  }

  @Test func aNewGenerationEmptiesTheBarsAndKeepsTheFrames() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 3)
    let frames = reader.frames.count
    #expect(reader.maxBar >= 2 && frames > 20)
    feed.release()
    feed.acquire()  // a new generation
    reader.update(feed: feed, enabled: true)
    #expect(
      reader.maxBar == -1 && reader.measCnt.allSatisfy { $0 == 0 } && reader.measFrom == .infinity)
    #expect(reader.frames.count >= frames, "measured audio stays")
    run(rig, feed, reader, seconds: 1)
    #expect(reader.maxBar >= 0 && reader.measCnt.reduce(0, +) > 3)
  }

  @Test func theBarsOfARealSongAreFilledWhereTheEngineIsAndTheKickIsInTheLowBands() throws {
    let rig = try ScopeRig(net: ["A"], genre: "techno", seed: 42, tempo: 300)
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    let reader = MeasuredReader()
    run(rig, feed, reader, seconds: 6)
    // 300 BPM: a bar is 0.8 s; 6 s is bar 7. Every bar before the one playing was read, ~8 times
    #expect(reader.maxBar >= 6, "bar \(reader.maxBar)")
    for bar in 1..<reader.maxBar {
      #expect(
        reader.measCnt[bar] >= 5 && reader.measCnt[bar] <= 9, "bar \(bar): \(reader.measCnt[bar])")
      let row = (0..<6).map { reader.measBars[bar * 6 + $0] }
      #expect(row[0..<5].allSatisfy { $0 > 0 }, "bar \(bar): \(row)")
      #expect(abs(row[5] - row[0..<5].reduce(0, +)) <= 1e-9 * row[5])
      #expect(row[0] + row[1] > row[4], "kick over hats in bar \(bar): \(row)")
    }
    // measAt is the step at the last read, measFrom a step in the first bar
    let now = try #require(feed.stepAt(feed.nowTime))
    #expect(abs(reader.measAt - now) < 1.5, "measAt \(reader.measAt) vs step now \(now)")
    #expect(reader.measFrom < 16)
  }

  @Test func oneReaderPerFeedInTheStore() throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"])
    defer { rig.stop() }
    let store = MeasuredReaderStore()
    let a = rig.hub.feed(.deck("A"))
    let b = rig.hub.feed(.deck("B"))
    let ra = store.reader(for: a)
    #expect(store.reader(for: a) === ra)
    #expect(store.reader(for: b) !== ra)
    #expect(store.count == 2)
  }
}
