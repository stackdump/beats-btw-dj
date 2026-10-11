import Testing

@testable import DJCore

// Canvas gradients as SwiftUI stops (StageOverlayGradient.swift).

struct StageOverlayGradientTests {
  private let stops = StageFlame.stops(energy: 1)

  private func near(_ c: ScopeColor, _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Bool {
    stageNear(c.r * 255, r, 1e-9) && stageNear(c.g * 255, g, 1e-9) && stageNear(c.b * 255, b, 1e-9)
      && stageNear(c.a, a, 1e-12)
  }

  @Test func theCanvasBlendsStraightRGBANotPremultiplied() {
    // halfway from rgba(233,69,96,.7) to rgba(74,144,217,0): the hue travels, the alpha halves
    #expect(near(StageCanvasGradient.color(at: 0.75, stops: stops), 153.5, 106.5, 156.5, 0.35))
    // halfway between amber .85 and rose .7
    #expect(near(StageCanvasGradient.color(at: 0.25, stops: stops), 244, 134.5, 80, 0.775))
  }

  @Test func theStopsThemselvesAndTheEndsAreExact() {
    #expect(StageCanvasGradient.color(at: 0, stops: stops) == stops[0].color)
    #expect(StageCanvasGradient.color(at: 0.5, stops: stops) == stops[1].color)
    #expect(StageCanvasGradient.color(at: 1, stops: stops) == stops[2].color)
    #expect(
      StageCanvasGradient.color(at: -3, stops: stops) == stops[0].color, "held before the first")
    #expect(StageCanvasGradient.color(at: 7, stops: stops) == stops[2].color, "held after the last")
  }

  @Test func resamplingKeepsTheStopsAndAddsEvenSamples() {
    let r = StageCanvasGradient.resampled(stops, segments: 32)
    #expect(r.count == 33, "0.5 is both a stop and a sample")
    #expect(r.first?.location == 0 && r.last?.location == 1)
    #expect(zip(r, r.dropFirst()).allSatisfy { $0.location < $1.location }, "strictly increasing")
    #expect(r.contains { $0.location == 0.5 && $0.color == stops[1].color })
    // every sample is the canvas colour at its place
    for s in r { #expect(s.color == StageCanvasGradient.color(at: s.location, stops: stops)) }
  }

  @Test func aStopBetweenSamplesIsKept() {
    let edge = ScopeColor(r8: 120, g8: 180, b8: 255, a: 0)
    let rim = [
      (0.0, edge), (0.55, ScopeColor(r8: 180, g8: 210, b8: 255, a: 0.1)), (1.0, edge),
    ]
    let r = StageCanvasGradient.resampled(rim, segments: 32)
    #expect(r.count == 34)
    #expect(r.contains { $0.location == 0.55 && $0.color.a == 0.1 })
  }
}
