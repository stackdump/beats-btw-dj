import Testing

@testable import DJCore

// Flow drift (SPEC mode 13) and track spin (SPEC mode 20).

struct SequenceRandom: StageRandom {
  var values: [Double]
  var i = 0
  mutating func next() -> Double {
    defer { i += 1 }
    return values[i % values.count]
  }
}

struct StageSpinTests {
  @Test func aTrackChangeAddsAQuarterTurnAndEasesToIt() {
    var s = StageSpin()
    #expect(s.rotation == 0 && s.target == 0)
    s.bump()
    #expect(s.target == 90 && s.rotation == 0)
    // rot += (target - rot) * min(1, dt * 4); dt = 0.1 -> 40% of what is left (node series)
    var got: [Double] = []
    for _ in 0..<4 {
      s.advance(dt: 0.1)
      got.append(s.rotation)
    }
    let want: [Double] = [36, 57.6, 70.56, 78.336]
    for (g, w) in zip(got, want) { #expect(stageNear(g, w, 1e-9)) }
  }

  @Test func aLongFrameJumpsStraightThere() {
    var s = StageSpin()
    s.bump()
    s.advance(dt: 0.25)  // min(1, 0.25 * 4) = 1
    #expect(s.rotation == 90)
  }

  @Test func itSnapsWithinATwentiethOfADegree() {
    #expect(StageSpin.snap == 0.05 && StageSpin.rate == 4 && StageSpin.step == 90)
    // stage.js: `if (Math.abs(delta) > 0.05) rot += delta * Math.min(1, dt * 4) else rot = target`
    var s = StageSpin(rotation: 89.955, target: 90)
    s.advance(dt: 0.001)  // |delta| = 0.045 <= 0.05
    #expect(s.rotation == 90)
    var edge = StageSpin(rotation: 89.945, target: 90)
    edge.advance(dt: 0.001)  // |delta| = 0.055 > 0.05: eases, however close it is
    #expect(stageNear(edge.rotation, 89.945 + 0.055 * 0.004, 1e-12))
    var t = StageSpin(rotation: 89.9, target: 90)
    t.advance(dt: 0.001)  // |delta| = 0.1 > 0.05: eases
    #expect(stageNear(t.rotation, 89.9 + 0.1 * 0.004, 1e-12))
  }

  @Test func fourQuarterTurnsWrapBackToZero() {
    var s = StageSpin()
    for _ in 0..<4 { s.bump() }
    #expect(s.target == 360)
    s.advance(dt: 1)  // jumps to 360, caught up, wraps
    #expect(s.rotation == 0 && s.target == 0)
    s.bump()
    #expect(s.target == 90)
  }

  @Test func itDoesNotWrapWhileStillTurning() {
    var s = StageSpin(rotation: 300, target: 450)
    s.advance(dt: 0.1)
    #expect(s.rotation > 300 && s.rotation < 450 && s.target == 450)
  }

  @Test func aNegativeTargetWrapsIntoRange() {
    var s = StageSpin(rotation: -90, target: -90)
    s.advance(dt: 0.1)
    #expect(s.rotation == 270 && s.target == 270)
  }
}

struct StageFlowTests {
  @Test func theDriftIsThreeToNineDegreesASecondEitherWay() {
    var low = SequenceRandom(values: [0.25, 0.0])  // sign: 0.25 < 0.5 -> -1; 3 + 0 * 6
    #expect(StageFlow.random(using: &low).velocity == -3)
    var mid = SequenceRandom(values: [0.25, 0.5])
    #expect(StageFlow.random(using: &mid).velocity == -6)
    var high = SequenceRandom(values: [0.75, 0.5])
    #expect(StageFlow.random(using: &high).velocity == 6)
    var top = SequenceRandom(values: [0.5, 0.999999])  // 0.5 is not < 0.5 -> +1
    #expect(stageNear(StageFlow.random(using: &top).velocity, 3 + 0.999999 * 6))
    #expect(low.i == 2, "two draws per panel")
  }

  @Test func theSeededGeneratorIsDeterministicAndInRange() {
    var a = StageSeededRandom(seed: 5)
    var b = StageSeededRandom(seed: 5)
    var c = StageSeededRandom(seed: 6)
    var same = true
    var differs = false
    for _ in 0..<100 {
      let x = a.next()
      same = same && x == b.next()
      differs = differs || x != c.next()
      #expect(x >= 0 && x < 1)
    }
    #expect(same && differs)
  }

  @Test func theAngleAdvancesByVelocityTimesDt() {
    var f = StageFlow(angle: 10, velocity: -6)
    f.advance(dt: 0.5, flowOn: true)
    #expect(stageNear(f.angle, 7))
    f.advance(dt: 0.5, flowOn: false)
    #expect(stageNear(f.angle, 7), "flow off: no drift")
  }

  @Test func theAngleWrapsAtPlusMinus360WithASingleSubtraction() {
    var f = StageFlow(angle: 359, velocity: 6)
    f.advance(dt: 1, flowOn: true)  // 365 > 360
    #expect(stageNear(f.angle, 5))
    var g = StageFlow(angle: -359, velocity: -6)
    g.advance(dt: 1, flowOn: true)  // -365 < -360
    #expect(stageNear(g.angle, -5))
    var h = StageFlow(angle: 361, velocity: 5)
    h.advance(dt: 0, flowOn: false)  // the wrap runs even with flow off
    #expect(stageNear(h.angle, 1))
  }
}
