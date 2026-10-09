import Darwin
import Testing

@testable import DJCore

/// feed.html's flame, as ported: the bin range, the bar mapping, the colours, the smoothing and its
/// cadence, silence, and the master feed that drives it.
@MainActor
struct FlameMeterTests {
  /// A sine of amplitude `a` exactly on FFT bin `bin` of a 256-point window.
  func sine(bin: Int, amplitude a: Float = 0.5, count: Int = 256) -> [Float] {
    (0..<count).map { n in
      a * Float(sin(2 * Double.pi * Double(bin) * Double(n) / 256))
    }
  }

  /// `getByteFrequencyData` of a steady magnitude `s`: floor(255 * (20 log10 s + 100) / 70).
  func byte(forMagnitude s: Double) -> Int {
    let scaled = 255 * (20 * log10(s) + 100) / 70
    return scaled <= 0 ? 0 : scaled >= 255 ? 255 : Int(scaled)
  }

  // MARK: the constants

  @Test func theAnalyserAndTheBinRangeAreFeedHtmls() {
    #expect(FlameSpec.fftSize == 256 && FlameSpec.smoothing == 0.78)
    #expect(FlameSpec.firstBin == 2 && FlameSpec.lastBin == 96 && FlameSpec.barCount == 94)
    #expect(FlameSpec.minBarHeight == 2 && FlameSpec.cssHeight == 38)
    let m = FlameMeterModel()
    #expect(m.analyser.fftSize == 256 && m.analyser.frequencyBinCount == 128)
    #expect(m.analyser.smoothingTimeConstant == 0.78)
    #expect(m.bytes.count == 128 && m.reads == 0)
  }

  // MARK: bin -> bar

  @Test func ninetyFourBarsSpanTheCanvasFromBinTwo() {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes[2] = 255  // the first bar
    bytes[95] = 255  // the last bar
    bytes[1] = 255  // skipped: DC / rumble
    bytes[96] = 255  // skipped: beyond ~half the spectrum
    bytes[127] = 255
    let bars = FlameLayout.bars(bytes: bytes, width: 600, height: 76)
    #expect(bars.count == 94)
    let lit = bars.indices.filter { bars[$0].value == 255 }
    #expect(lit == [0, 93], "bin 2 is bar 0, bin 95 is bar 93; bins 0, 1, 96... never show")
    let barW = 600.0 / 94
    #expect(abs(bars[0].rect.x - 0.5) < 1e-12 && abs(bars[0].rect.width - (barW - 1)) < 1e-12)
    #expect(abs(bars[93].rect.x - (93 * barW + 0.5)) < 1e-9)
    #expect(abs(bars[93].rect.x - 594.1170212765957) < 1e-9)
    #expect(abs(bars[93].rect.x + bars[93].rect.width - 599.5) < 1e-9, "ends half a pixel short")
  }

  @Test func aBarsHeightIsTheByteOfTheCanvasWithATwoPixelFloor() {
    var bytes = [UInt8](repeating: 0, count: 128)
    bytes[3] = 255
    bytes[4] = 128
    bytes[5] = 1
    bytes[6] = 3
    let bars = FlameLayout.bars(bytes: bytes, width: 600, height: 76)
    #expect(bars[0].rect.height == 2 && bars[0].rect.y == 74, "silence still stands 2 px high")
    #expect(bars[1].rect.height == 76 && bars[1].rect.y == 0)
    #expect(abs(bars[2].rect.height - 128.0 / 255 * 76) < 1e-12)
    #expect(abs(bars[2].rect.y - (76 - 128.0 / 255 * 76)) < 1e-12)
    #expect(bars[3].rect.height == 2, "byte 1: 0.3 px, floored to 2")
    #expect(abs(bars[4].rect.height - 3.0 / 255 * 76) < 1e-12 || bars[4].rect.height == 2)
    #expect(bars[4].rect.height == 2, "byte 3: 0.89 px")
    // a tall canvas: the floor is in pixels, the byte scales with the height
    let tall = FlameLayout.bars(bytes: bytes, width: 300, height: 200)
    #expect(tall[1].rect.height == 200 && tall[3].rect.height == 2)
  }

  @Test func missingBytesReadAsSilence() {
    let bars = FlameLayout.bars(bytes: [], width: 100, height: 38)
    #expect(bars.count == 94 && bars.allSatisfy { $0.value == 0 && $0.rect.height == 2 })
  }

  // MARK: colour

  @Test func theGradientIsHueTwoHundredDownToFortyAsTheBarRises() {
    func rgb(_ v: Double) -> [Int] {
      let c = FlameLayout.color(forValue: v).rgb8
      return [c.r, c.g, c.b]
    }
    // hsl(200, 70%, 35%), hsl(40, 100%, 60%), and the middle hsl(120, 85%, 47.5%)
    #expect(rgb(0) == [27, 110, 152])
    #expect(rgb(1) == [255, 187, 51])
    let mid = FlameLayout.color(forValue: 0.5)
    let expected = ScopeColor.hsla(120, 85, 47.5)
    #expect(mid == expected)
    let bars = FlameLayout.bars(bytes: [UInt8](repeating: 255, count: 128), width: 94, height: 10)
    #expect(bars.allSatisfy { $0.color == FlameLayout.color(forValue: 1) })
    #expect(FlameLayout.color(forValue: 0).a == 1)
  }

  @Test func theIdleLineIsAFlatTwoPixelLineAtMidHeight() {
    let r = FlameLayout.idleLine(width: 600, height: 76)
    #expect(r == FlameRect(x: 0, y: 37, width: 600, height: 2))
    #expect(FlameSpec.idleColor.rgb8 == (0x1a, 0x2a, 0x3a))
    let idle = FlameLayout.frame(
      bytes: [UInt8](repeating: 255, count: 128), width: 600, height: 76, idle: true)
    #expect(idle.idle && idle.bars.isEmpty && idle.idleLine == r)
    let live = FlameLayout.frame(bytes: [], width: 600, height: 76, idle: false)
    #expect(!live.idle && live.bars.count == 94)
  }

  // MARK: smoothing

  @Test func theSmoothingConstantFollowsTheCadence() {
    let tau = Double(FlameSpec.smoothing)
    // 60 Hz is the JS to the digit
    #expect(FlameLayout.smoothing(forInterval: 1.0 / 60) == FlameSpec.smoothing)
    #expect(abs(Double(FlameLayout.smoothing(forInterval: 1.0 / 30)) - tau * tau) < 1e-6)
    #expect(abs(Double(FlameLayout.smoothing(forInterval: 1.0 / 120)) - tau.squareRoot()) < 1e-6)
    #expect(abs(Double(FlameLayout.smoothing(forInterval: 0.25)) - pow(tau, 15)) < 1e-6)
    #expect(FlameLayout.smoothing(forInterval: 0) == 1, "no time passed: nothing changes")
    #expect(
      FlameLayout.smoothing(forInterval: -1) == FlameSpec.smoothing,
      "a clock that went back is a 60 Hz frame")
    #expect(FlameLayout.smoothing(forInterval: .nan) == FlameSpec.smoothing)
  }

  @Test func aSteadySineRisesByTheSmoothingRecurrence() {
    let m = FlameMeterModel()
    let input = sine(bin: 10)
    // |X_10| / N = A * 0.42 / 2 = 0.105 for the periodic Blackman window
    var t = 0.0
    for k in 1...12 {
      m.analyse(input, at: t)
      t += 1.0 / 60
      let steady = 0.105
      let s = steady * (1 - pow(0.78, Double(k)))
      let want = byte(forMagnitude: s)
      #expect(abs(Int(m.bytes[10]) - want) <= 1, "analysis \(k): byte \(m.bytes[10]), want \(want)")
    }
    // the first analysis is attenuated by (1 - tau) = 0.22, as in a browser
    let first = FlameMeterModel()
    first.analyse(input, at: 0)
    #expect(abs(Int(first.bytes[10]) - byte(forMagnitude: 0.105 * 0.22)) <= 1)
    #expect(first.bytes[10] == 245)
  }

  @Test func theSineLightsItsBarAndItsWindowLeakageOnly() {
    let m = FlameMeterModel()
    var t = 0.0
    for _ in 0..<40 {
      m.analyse(sine(bin: 10), at: t)
      t += 1.0 / 60
    }
    let frame = m.frame(width: 600, height: 76, active: true)
    // Bin 10 is bar 8. The periodic Blackman window is non-zero at bins 0, +-1, +-2 only
    // (0.42, -0.25, 0.04), so a sine of amplitude 0.5 reads |X|/N = 0.105 / 0.0625 / 0.01 there:
    // -19.6 dB, -24.1 dB and -40 dB, i.e. bytes 255, 255 and 218 on the -100...-30 dB scale.
    #expect(frame.bars.indices.filter { frame.bars[$0].rect.height > 20 } == [6, 7, 8, 9, 10])
    #expect(
      [7, 8, 9].allSatisfy { frame.bars[$0].value == 255 && frame.bars[$0].rect.height == 76 })
    #expect([6, 10].allSatisfy { abs(Int(frame.bars[$0].value) - 218) <= 1 })
    #expect(frame.bars[8].color == FlameLayout.color(forValue: 1))
    let rest = frame.bars.indices.filter { !(6...10).contains($0) }
    #expect(
      rest.allSatisfy { frame.bars[$0].rect.height == 2 }, "everything else sits at the floor")
  }

  @Test func theBarFallsBackAtTheSmoothingRateWhenTheSoundStops() {
    let m = FlameMeterModel()
    var t = 0.0
    for _ in 0..<80 {
      m.analyse(sine(bin: 20), at: t)
      t += 1.0 / 60
    }
    #expect(m.bytes[20] == 255)
    let silence = [Float](repeating: 0, count: 256)
    for k in 1...8 {
      m.analyse(silence, at: t)
      t += 1.0 / 60
      let s = 0.105 * pow(0.78, Double(k))
      #expect(abs(Int(m.bytes[20]) - byte(forMagnitude: s)) <= 1, "decay step \(k)")
    }
    // half-life 2.8 analyses (46 ms at 60 Hz): after 8, the bar has lost 1 - 0.78^8 of its linear level
    #expect(m.bytes[20] < 255)
    for _ in 0..<200 {
      m.analyse(silence, at: t)
      t += 1.0 / 60
    }
    #expect(m.bytes.allSatisfy { $0 == 0 }, "-100 dB and below reads 0")
  }

  @Test func aSlowerCadenceDecaysAtTheSameRatePerSecond() {
    func after(frames: Int, interval: Double) -> UInt8 {
      let m = FlameMeterModel()
      var t = 0.0
      for _ in 0..<200 {
        m.analyse(sine(bin: 20), at: t)
        t += 1.0 / 60
      }
      let silence = [Float](repeating: 0, count: 256)
      for _ in 0..<frames {
        t += interval
        m.analyse(silence, at: t)
      }
      return m.bytes[20]
    }
    let a = after(frames: 12, interval: 1.0 / 60)  // 0.2 s at 60 Hz
    let b = after(frames: 6, interval: 1.0 / 30)  // 0.2 s at 30 Hz
    let c = after(frames: 3, interval: 1.0 / 15)  // 0.2 s at 15 Hz
    #expect(abs(Int(a) - Int(b)) <= 1 && abs(Int(a) - Int(c)) <= 1, "\(a) \(b) \(c)")
    #expect(a < 255 && a > 0)
  }

  // MARK: silence

  @Test func silenceIsDarkWithEveryBarAtItsFloor() {
    let m = FlameMeterModel()
    var t = 0.0
    for _ in 0..<10 {
      m.analyse([Float](repeating: 0, count: 256), at: t)
      t += 1.0 / 60
    }
    #expect(m.bytes.allSatisfy { $0 == 0 })
    let frame = m.frame(width: 600, height: 76, active: true)
    #expect(frame.bars.count == 94)
    #expect(frame.bars.allSatisfy { $0.rect.height == 2 && $0.rect.y == 74 && $0.value == 0 })
    #expect(frame.bars.allSatisfy { $0.color == FlameLayout.color(forValue: 0) })
  }

  @Test func resetForgetsTheLevelAndTheCadence() {
    let m = FlameMeterModel()
    for k in 0..<30 { m.analyse(sine(bin: 10), at: Double(k) / 60) }
    #expect(m.bytes[10] == 255)
    m.reset()
    #expect(m.bytes.allSatisfy { $0 == 0 })
    // the first analysis again: attenuated, at the 60 Hz assumption
    m.analyse(sine(bin: 10), at: 500)
    #expect(m.bytes[10] == 245)
  }

  @Test func aShortWindowIsPaddedAtTheFront() {
    let m = FlameMeterModel()
    m.analyse(Array(sine(bin: 10).suffix(100)), at: 0)
    #expect(m.reads == 1)
    #expect(m.bytes[10] > 0, "100 samples of the sine still read as something")
  }

  // MARK: the master feed

  @Test func theMasterFeedDrivesTheMeterAndAnIdleEngineMovesNothing() throws {
    let rig = try ScopeRig(net: ["A"], samples: ["B"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    let m = FlameMeterModel()
    m.update(feed: feed, at: 0)  // nothing rendered yet: "now" is 0, an analysis of silence
    #expect(m.reads == 1 && m.bytes.allSatisfy { $0 == 0 })
    rig.render(seconds: 1)
    rig.hub.pump()
    m.update(feed: feed, at: 1.0 / 60)
    #expect(m.reads == 2)
    #expect(
      m.bytes[FlameSpec.firstBin..<FlameSpec.lastBin].contains { $0 > 0 }, "the mix has a spectrum")
    let bytes = m.bytes
    m.update(feed: feed, at: 2.0 / 60)  // the engine has not moved: a second read in one block
    #expect(m.reads == 2 && m.bytes == bytes)
    rig.render(seconds: 0.1)
    rig.hub.pump()
    m.update(feed: feed, at: 3.0 / 60)
    #expect(m.reads == 3)
  }

  @Test func theMeterReadsTheNewestTwoHundredFiftySixMasterSamples() throws {
    let rig = try ScopeRig(net: [], samples: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    rig.render(seconds: 1)
    rig.hub.pump()
    let m = FlameMeterModel()
    m.update(feed: feed, at: 0)
    let ref = AnalyserFFT(fftSize: 256, smoothingTimeConstant: 0.78)
    ref.analyse(feed.window(count: 256, endingAt: feed.nowFrame))
    #expect(m.bytes == ref.bytes(), "the same analysis as a browser analyser over the master tap")
  }

  @Test func aRestartedHistoryForgetsTheSmoothedLevel() throws {
    let rig = try ScopeRig(net: [], samples: ["A"])
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    rig.render(seconds: 1)
    rig.hub.pump()
    let m = FlameMeterModel()
    for k in 0..<30 {
      rig.render(frames: 512)
      rig.hub.pump()
      m.update(feed: feed, at: Double(k) / 60)
    }
    let lit = m.bytes.filter { $0 > 0 }.count
    #expect(lit > 0)
    feed.release()
    feed.acquire()  // a re-acquire empties the history, so the meter starts over with it
    rig.hub.pump()
    m.update(feed: feed, at: 1)
    #expect(m.bytes.filter { $0 > 0 }.count < lit, "attenuated by the first-analysis (1 - tau)")
    feed.release()
  }

  @Test func aTrackLoadedOnTheIdleDeckDoesNotBlinkTheMeter() throws {
    // Deck A plays on while a new song is loaded onto B: the feed starts a new generation (its
    // lanes are rebuilt), but the master audio is unbroken, and so must the meter be. An analyser
    // that is never reset is the oracle: at 30 fps every frame decays by 0.78 ^ 2.
    let rig = try ScopeRig(net: ["A", "B"])
    defer { rig.stop() }
    rig.dj["B"]!.setPlaying(false)
    let feed = rig.hub.feed(.master)
    feed.acquire()
    defer { feed.release() }
    let m = FlameMeterModel()
    let oracle = AnalyserFFT(
      fftSize: FlameSpec.fftSize,
      smoothingTimeConstant: FlameLayout.smoothing(forInterval: 1.0 / 30))
    func frame(_ k: Int) {
      rig.render(frames: 735)
      rig.hub.pump()
      m.update(feed: feed, at: Double(k) / 30)
      oracle.analyse(feed.window(count: FlameSpec.fftSize, endingAt: feed.nowFrame))
    }
    for k in 0..<60 { frame(k) }
    #expect(m.bytes[FlameSpec.firstBin..<40].reduce(0) { $0 + Int($1) } > 1000, "deck A sounds")
    let generation = feed.generation
    rig.load(scopeProject("house", seed: 7), on: "B", play: false)
    for k in 60..<66 {
      frame(k)
      #expect(feed.generation != generation, "the load really started a new generation")
      let want = oracle.bytes()
      var worst = 0
      for i in 0..<want.count { worst = max(worst, abs(Int(m.bytes[i]) - Int(want[i]))) }
      #expect(worst <= 1, "frame \(k): the meter is \(worst) bytes off an analyser nobody reset")
    }
  }
}
