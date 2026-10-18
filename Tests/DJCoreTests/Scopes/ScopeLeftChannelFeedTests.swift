import Testing

@testable import DJCore

// The feed's lease on a left-channel tap (`setLeftChannelWanted`, `copyNewestLeftSamples`): what
// the stage's corona uses. A lease, not a subscription: idempotent, only while the feed is
// acquired, gone with its last `release()`.

@MainActor
struct ScopeLeftChannelFeedTests {
  /// Deck A plays the (panned, so stereo) demo loop, deck B a net.
  func rig() throws -> ScopeRig { try ScopeRig(net: ["B"], samples: ["A"], block: 512) }

  func newest(_ feed: ScopeFeed, _ n: Int) -> (ok: Bool, samples: [Float]) {
    var out = [Float](repeating: 9, count: n)
    let ok = out.withUnsafeMutableBufferPointer { feed.copyNewestLeftSamples(into: $0) }
    return (ok, out)
  }

  func tapNewest(_ tap: ScopeTap, _ n: Int) -> [Float] {
    var out = [Float](repeating: .nan, count: n)
    let r = out.withUnsafeMutableBufferPointer { tap.read(from: tap.frames - n, into: $0) }
    #expect(r.count == n && r.lost == 0)
    return out
  }

  @Test func askingBeforeTheFeedIsAcquiredIsIgnored() throws {
    let rig = try rig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("A"))
    feed.setLeftChannelWanted(true)
    #expect(!feed.leftChannelWanted && !rig.dj["A"]!.leftTap.isEnabled)
    rig.render(frames: 1024)
    let got = newest(feed, 64)
    #expect(!got.ok && got.samples.allSatisfy { $0 == 0 }, "nothing wanted: zeros, and says so")
  }

  @Test func theLeaseSwitchesOneTapOnIsIdempotentAndEndsWithTheLastRelease() throws {
    let rig = try rig()
    defer { rig.stop() }
    let a = rig.dj["A"]!
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    #expect(!a.leftTap.isEnabled && a.tap.isEnabled, "the mono history is on, the left not")
    feed.setLeftChannelWanted(true)
    feed.setLeftChannelWanted(true)
    #expect(feed.leftChannelWanted && a.leftTap.subscribers == 1, "asking twice holds once")
    feed.setLeftChannelWanted(false)
    #expect(!feed.leftChannelWanted && !a.leftTap.isEnabled && a.tap.isEnabled)
    feed.setLeftChannelWanted(false)  // and handing back twice is harmless
    feed.setLeftChannelWanted(true)
    feed.acquire()  // a second subscriber of the feed: the lease stays
    feed.release()
    #expect(feed.leftChannelWanted && a.leftTap.isEnabled)
    feed.release()  // the last one: the lease goes with it
    #expect(!feed.leftChannelWanted && !a.leftTap.isEnabled && !a.tap.isEnabled)
    // re-acquired, the lease is NOT remembered: whoever wants the channel asks again
    feed.acquire()
    #expect(!feed.leftChannelWanted && !a.leftTap.isEnabled)
    feed.setLeftChannelWanted(true)
    #expect(a.leftTap.subscribers == 1)
    feed.release()
    #expect(a.leftTap.subscribers == 0)
  }

  @Test func theNewestSamplesAreTheDecksLeftChannelNotTheDownMix() throws {
    let rig = try rig()
    defer { rig.stop() }
    let a = rig.dj["A"]!
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    feed.setLeftChannelWanted(true)
    rig.render(frames: 4096)
    rig.hub.pump()
    let got = newest(feed, 256)
    #expect(got.ok)
    #expect(
      sameSamples(got.samples, tapNewest(a.leftTap, 256)) == .identical,
      "the left tap's own newest 256")
    #expect(got.samples.contains { abs($0) > 0.01 })
    let down = feed.window(count: 256)
    #expect(zip(got.samples, down).contains { abs($0 - $1) > 0.01 }, "history is (L+R)/2")
    feed.release()
  }

  @Test func fewerSamplesThanAskedForAreZeroPaddedAtTheFront() throws {
    let rig = try rig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    feed.setLeftChannelWanted(true)
    let none = newest(feed, 128)
    #expect(!none.ok && none.samples.allSatisfy { $0 == 0 }, "no block rendered yet")
    rig.render(frames: 512)  // the net deck is playing; the tap started at this block
    let got = newest(feed, 1024)
    #expect(got.ok)
    #expect(got.samples[..<512].allSatisfy { $0 == 0 })
    #expect(
      sameSamples(Array(got.samples[512...]), tapNewest(rig.dj["B"]!.leftTap, 512)) == .identical)
    #expect(got.samples[512...].contains { abs($0) > 0.001 })
    feed.release()
  }

  @Test func theMasterFeedLeasesTheMasterLeftTap() throws {
    let rig = try rig()
    defer { rig.stop() }
    let feed = rig.hub.feed(.master)
    feed.acquire()
    feed.setLeftChannelWanted(true)
    #expect(rig.dj.masterLeftTap.subscribers == 1 && rig.dj.masterTap.subscribers == 1)
    #expect(rig.dj["A"]!.leftTap.subscribers == 0 && rig.dj["B"]!.leftTap.subscribers == 0)
    rig.render(frames: 4096)
    rig.hub.pump()
    let got = newest(feed, 256)
    #expect(got.ok)
    #expect(sameSamples(got.samples, tapNewest(rig.dj.masterLeftTap, 256)) == .identical)
    #expect(got.samples.contains { abs($0) > 0.01 })
    feed.release()
    #expect(!rig.dj.masterLeftTap.isEnabled && !rig.dj.masterTap.isEnabled)
  }

  @Test func eachFeedLeasesItsOwnTap() throws {
    let rig = try rig()
    defer { rig.stop() }
    let fa = rig.hub.feed(.deck("A"))
    let fb = rig.hub.feed(.deck("B"))
    fa.acquire()
    fb.acquire()
    fa.setLeftChannelWanted(true)
    #expect(rig.dj["A"]!.leftTap.isEnabled && !rig.dj["B"]!.leftTap.isEnabled)
    fb.setLeftChannelWanted(true)
    fa.release()
    #expect(!rig.dj["A"]!.leftTap.isEnabled && rig.dj["B"]!.leftTap.isEnabled)
    fb.release()
    #expect(!rig.dj["B"]!.leftTap.isEnabled)
  }

  /// A tap that is switched off keeps its old samples in the ring. A lease that begins later must
  /// not hand them out as if they were current: it starts empty, and what it returns is only
  /// what the tap collected since (the gap, as silence, then the live block).
  @Test func aLeaseThatBeginsAgainDoesNotHearTheAudioOfTheLastOne() throws {
    let rig = try rig()
    defer { rig.stop() }
    let a = rig.dj["A"]!
    let feed = rig.hub.feed(.deck("A"))
    feed.acquire()
    feed.setLeftChannelWanted(true)
    rig.render(frames: 4096)
    let first = newest(feed, 256)
    #expect(first.ok && first.samples.contains { abs($0) > 0.01 }, "the first lease hears the deck")
    feed.setLeftChannelWanted(false)
    a.setPlaying(false)
    rig.render(frames: 4096 * 4)  // the deck is silent and its left tap is off
    // the ring still holds the old audio ...
    #expect(sameSamples(tapNewest(a.leftTap, 256), first.samples) == .identical)
    // ... which a new lease must not return before the tap has delivered a block
    feed.setLeftChannelWanted(true)
    let stale = newest(feed, 256)
    #expect(!stale.ok && stale.samples.allSatisfy { $0 == 0 }, "nothing of this lease yet: zeros")
    rig.render(frames: 512)
    let live = newest(feed, 256)
    #expect(live.ok, "a block has arrived")
    #expect(
      sameSamples(live.samples, tapNewest(a.leftTap, 256)) == .identical,
      "and it is this lease's, from the tap")
    #expect(
      sameSamples(live.samples, first.samples) != .identical, "not the audio of the first lease")
    feed.release()
  }

  /// A lease asked for while the tap has older samples reaches back only to its own start.
  @Test func aLeaseReachesBackOnlyToItsOwnStart() throws {
    let rig = try rig()
    defer { rig.stop() }
    let b = rig.dj["B"]!  // the net deck: sounding
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    feed.setLeftChannelWanted(true)
    rig.render(frames: 4096)
    feed.setLeftChannelWanted(false)
    feed.setLeftChannelWanted(true)
    #expect(!newest(feed, 128).ok, "a new lease, a new start")
    rig.render(frames: 512)
    let got = newest(feed, 4096)
    // the ring holds 4096 older samples of the net, but only the last 512 are this lease's
    #expect(got.ok)
    #expect(got.samples[..<3584].allSatisfy { $0 == 0 }, "nothing from before the lease")
    #expect(sameSamples(Array(got.samples[3584...]), tapNewest(b.leftTap, 512)) == .identical)
    #expect(got.samples[3584...].contains { abs($0) > 0.001 })
    feed.release()
  }

  /// `copyNewestLeftSamples` takes a copy of a ring that the audio thread keeps writing. If the
  /// producer laps the reader in the middle of the copy the samples are torn: the call says so
  /// and returns silence, never the torn data.
  @Test func aCopyThatTheProducerLapsInTheMiddleIsDroppedAsSilence() throws {
    let rig = try rig()
    defer { rig.stop() }
    let tap = rig.dj["B"]!.leftTap
    let feed = rig.hub.feed(.deck("B"))
    feed.acquire()
    feed.setLeftChannelWanted(true)
    rig.render(frames: 4096)
    let clean = newest(feed, 256)
    #expect(clean.ok && clean.samples.contains { abs($0) > 0.001 }, "control: the copy works")
    tap.ring.midCopyHook = {
      tap.ring.midCopyHook = nil
      tap.ring.write(repeating: 0.5, count: tap.ring.capacity + 64)  // a whole lap, as if preempted
    }
    let torn = newest(feed, 256)
    #expect(!torn.ok, "the producer lapped the reader mid-copy")
    #expect(torn.samples.allSatisfy { $0 == 0 }, "and nothing torn is handed out")
    // and the next copy is fine again (the ring is intact)
    let again = newest(feed, 256)
    #expect(again.ok && again.samples.allSatisfy { $0 == 0.5 })
    feed.release()
  }
}
