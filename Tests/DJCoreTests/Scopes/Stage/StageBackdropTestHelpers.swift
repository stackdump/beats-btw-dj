import Foundation

@testable import DJCore

// Foundation-side helpers for the background tests (test files that `import Testing` must not
// import Foundation; see AllocationCounter.swift).

func bdSin(_ x: Double) -> Double { sin(x) }
func bdCos(_ x: Double) -> Double { cos(x) }
func bdHypot(_ a: Double, _ b: Double) -> Double { hypot(a, b) }
func bdAbs(_ x: Double) -> Double { abs(x) }

/// A `Math.random()` that replays `values` in order, then repeats the last one.
final class BackdropScript {
  private let values: [Double]
  private(set) var calls = 0

  init(_ values: [Double]) { self.values = values }

  func next() -> Double {
    defer { calls += 1 }
    return values[min(calls, values.count - 1)]
  }
}

/// A seeded source as a closure, like the stage model takes.
func backdropRandom(seed: UInt64) -> () -> Double {
  var rng = StageSeededRandom(seed: seed)
  return { rng.next() }
}

/// A context for the background model: only the background and the frame time matter.
func backdropContext(_ mode: StageBackground, dt: Double, width: Double = 800, height: Double = 600)
  -> StageContext
{
  StageContext(
    width: width, height: height,
    layout: StagePanelLayout.layoutRing(width: width, height: height, count: 0), dt: dt,
    bgMode: mode)
}
