import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["structure"] = .string("loop")
  return compose(genre: genre, overrides: .object(ov))
}

private func readAll(_ tap: ScopeTap, from: Int = 0, max: Int = 1 << 16) -> (
  samples: [Float], lost: Int
) {
  var buf = [Float](repeating: .nan, count: max)
  let r = buf.withUnsafeMutableBufferPointer { tap.read(from: from, into: $0) }
  return (Array(buf[0..<r.count]), r.lost)
}

private func push(_ tap: ScopeTap, _ l: [Float], _ r: [Float]?, at frame: Int) {
  l.withUnsafeBufferPointer { lp in
    if let r {
      r.withUnsafeBufferPointer { rp in
        tap.push(left: lp.baseAddress!, right: rp.baseAddress!, frames: l.count, startFrame: frame)
      }
    } else {
      tap.push(left: lp.baseAddress!, right: nil, frames: l.count, startFrame: frame)
    }
  }
}

struct ScopeTapTests {
  @Test func subscribersAreCountedAndTheTapIsEnabledWhileAnyRemain() {
    let tap = ScopeTap()
    #expect(!tap.isEnabled && tap.subscribers == 0)
    tap.acquire()
    #expect(tap.isEnabled && tap.subscribers == 1)
    tap.acquire()
    tap.acquire()
    #expect(tap.subscribers == 3)
    tap.release()
    tap.release()
    #expect(tap.isEnabled && tap.subscribers == 1)
    tap.release()
    #expect(!tap.isEnabled)
    tap.release()  // unbalanced: ignored, never negative
    tap.release()
    #expect(tap.subscribers == 0 && !tap.isEnabled)
    tap.acquire()
    #expect(tap.subscribers == 1, "an extra release left no debt behind")
  }

  @Test func acquireAndReleaseAreSafeFromSeveralThreadsAtOnce() {
    #expect(hammerSubscriptions(threads: 4, each: 50_000) == 0, "balanced calls net to zero")
    #expect(hammerUnbalancedReleases(threads: 4, each: 50_000) == 0, "and never go below it")
  }

  @Test func defaultCapacityIsAtLeastSixteenBitsOfHistory() {
    #expect(ScopeTap().ring.capacity >= 1 << 16)
  }

  @Test func mixdownIsTheMeanOfLeftAndRight() {
    let tap = ScopeTap()
    push(tap, [1, 0.5, -1, 0.25], [0, 0.5, 1, -0.75], at: 100)
    let got = readAll(tap)
    #expect(got.samples == [0.5, 0.5, 0, -0.25] && got.lost == 0)
    #expect(tap.frames == 4)
  }

  @Test func aMissingRightChannelMeansMono() {
    let tap = ScopeTap()
    push(tap, [0.1, -0.2, 0.3], nil, at: 0)
    #expect(readAll(tap).samples == [0.1, -0.2, 0.3])
  }

  @Test func blocksBiggerThanTheScratchAreChunkedWithoutChangingTheData() {
    let tap = ScopeTap()
    let n = 3000  // the scratch chunk is 1024
    let l = (0..<n).map { Float($0) * 0.001 }
    let r = (0..<n).map { Float($0) * -0.0005 }
    push(tap, l, r, at: 0)
    let got = readAll(tap).samples
    #expect(got.count == n)
    for i in [0, 1, 1023, 1024, 1025, 2047, 2048, 2999] {
      #expect(got[i] == (l[i] + r[i]) * 0.5, "sample \(i)")
    }
  }

  @Test func sequenceNumbersMapToEngineFrames() {
    let tap = ScopeTap()
    push(tap, [Float](repeating: 1, count: 128), nil, at: 48_000)
    push(tap, [Float](repeating: 2, count: 128), nil, at: 48_128)
    #expect(tap.originFrame == 48_000)
    #expect(tap.frame(ofSequence: 0) == 48_000 && tap.frame(ofSequence: 130) == 48_130)
    #expect(tap.sequence(ofFrame: 48_128) == 128)
    #expect(tap.endFrame == 48_256, "the frame that follows the newest sample")
    let got = readAll(tap, from: tap.sequence(ofFrame: 48_120)).samples
    #expect(got.count == 136 && got[0] == 1 && got[8] == 2)
  }

  @Test func aGapIsFilledWithSilenceSoTheMappingHolds() {
    let tap = ScopeTap()
    push(tap, [Float](repeating: 1, count: 100), nil, at: 1000)
    // 300 frames while nobody was looking
    push(tap, [Float](repeating: 2, count: 50), nil, at: 1400)
    let got = readAll(tap).samples
    #expect(got.count == 450)
    #expect(got[99] == 1 && got[100] == 0 && got[399] == 0 && got[400] == 2)
    #expect(tap.frame(ofSequence: 400) == 1400, "the sample stamped 1400 is still at frame 1400")
    #expect(tap.gapFrames == 300)
    #expect(tap.endFrame == 1450)
  }

  @Test func aGapLongerThanTheRingJustSkipsAhead() {
    let tap = ScopeTap(capacity: 1 << 12)
    push(tap, [Float](repeating: 1, count: 64), nil, at: 0)
    let far = 10_000_000
    push(tap, [Float](repeating: 3, count: 64), nil, at: far)
    #expect(tap.frame(ofSequence: tap.frames - 64) == far)
    #expect(tap.endFrame == far + 64)
    let r = readAll(tap, from: 0)
    #expect(r.lost > 0, "the old history is gone")
    #expect(r.samples.suffix(64).allSatisfy { $0 == 3 })
    #expect(r.samples.dropLast(64).allSatisfy { $0 == 0 }, "and what is left of the gap is silence")
  }

  @Test func aClockThatGoesBackwardsRebasesAndCountsAnEpoch() {
    let tap = ScopeTap()
    push(tap, [Float](repeating: 1, count: 100), nil, at: 5000)
    #expect(tap.epoch == 0)
    push(tap, [Float](repeating: 2, count: 100), nil, at: 20)
    #expect(tap.epoch == 1)
    #expect(tap.frame(ofSequence: 100) == 20 && tap.endFrame == 120)
  }

  @Test func monoPushStampsLikeStereo() {
    let tap = ScopeTap()
    let v: [Float] = [0.5, 0.25, 0.125]
    v.withUnsafeBufferPointer { tap.push(mono: $0, startFrame: 77) }
    #expect(readAll(tap).samples == v && tap.originFrame == 77 && tap.endFrame == 80)
  }

  @Test func aReaderNeverSeesStaleAudioInsideAGapLongerThanTheRing() {
    // The producer jumps over more than a whole ring of time while a reader is caught up
    // and polling: whatever it is handed must be silence or the new block, never the old lap.
    let report = stressTapGap(iterations: 5_000)
    #expect(report.iterations == 5_000)
    #expect(report.received > 0 && report.lost > 0, "the gaps were really crossed")
    #expect(report.wrong == 0, "\(report.wrong) samples of stale audio were returned as gap")
  }
}
