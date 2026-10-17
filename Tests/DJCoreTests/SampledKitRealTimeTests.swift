import Testing

@testable import DJCore

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SampledKitRealTimeTests {
  /// A deck switches from beats' synth kit to a sampled kit mid-render (the hand-over at the
  /// bar), plays it — kicks, snares, hats choking open hats, fills, crashes — and switches
  /// back: the render thread allocates and frees nothing.
  @Test(
    .enabled(if: optimized, "allocation is only meaningful in optimized builds"),
    .enabled(if: floorBank != nil, "no MuseScore_General.sf2 (make soundfonts)"))
  func switchingToASampledKitDoesNotAllocate() throws {
    let sr = 48_000.0
    let src = WaveDeckSource(sampleRate: sr)
    let spec = TrackSpec(genre: "house", seed: 5, structure: "standard")
    let synth = PreparedTrack(spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers))
    let kitted = try #require(
      DeckSourceDescriptor.net(spec).withKit(floorKit, channels: synth.project.drumChannels))
    let sampled = try #require(
      PreparedTrack(source: kitted, sampleRate: sr, opts: .extended(samplers: src.samplers)))
    #expect(sampled.prepared.lanes.contains { !$0.isTonal && $0.samplerSlot >= 0 })
    // the way back, prepared before measuring (as a deck prepares off the audio thread)
    let back = PreparedTrack(spec: spec, sampleRate: sr, opts: .extended(samplers: src.samplers))
    src.load(synth.prepared)
    src.setTempo(480)
    src.play()
    var l = [Float](repeating: 0, count: 512)
    var r = [Float](repeating: 0, count: 512)
    func run(_ n: Int) {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          for _ in 0..<n { src.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) }
        }
      }
    }
    run(100)
    src.load(sampled.prepared)
    let report = countAllocations {
      run(1500)
    }
    #expect(src.activeGeneration == sampled.prepared.generation, "the kit took over")
    #expect(report.allocations == 0, "render allocated \(report.allocations) times")
    #expect(report.frees == 0, "render freed \(report.frees) times")
    src.load(back.prepared)
    let returning = countAllocations { run(400) }
    #expect(returning.allocations == 0, "render allocated \(returning.allocations) times")
    #expect(returning.frees == 0, "render freed \(returning.frees) times")
    src.drainRetired()
  }
}
