import Darwin
import Testing

@testable import DJCore

private func tone(_ n: Int, bin: Int, size: Int, amp: Float) -> [Float] {
  (0..<n).map { amp * Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(size))) }
}

struct AudioTapTests {
  @Test func readsBackWhatWasWrittenInOrder() {
    let tap = AudioTap(minimumCapacity: 4096)
    var l = (0..<1000).map { Float($0) }
    var r = (0..<1000).map { Float(-$0) }
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        tap.write(lp.baseAddress!, rp.baseAddress!, frames: 1000)
      }
    }
    #expect(tap.framesWritten == 1000)
    let got = tap.recent(10)
    #expect(got == [Float](repeating: 0, count: 10), "(l + r) / 2 of a mirrored pair is silence")
    var mono = [Float](repeating: 0, count: 1000)
    let rd = mono.withUnsafeMutableBufferPointer {
      tap.read(from: 0, into: $0.baseAddress!, maxFrames: 1000)
    }
    #expect(rd.start == 0 && rd.count == 1000 && rd.lost == 0)
  }

  @Test func overwritesTheOldestAndReportsWhatWasLost() {
    let tap = AudioTap(minimumCapacity: 1024)
    let cap = tap.capacity
    var x = (0..<(cap * 3 / 2)).map { Float($0) }
    x.withUnsafeMutableBufferPointer { tap.write($0.baseAddress!, nil, frames: $0.count) }
    var out = [Float](repeating: 0, count: cap)
    let r = out.withUnsafeMutableBufferPointer {
      tap.read(from: 0, into: $0.baseAddress!, maxFrames: cap)
    }
    #expect(r.lost == cap / 2, "the first half-capacity was overwritten")
    #expect(r.start == cap / 2 && r.count == cap)
    #expect(out[0] == Float(cap / 2) && out[cap - 1] == Float(cap * 3 / 2 - 1))
  }
}

struct TapReaderTests {
  @Test func blocksCarryMinMaxAndMeanSquare() {
    // 4 blocks: a constant 0.5, then silence, then +-0.25 square, then a ramp
    var x = [Float](repeating: 0.5, count: 256) + [Float](repeating: 0, count: 256)
    x += (0..<256).map { $0 % 2 == 0 ? 0.25 : -0.25 }
    x += (0..<256).map { Float($0) / 255 }
    let fresh = AudioTap(minimumCapacity: 1 << 14)
    let r = TapReader(tap: fresh, sampleRate: 48_000)
    x.withUnsafeMutableBufferPointer { fresh.write($0.baseAddress!, nil, frames: $0.count) }
    #expect(r.update() == 4)
    #expect(r.count == 4)
    #expect(r.blockMin[0] == 0.5 && r.blockMax[0] == 0.5)
    #expect(abs(r.blockSq[0] - 0.25) < 1e-6)
    #expect(r.blockMin[1] == 0 && r.blockMax[1] == 0 && r.blockSq[1] == 0)
    #expect(r.blockMin[2] == -0.25 && r.blockMax[2] == 0.25 && abs(r.blockSq[2] - 0.0625) < 1e-6)
    #expect(r.blockMin[3] == 0 && r.blockMax[3] == 1)
    #expect(abs(r.blockT[3] - 1024.0 / 48_000) < 1e-12, "stamped with the block's last sample")
    #expect(r.lastPeak == 1)
    #expect(r.update() == 0)
  }

  @Test func columnsFoldBlocksNewestAtTheRight() {
    let tap = AudioTap(minimumCapacity: 1 << 16)
    let r = TapReader(tap: tap, sampleRate: 48_000)
    // 1 s of a +-0.8 tone in the first half, +-0.2 in the second
    var x =
      tone(24_000, bin: 100, size: 4096, amp: 0.8) + tone(24_000, bin: 100, size: 4096, amp: 0.2)
    // as the UI does: a little at a time
    for chunk in 0..<8 {
      x.withUnsafeMutableBufferPointer {
        tap.write($0.baseAddress! + chunk * 6000, nil, frames: 6000)
      }
      r.update()
    }
    let cols = r.columns(width: 100, window: 1)
    #expect(cols.count.count == 100)
    let loud = cols.max[10]
    let quiet = cols.max[90]
    #expect(loud > 0.7 && loud <= 0.8001)
    #expect(quiet > 0.15 && quiet <= 0.2001)
    #expect(cols.rms(10) > cols.rms(90))
  }

  @Test func theSpectrumPeaksAtTheToneAndMatchesTheAnalyserScale() {
    let tap = AudioTap(minimumCapacity: 1 << 14)
    let r = TapReader(tap: tap, sampleRate: 48_000)
    var x = tone(TapReader.fftSize, bin: 200, size: TapReader.fftSize, amp: 1)
    x.withUnsafeMutableBufferPointer { tap.write($0.baseAddress!, nil, frames: $0.count) }
    let db = r.spectrum()
    #expect(db.count == TapReader.fftSize / 2)
    let peak = db.indices.max { db[$0] < db[$1] }!
    #expect(peak == 200)
    // Blackman coherent gain 0.42, a real sine splits into two halves: 0.42 / 2 = -13.6 dB
    #expect(abs(db[200] - 20 * log10f(0.21)) < 0.2, "got \(db[200])")
    #expect(db[1000] < db[200] - 60)
    #expect(abs(r.binFrequency(200) - 200 * 48_000.0 / 4096) < 1e-9)
  }
}

struct AutoGainTests {
  @Test func matchesTheJavaScriptFormulaToTheLastDigit() throws {
    let fx = try JSONValue.parse(try beatsFixtureText("autogain"))
    let ops = try #require(fx["ops"]?.array)
    let trace = try #require(fx["trace"]?.array)
    #expect(ops.count == trace.count && ops.count > 1000)
    var g = AutoGain()
    var worst = 0.0
    for (op, want) in zip(ops, trace) {
      if op["op"]?.string == "raise" {
        g.observe(peak: op["pk"]!.double!)
      } else {
        g.advance(now: op["now"]!.double!)
      }
      let w = want.array!.map { $0.double! }
      worst = max(worst, abs(g.peak - w[0]), abs(g.disp - w[1]), abs(g.vel - w[2]))
    }
    #expect(worst < 1e-9, "worst deviation \(worst)")
  }

  @Test func theFloorHoldsAndTheFirstFrameHasNoStep() {
    var g = AutoGain()
    g.advance(now: 5000)  // dt = 0: nothing moves
    #expect(g.peak == 0.1 && g.disp == 0.1 && g.vel == 0)
    for i in 1...20_000 { g.advance(now: 5000 + Double(i) * 0.05) }
    #expect(g.peak == 0.05 && abs(g.disp - 0.05) < 1e-6)
    g.observe(peak: 0.9)
    g.step(dt: 10)  // clamped to 0.05
    #expect(g.peak > 0.89 && g.vel > 0 && g.disp > 0.05, "one clamped step, not ten seconds")
  }
}

@MainActor
struct ScopeFeedTests {
  func engine() throws -> (DJEngine, ScopeFeed, ScopeFeed, ScopeFeed) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadNet(
      PreparedTrack(
        spec: TrackSpec(genre: "techno", seed: 42, extra: JSONObject([("bpm", .number(480))])),
        sampleRate: 22_050))
    dj["B"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    dj["B"]!.setPlaying(true)
    let feeds = ScopeFeed.feeds(for: dj)
    return (dj, feeds["A"]!, feeds["B"]!, feeds["master"]!)
  }

  @Test func theMasterTapIsThePostMixSignalAndDeckTapsAreTheirOwn() throws {
    let (dj, a, b, m) = try engine()
    try dj.start()
    defer { dj.stop() }
    dj.master = 0.5
    let ch = try renderChannels(dj, frames: 40_960)
    let left = monoMix(ch[0], ch[1])
    #expect(m.reader.tap.framesWritten == left.count)
    #expect(a.reader.tap.framesWritten == left.count && dj.frame == left.count)
    let tapped = m.reader.tap.recent(8192)
    let want = Array(left.suffix(8192))
    var worst: Float = 0
    for (x, y) in zip(tapped, want) { worst = max(worst, abs(x - y)) }
    #expect(worst < 1e-6, "master tap == rendered output (post master gain), off by \(worst)")
    #expect(want.contains { abs($0) > 0.01 })
    // Decks differ from the master and from each other
    let ta = a.reader.tap.recent(2048)
    let tb = b.reader.tap.recent(2048)
    #expect(ta != tb)
    #expect(ta.contains { abs($0) > 0.001 })
  }

  @Test func netFiresReachTheFeedWithFramesAndNotes() throws {
    let (dj, a, b, _) = try engine()
    try dj.start()
    defer { dj.stop() }
    for _ in 0..<60 { _ = try renderOffline(dj, frames: 2048) }
    a.update(now: 1)
    b.update(now: 1)
    #expect(b.events.isEmpty, "a sample deck fires nothing")
    #expect(a.events.count > 100)
    let tick = a.snapshot?.tick ?? 0
    #expect(tick > 50)
    let written = a.reader.tap.framesWritten
    var last = -1
    var notes = 0
    for e in a.events {
      #expect(e.frame >= 0 && e.frame <= written)
      #expect(e.frame >= last, "events arrive in time order")
      last = e.frame
      if e.note >= 0 {
        notes += 1
        #expect(e.velocity > 0)
      }
      #expect(a.netId(of: e) != nil)
    }
    #expect(notes > 50)
    #expect(a.events.last!.tick <= Int32(tick))
    #expect(a.events(lastSeconds: 0.5).count < a.events.count)
    #expect(a.snapshot?.rings.isEmpty == false)
    #expect(a.reader.count > 10)
  }

  @Test func muteMarksEventsInaudible() throws {
    let (dj, a, _, _) = try engine()
    try dj.start()
    defer { dj.stop() }
    for _ in 0..<20 { _ = try renderOffline(dj, frames: 2048) }
    a.update(now: 1)
    #expect(a.events.contains { $0.isAudible })
    let wave = dj["A"]!.wave
    for n in wave.latest!.graph.nets { wave.setMute(n.id, true) }
    _ = try renderOffline(dj, frames: 2048)  // the command lands
    a.update(now: 2)
    let mark = a.events.count
    for _ in 0..<20 { _ = try renderOffline(dj, frames: 2048) }
    a.update(now: 3)
    let after = a.events[mark...]
    #expect(after.count > 20)
    #expect(after.contains { $0.note >= 0 }, "still reported: they fire, they just do not sound")
    #expect(!after.contains { $0.isAudible })
  }
}
