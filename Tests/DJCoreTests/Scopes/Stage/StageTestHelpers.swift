import Foundation

@testable import DJCore

// Foundation-side helpers for the stage tests (test files that `import Testing` must not import
// Foundation; see AllocationCounter.swift).

func stageNear(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

func stageNear(_ p: StagePoint, _ x: Double, _ y: Double, _ tol: Double = 1e-9) -> Bool {
  stageNear(p.x, x, tol) && stageNear(p.y, y, tol)
}

func stageHyp(_ a: Double, _ b: Double) -> Double { hypot(a, b) }

func stageDegCos(_ d: Double) -> Double { cos(d * Double.pi / 180) }
func stageDegSin(_ d: Double) -> Double { sin(d * Double.pi / 180) }
