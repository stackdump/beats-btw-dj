import Darwin
import Testing

@testable import DJCore

// SPEC mode 9, the corona: the bin -> geometry/colour numbers (pinned against stage.js's own
// arithmetic run in node), the analyser (one analysis per frame, smoothing compensated for the
// frame rate), and the feed behind it (a sine on the left channel raises the right sector; the
// left-channel tap is leased only while the corona shows).

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

private func sine(bin k: Int, count n: Int = 256, amp: Double = 1) -> [Float] {
  (0..<n).map { Float(amp * sin(2 * Double.pi * Double(k) * Double($0) / 256)) }
}

struct StageCoronaGeometryTests {
  /// stage.js `renderCorona` on a 1000 x 800 stage, ring at (500, 400), dark planet radius 100:
  /// innerR 118, maxLen 256. (Pinned with scripts run in node over the same arithmetic.)
  private let center = StagePoint(x: 500, y: 400)

  private func ray(_ i: Int, _ db: Float, planet: Double? = 100) -> CoronaRay {
    StageCorona.ray(
      index: i, count: 128, decibels: db, center: center,
      innerRadius: StageCorona.innerRadius(planetRadius: planet, width: 1000, height: 800),
      maxLength: StageCorona.maxLength(width: 1000, height: 800))
  }

  @Test func theConstantsAreTheOnesInStageJsAndToneEngine() {
    #expect(StageCorona.binCount == 128 && StageCorona.fftSize == 256)
    #expect(StageCorona.smoothing == 0.4)
    #expect(StageCorona.dbRange == -100...0)
    #expect(StageCorona.planetGap == 18 && StageCorona.lengthFraction == 0.32)
    #expect(StageCorona.fallbackPlanetFraction == 0.08)
  }

  @Test func halfScaleBinZeroPointsStraightUp() {
    let r = ray(0, -50)
    #expect(near(r.norm, 0.5) && near(r.hue, 120))
    #expect(near(r.x0, 500, 1e-9) && near(r.y0, 282, 1e-9), "innerR 118 above the centre")
    #expect(near(r.x1, 500, 1e-9) && near(r.y1, 154, 1e-9), "plus 0.5 * 256")
    #expect(near(r.lineWidth, 3.75) && near(r.stroke.a, 0.625))
    #expect(near(r.shadowBlur, 11) && near(r.shadow.a, 0.6))
  }

  @Test func theCeilingBinAtAQuarterTurnIsFullLengthAndWarm() {
    let r = ray(32, 0)
    #expect(near(r.x0, 618) && near(r.y0, 400) && near(r.x1, 874) && near(r.y1, 400))
    #expect(near(r.norm, 1) && near(r.hue, 40) && near(r.lineWidth, 5.5))
    #expect(near(r.stroke.a, 0.9) && near(r.shadowBlur, 16))
  }

  @Test func aMidBinAtHalfTurnPointsDown() {
    let r = ray(64, -25)
    #expect(near(r.norm, 0.75) && near(r.hue, 80))
    #expect(near(r.x0, 500) && near(r.y0, 518) && near(r.x1, 500) && near(r.y1, 710))
    #expect(near(r.lineWidth, 4.625) && near(r.stroke.a, 0.7625) && near(r.shadowBlur, 13.5))
  }

  @Test func anArbitraryBinMatchesNode() {
    let r = ray(1, -37.5)
    #expect(near(r.x0, 505.78998557063534) && near(r.y0, 282.14213616778966))
    #expect(near(r.x1, 513.6408134630223) && near(r.y1, 122.3348631749621))
    #expect(near(r.hue, 100) && near(r.lineWidth, 4.1875))
    #expect(near(r.stroke.a, 0.69375) && near(r.shadowBlur, 12.25))
    let last = ray(127, 12)  // above the ceiling: clamped to 0 dB
    #expect(
      near(last.norm, 1) && near(last.x1, 481.64868980154563) && near(last.y1, 26.450499379265523))
  }

  @Test func theFloorAndSilenceAreZeroLengthBarsAtTheColdEnd() {
    for db: Float in [-100, -250, -.infinity] {
      let r = ray(96, db)
      #expect(near(r.norm, 0) && r.isZeroLength, "\(db) dB")
      #expect(near(r.x0, 382) && near(r.y0, 400), "bin 96 is at the left")
      #expect(near(r.hue, 200) && near(r.lineWidth, 2) && near(r.stroke.a, 0.35))
      #expect(near(r.shadowBlur, 6))
    }
    #expect(!ray(0, -99).isZeroLength)
  }

  @Test func normaliseIsTheClampedDecibelRangeOnto0To1() {
    #expect(StageCorona.normalised(decibels: -.infinity) == 0)
    #expect(StageCorona.normalised(decibels: -100) == 0)
    #expect(near(StageCorona.normalised(decibels: -30), 0.7))
    #expect(StageCorona.normalised(decibels: 0) == 1)
    #expect(StageCorona.normalised(decibels: 40) == 1)
  }

  @Test func theInnerRadiusIsThePlanetPlus18OrEightPercentOfTheShortSide() {
    #expect(StageCorona.innerRadius(planetRadius: 100, width: 1000, height: 800) == 118)
    for none in [nil, 0, -3, .infinity, .nan] as [Double?] {
      #expect(
        StageCorona.innerRadius(planetRadius: none, width: 1000, height: 800) == 82,
        "stage.js: `darkPlanetRadius || min(w, h) * 0.08` = 64, plus 18")
    }
    #expect(StageCorona.innerRadius(planetRadius: nil, width: 600, height: 1200) == 66)
    #expect(StageCorona.maxLength(width: 1000, height: 800) == 256)
    #expect(StageCorona.maxLength(width: 500, height: 900) == 160)
  }

  @Test func theColoursAreHslaConvertedAsTheCssSpecSaysAndNodeAgrees() {
    // [stroke hsla(hue, 90%, 60%), shadow hsla(hue, 90%, 55%)] from node
    let expected: [(Float, (Int, Int, Int), (Int, Int, Int))] = [
      (-100, (61, 184, 245), (37, 175, 244)),  // hue 200
      (-50, (61, 245, 61), (37, 244, 37)),  // hue 120
      (-25, (184, 245, 61), (175, 244, 37)),  // hue 80
      (0, (245, 184, 61), (244, 175, 37)),  // hue 40
    ]
    for (db, stroke, shadow) in expected {
      let r = ray(3, db)
      #expect(r.stroke.rgb8 == stroke, "\(db) dB: \(r.stroke.rgb8)")
      #expect(r.shadow.rgb8 == shadow, "\(db) dB: \(r.shadow.rgb8)")
    }
  }

  @Test func aWholeSpectrumIsOneRayPerBinRoundTheCircle() {
    var db = [Float](repeating: -.infinity, count: 128)
    db[0] = -50
    db[32] = 0
    let rays = StageCorona.rays(
      decibels: db, center: center, planetRadius: 100, width: 1000, height: 800)
    #expect(rays.count == 128)
    #expect(near(rays[0].y1, 154) && near(rays[32].x1, 874))
    #expect(rays.filter { !$0.isZeroLength }.count == 2)
    for (i, r) in rays.enumerated() {  // every bar starts on the inner circle
      let d = hypot(r.x0 - 500, r.y0 - 400)
      #expect(near(d, 118, 1e-9), "bin \(i): \(d)")
    }
  }

  @Test func smoothingIsTauToTheSixtiethOfASecondPerFrame() {
    func s(_ dt: Double) -> Double { Double(StageCorona.smoothingConstant(dt: dt)) }
    #expect(near(s(1.0 / 60), 0.4, 1e-6), "a 60 Hz frame is beats' own cadence")
    #expect(near(s(1.0 / 120), 0.6324555, 1e-6), "a 120 Hz frame: the square root")
    #expect(near(s(1.0 / 30), 0.16, 1e-6), "a 30 Hz frame: two 60 Hz steps")
    #expect(near(s(0.1), 0.004096, 1e-6))
    #expect(near(s(5), 0.004096, 1e-6), "trusted up to the stage's own 0.1 s clamp")
    for odd in [0, -1, .nan, .infinity] as [Double] {
      #expect(near(s(odd), 0.4, 1e-6), "no usable interval: the nominal constant (\(odd))")
    }
  }
}

@MainActor
struct StageCoronaModelTests {
  @Test func beforeTheFirstAnalysisEveryBinIsSilentAndEveryBarADot() {
    let model = StageCoronaModel()
    #expect(model.decibels.count == 128 && model.decibels.allSatisfy { $0 == -.infinity })
    #expect(model.analyses == 0 && !model.heardSamples)
  }

  @Test func aSineOnBinKRaisesBinKAndItsNeighboursByTheWindowsLeakage() {
    let model = StageCoronaModel()
    let k = 20
    model.analyse(samples: sine(bin: k, amp: 0.5), dt: 1.0 / 60)
    let db = model.decibels
    // first analysis of a fresh analyser: (1 - tau) of the steady value 0.21 * A
    #expect(near(Double(db[k]), -24.013189, 0.01), "20 log10(0.6 * 0.105) = \(db[k])")
    #expect(db.indices.max { db[$0] < db[$1] } == k)
    #expect(near(Double(db[k - 1]), -28.519, 0.02) && near(Double(db[k + 1]), -28.519, 0.02))
    #expect(near(Double(db[k + 2]) - Double(db[k]), -20.4, 0.1), "0.04 against 0.42 of the window")
    #expect(db[k + 10] < -100, "far bins are numerically silent")
    // and it converges to the steady 0.21 * A = -19.576 dB, geometrically
    for _ in 0..<30 { model.analyse(samples: sine(bin: k, amp: 0.5), dt: 1.0 / 60) }
    #expect(near(Double(model.decibels[k]), -19.576214, 0.001))
    #expect(model.analyses == 31 && model.heardSamples)
  }

  @Test func theRaysOfASineRaiseTheRightSector() {
    let model = StageCoronaModel()
    let k = 20
    for _ in 0..<30 { model.analyse(samples: sine(bin: k, amp: 1), dt: 1.0 / 60) }
    let ctx = StageContext(
      width: 1000, height: 800,
      layout: StagePanelLayout.layoutRing(width: 1000, height: 800, count: 0))
    let rays = model.rays(for: ctx)
    #expect(rays.count == 128)
    let peak = rays.indices.max { rays[$0].norm < rays[$1].norm }
    #expect(peak == k)
    // 20/128 of a turn clockwise from the top: up and to the right of the ring centre
    let c = ctx.ringCenter
    let a = StageCorona.angle(index: k, count: 128)
    #expect(near(a, 20.0 / 128 * 2 * Double.pi - Double.pi / 2))
    #expect(rays[k].x1 > c.x && rays[k].y1 < c.y)
    // -13.56 dB for amplitude 1: norm 0.8644, hue 61.7
    #expect(near(rays[k].norm, (20 * log10(0.21) + 100) / 100, 0.001))
    // the quiet half is flat
    #expect(rays[(k + 40)...].allSatisfy { $0.norm < 0.001 && $0.isZeroLength == ($0.norm == 0) })
  }

  @Test func theFrameRateDoesNotChangeTheSmoothingPerSecond() {
    // two 120 Hz frames on the same input end where one 60 Hz frame does
    let a = StageCoronaModel()
    let b = StageCoronaModel()
    let x = sine(bin: 33, amp: 0.7)
    a.analyse(samples: x, dt: 1.0 / 60)
    b.analyse(samples: x, dt: 1.0 / 120)
    b.analyse(samples: x, dt: 1.0 / 120)
    #expect(
      a.decibels.indices.allSatisfy {
        abs(a.decibels[$0] - b.decibels[$0]) < 1e-3 || a.decibels[$0] < -150
      })
    // a 30 Hz frame (perf level 1) is two 60 Hz steps
    let c = StageCoronaModel()
    let d = StageCoronaModel()
    c.analyse(samples: x, dt: 1.0 / 30)
    d.analyse(samples: x, dt: 1.0 / 60)
    d.analyse(samples: x, dt: 1.0 / 60)
    #expect(
      c.decibels.indices.allSatisfy {
        abs(c.decibels[$0] - d.decibels[$0]) < 1e-3 || c.decibels[$0] < -150
      })
  }

  @Test func aShortWindowIsZeroPaddedAtTheFrontAndSilenceDecaysToTheFloor() {
    let model = StageCoronaModel()
    model.analyse(samples: Array(sine(bin: 10, amp: 0.5).suffix(100)), dt: 1.0 / 60)
    #expect(model.decibels[10] > -60 && model.heardSamples)
    for _ in 0..<40 { model.analyse(samples: [Float](repeating: 0, count: 256), dt: 1.0 / 60) }
    #expect(model.decibels.allSatisfy { $0 < -100 }, "smoothed down to numerical silence")
    #expect(StageCorona.normalised(decibels: model.decibels[10]) == 0)
  }
}

@MainActor
struct StageCoronaFeedTests {
  /// Deck A plays a stereo sample: the left channel a sine on bin `left`, the right one on bin
  /// `right` (exactly periodic over the loop). Deck B idles.
  func rig(left: Int, right: Int, amp: Float = 0.5) throws -> ScopeRig {
    let rig = try ScopeRig(net: [], samples: ["A", "B"], play: false, block: 368)
    let n = 256 * 172
    func tone(_ k: Int) -> [Float] {
      (0..<n).map { amp * Float(sin(2 * Double.pi * Double(k) * Double($0) / 256)) }
    }
    rig.dj["A"]!.load(
      SampleBuffer(left: tone(left), right: tone(right), sampleRate: ScopeRig.rate), title: "tones")
    rig.dj["A"]!.setPlaying(true)
    return rig
  }

  func model(_ rig: ScopeRig, source: ScopeSource, shown: StageVisualizer = .corona) -> StageModel {
    let model = StageModel(hub: rig.hub)
    model.settings.source = source
    model.settings.visualizer = shown
    model.attach()
    return model
  }

  func run(_ rig: ScopeRig, _ model: StageModel, frames: Int, dt: Double = 1.0 / 60) {
    var now = 100.0
    for _ in 0..<frames {
      rig.render(frames: 368)  // one block: 1/60 s at 22.05 kHz
      now += dt
      model.advance(now: now, dt: dt, width: 1000, height: 800)
    }
  }

  @Test(arguments: [ScopeSource.deck("A"), ScopeSource.master])
  func theCoronaHearsTheLeftChannelNotTheDownMix(source: ScopeSource) throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let model = model(rig, source: source)
    run(rig, model, frames: 60)  // past the platter's spin-up and the smoothing
    let db = model.layers.solo.corona.decibels
    #expect(db.indices.max { db[$0] < db[$1] } == 20, "the left channel's tone")
    // the down-mix would carry both tones at -6 dB each: the right channel's bin must be far
    // below the left's (only window leakage, tens of dB down)
    #expect(db[20] - db[60] > 40, "bin 20: \(db[20]) dB, bin 60: \(db[60]) dB")
    #expect(model.layers.solo.corona.heardSamples)
    // the level: an amplitude 0.5 tone is 0.21 * 0.5 = -19.6 dB, up to the deck's strip gain
    #expect(db[20] > -30 && db[20] < -12, "\(db[20]) dB")
    // the picture agrees: the ray of bin 20 is the longest
    let rays = model.layers.solo.corona.rays(for: model.context)
    #expect(rays.indices.max { rays[$0].norm < rays[$1].norm } == 20)
    model.detach()
  }

  @Test func theLeftChannelTapIsLeasedOnlyWhileTheCoronaShows() throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let model = model(rig, source: .master, shown: .constellation)
    let tap = rig.dj.masterLeftTap
    run(rig, model, frames: 3)
    #expect(!tap.isEnabled && rig.dj.masterTap.isEnabled, "the constellation reads no left channel")
    model.settings.visualizer = .corona
    run(rig, model, frames: 3)
    #expect(tap.subscribers == 1, "the corona asks for it")
    run(rig, model, frames: 3)
    #expect(tap.subscribers == 1, "once, however many frames")
    model.settings.visualizer = .sonar
    run(rig, model, frames: 2)
    #expect(!tap.isEnabled, "handed back the frame the corona stops showing")
    #expect(model.layers.solo.corona.decibels.allSatisfy { $0 == -.infinity }, "and forgotten")
    model.settings.visualizer = .corona
    run(rig, model, frames: 3)
    #expect(tap.subscribers == 1)
    // closing the window while the corona shows ends the lease (here with the feed's last release;
    // with another holder it is handed back by `detach()` itself, see below)
    model.detach()
    #expect(!tap.isEnabled && !rig.dj.masterTap.isEnabled)
  }

  @Test func switchingTheSourceMovesTheLease() throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let model = model(rig, source: .deck("A"))
    run(rig, model, frames: 5)
    #expect(rig.dj["A"]!.leftTap.isEnabled && !rig.dj.masterLeftTap.isEnabled)
    model.settings.source = .master
    run(rig, model, frames: 5)
    #expect(!rig.dj["A"]!.leftTap.isEnabled && rig.dj.masterLeftTap.isEnabled)
    model.detach()
    #expect(!rig.dj.masterLeftTap.isEnabled)
  }

  /// Another window (the Scopes window, say) keeps the master feed open. Closing the Stage must
  /// still switch the corona's left-channel tap off, and a frame that outlives the close must
  /// not switch it on again.
  @Test func closingTheStageHandsTheLeaseBackWhileAnotherWindowHoldsTheFeed() throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let other = rig.hub.feed(.master)
    other.acquire()  // the Scopes window
    let model = model(rig, source: .master)
    run(rig, model, frames: 5)
    #expect(rig.dj.masterLeftTap.subscribers == 1, "the corona holds the left channel")
    model.detach()
    #expect(!rig.dj.masterLeftTap.isEnabled, "handed back with the window, not with the feed")
    #expect(rig.dj.masterTap.isEnabled, "the other window still has its history")
    #expect(model.layers.solo.corona.decibels.allSatisfy { $0 == -.infinity }, "and forgotten")
    // a frame after the close (a timeline that ticks once more) leases nothing
    rig.render(frames: 368)
    model.advance(now: 200, dt: 1.0 / 60, width: 1000, height: 800)
    #expect(!rig.dj.masterLeftTap.isEnabled)
    other.release()
    #expect(!rig.dj.masterTap.isEnabled)
  }

  /// The tap keeps the old samples while it is off. The first frame after the corona comes back
  /// must hear silence (a fresh analyser over what has arrived since), not the previous session's
  /// audio: the live loop always asks before the audio thread has delivered a block.
  @Test func theFirstFrameAfterTheCoronaComesBackHearsNothingFromBefore() throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let model = model(rig, source: .deck("A"))
    run(rig, model, frames: 40)
    let db = model.layers.solo.corona.decibels
    #expect(db[20] > -30, "the tone is on the corona: \(db[20]) dB")
    #expect(model.layers.solo.corona.heardSamples)
    model.settings.visualizer = .constellation
    run(rig, model, frames: 3)
    // the deck is given silence while the corona is away: three seconds in which the left tap is
    // off, and its ring keeps the tone
    let silence = [Float](repeating: 0, count: 256 * 172)
    rig.dj["A"]!.load(
      SampleBuffer(left: silence, right: silence, sampleRate: ScopeRig.rate), title: "silence")
    rig.dj["A"]!.setPlaying(true)
    run(rig, model, frames: 200)
    model.settings.visualizer = .corona
    // one frame, no audio rendered since the switch: nothing may be heard
    model.advance(now: 300, dt: 1.0 / 60, width: 1000, height: 800)
    let corona = model.layers.solo.corona
    #expect(!corona.heardSamples)
    #expect(corona.decibels.allSatisfy { $0 == -.infinity }, "no ghost of the old tone")
    // and once audio flows (the deck is stopped: silence) it stays silent, nothing decaying
    run(rig, model, frames: 3)
    #expect(corona.decibels.allSatisfy { $0 < -100 })
  }

  /// SPEC 9: the analyser runs ONCE per drawn frame, with the smoothing taken per frame interval.
  /// Through the live path (`StageModel.advance`, not `analyse(samples:)`): two 120 Hz frames over
  /// the same audio end where one 60 Hz frame does, every frame counts one analysis, and the
  /// 30 Hz poll of the hub (`pump`) analyses nothing.
  @Test func theCoronaAnalysesOncePerDrawnFrameWithTheSmoothingOfTheFramesInterval() throws {
    let rig = try rig(left: 20, right: 60)
    defer { rig.stop() }
    let slow = model(rig, source: .deck("A"))  // draws at 60 Hz
    let fast = model(rig, source: .deck("A"))  // draws at 120 Hz; the two share the feed
    func frame(_ m: StageModel, dt: Double) {
      m.advance(now: 100, dt: dt, width: 1000, height: 800)
    }
    frame(slow, dt: 1.0 / 60)  // the lease begins; nothing has arrived yet
    frame(fast, dt: 1.0 / 60)
    rig.render(frames: 368 * 40)  // the platter spins up and the tone arrives
    let a = slow.layers.solo.corona
    let b = fast.layers.solo.corona
    #expect(a.analyses == 1 && b.analyses == 1 && !a.heardSamples)
    for _ in 0..<5 { rig.hub.pump() }  // the AppModel's poll
    #expect(a.analyses == 1 && b.analyses == 1, "a pump is not a frame")
    frame(slow, dt: 1.0 / 60)
    frame(fast, dt: 1.0 / 120)
    frame(fast, dt: 1.0 / 120)
    #expect(a.analyses == 2, "one frame, one analysis (\(a.analyses))")
    #expect(b.analyses == 3, "two frames, two analyses (\(b.analyses))")
    #expect(a.heardSamples && b.heardSamples)
    let k = 20
    #expect(a.decibels[k] > -40, "the tone is heard: \(a.decibels[k]) dB")
    for i in a.decibels.indices where a.decibels[i] > -150 || b.decibels[i] > -150 {
      #expect(
        abs(a.decibels[i] - b.decibels[i]) < 1e-3, "bin \(i): \(a.decibels[i]) / \(b.decibels[i])")
    }
    // a frame interval that is not 1/60 changes the result (the constant is not fixed at 0.4)
    let c = model(rig, source: .deck("A"))
    frame(c, dt: 1.0 / 60)
    rig.render(frames: 368)
    frame(c, dt: 1.0 / 30)
    #expect(
      abs(c.layers.solo.corona.decibels[k] - a.decibels[k]) > 1, "30 Hz smooths twice as hard")
    slow.detach()
    fast.detach()
    c.detach()
  }
}
