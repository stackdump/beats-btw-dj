import AVFoundation
import Testing

@testable import DJCore

struct SPSCRingTests {
  @Test func fifoAndFull() {
    let r = SPSCRing<Int>(capacity: 3)
    #expect(r.push(1) && r.push(2) && r.push(3))
    #expect(!r.push(4))
    #expect(r.pop() == 1)
    #expect(r.push(4))
    #expect([r.pop(), r.pop(), r.pop(), r.pop()] == [2, 3, 4, nil])
  }
}

struct TurntableTests {
  let sr = 1000.0  // small rate keeps the arithmetic readable

  /// A ramp: sample i has value i, so output == interpolated position.
  func ramp(_ n: Int) -> SampleBuffer {
    SampleBuffer(left: (0..<n).map(Float.init), sampleRate: sr)
  }

  func run(_ tt: Turntable, _ frames: Int) -> [Float] {
    var out = [Float](repeating: 0, count: frames)
    out.withUnsafeMutableBufferPointer {
      tt.render(frames: frames, left: $0.baseAddress!, right: nil)
    }
    return out
  }

  @Test func silentWhenEmpty() {
    let tt = Turntable(sampleRate: sr)
    #expect(run(tt, 16).allSatisfy { $0 == 0 })
  }

  @Test func motorSpinsUpToUnityRate() {
    let tt = Turntable(sampleRate: sr)
    tt.load(ramp(100_000))
    tt.send(.transport(playing: true))
    _ = run(tt, 2000)  // 2 s >> 45 ms motor time constant
    #expect(abs(tt.currentRate - 1) < 1e-6)
    // Lost ground during spin-up is about one time constant (45 samples).
    #expect(abs(tt.position - (2000 - 45)) < 2)
  }

  @Test func nudgeChangesRate() {
    let tt = Turntable(sampleRate: sr)
    tt.load(ramp(100_000))
    tt.send(.transport(playing: true))
    tt.send(.nudge(ratio: 0.1))
    _ = run(tt, 2000)
    #expect(abs(tt.currentRate - 1.1) < 1e-6)
  }

  @Test func scrubThereAndBackReturnsToStart() {
    let tt = Turntable(sampleRate: sr)
    tt.load(ramp(100_000))
    tt.send(.transport(playing: true))
    _ = run(tt, 500)
    let start = tt.position  // freeze applies before the next sample, so this is the anchor
    tt.send(.freeze)
    for _ in 0..<20 { tt.send(.scrub(samples: 7)) }
    _ = run(tt, 50)
    for _ in 0..<20 { tt.send(.scrub(samples: -7)) }
    _ = run(tt, 3000)
    #expect(abs(tt.position - start) < 0.5)
    #expect(abs(tt.currentRate) < 1e-3)
  }

  @Test func outputIsInterpolatedBuffer() {
    let tt = Turntable(sampleRate: sr)
    tt.load(ramp(100_000))
    tt.send(.transport(playing: true))
    let out = run(tt, 1500)
    // Once at speed, output tracks position: consecutive samples differ by ~1.
    #expect(abs((out[1499] - out[1498]) - 1) < 1e-3)
  }

  @Test func wrapsBackwardsPastZero() {
    let tt = Turntable(sampleRate: sr)
    tt.load(ramp(1000))
    tt.send(.freeze)
    tt.send(.scrub(samples: -100))
    let out = run(tt, 2000)
    #expect(tt.position < -99)
    #expect(abs(out.last! - 900) < 1)  // -100 wraps to 900
  }

  @Test func swappedBufferIsFreedOnMainThread() {
    let tt = Turntable(sampleRate: sr)
    weak var first: SampleBuffer?
    do {
      let b = ramp(10)
      first = b
      tt.load(b)
    }
    _ = run(tt, 1)
    #expect(first != nil)  // held by the turntable
    tt.load(ramp(10))
    _ = run(tt, 1)  // audio thread swaps and retires
    tt.drainRetired()
    #expect(first == nil)
  }
}

struct DJEngineTests {
  @Test func offlineRenderPlaysTheDemoLoop() throws {
    let dj = try DJEngine(decks: ["A"], offline: true)
    let deck = try #require(dj["A"])
    deck.loadDemo()
    deck.setPlaying(true)
    try dj.start()
    defer { dj.stop() }

    let out = AVAudioPCMBuffer(pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: 4096)!
    var peak: Float = 0
    var rendered = 0
    while rendered < 48_000 {
      let status = try dj.engine.renderOffline(4096, to: out)
      #expect(status == .success)
      rendered += Int(out.frameLength)
      let ch = out.floatChannelData![0]
      for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[i])) }
    }
    #expect(peak > 0.1)  // the kick on beat 1 is loud
    #expect(abs(deck.platterSeconds - 1.0) < 0.06)  // ~1 s minus motor spin-up
  }

  @Test func demoLoopIsDeterministic() {
    let a = DemoLoop.make(sampleRate: 8000)
    let b = DemoLoop.make(sampleRate: 8000)
    #expect(a.length == 8000 * 4)
    #expect(memcmp(a.left, b.left, a.length * 4) == 0)
  }
}

struct TurntableLoopTests {
  @Test func loopWrapsThePlayhead() {
    let sr = 1000.0
    let tt = Turntable(sampleRate: sr)
    tt.load(SampleBuffer(left: (0..<100_000).map(Float.init), sampleRate: sr))
    tt.send(.transport(playing: true))
    tt.send(.loop(start: 100, end: 300))
    var out = [Float](repeating: 0, count: 5000)
    out.withUnsafeMutableBufferPointer {
      tt.render(frames: 5000, left: $0.baseAddress!, right: nil)
    }
    #expect(tt.position >= 100 && tt.position < 300)
    tt.send(.loopOff)
    out.withUnsafeMutableBufferPointer {
      tt.render(frames: 1000, left: $0.baseAddress!, right: nil)
    }
    #expect(tt.position > 1000)
  }
}
