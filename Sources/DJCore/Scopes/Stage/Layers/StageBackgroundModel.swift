import Foundation

// The stage's background layer (SPEC mode 18: void, stars with ringed planets, aurora).
// Contract: StageLayerModels.swift. The numbers are `StageBackdrop` (StageBackdrop.swift).
//
// stage.js runs `renderStars(dt)` / `renderAurora(dt)` every frame behind the meta-diagram, and
// the toolbar's select (`context.bgMode`) picks which. This model is the state those two
// functions keep in the `session`:
//
//   * `bgStars` / `bgPlanets`: generated once, when the stars background is first shown, and kept
//     (switching away and back does not respawn them; they respawn only if empty).
//   * `bgAuroraPhase`: ONE clock shared by both backgrounds, advanced by the frame's `dt` while
//     either is drawn. Void draws nothing, so the clock stands still there and picks up where it
//     left off. (It never resets: the JS keeps it for the life of the session.)
//
// Nothing here "clears" on a mode switch: the view is a pure function of (context, model), so the
// frame after a switch simply draws the new background, and no pixel of the old one can remain
// (the JS has to `clearRect` its persistent canvas for the same effect).
//
// `random` stands in for `Math.random()`: a test hands in a seeded source to get the same stars
// and planets every run. This layer is not inside the container transform: the background does
// not spin or tilt.

@MainActor
public final class StageBackgroundModel: StageLayerModel {
  /// The 150 stars, empty until the stars background is first shown.
  public private(set) var stars: [StageStar] = []
  /// The two or three planets (spawned with the stars).
  public private(set) var planets: [StagePlanet] = []
  /// Seconds of background time (`session.bgAuroraPhase`): the twinkle, ring-tilt and aurora clock.
  public private(set) var phase = 0.0
  /// The background of the last frame.
  public private(set) var mode: StageBackground = .void
  /// How many times the starfield was generated (a test watches that it is not redone).
  public private(set) var spawns = 0

  private let random: () -> Double

  public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
    self.random = random
  }

  /// A fixed scene, for tests and tools that need the stars and planets in known places. (An
  /// empty `stars` is respawned from `random` when the stars background is first shown, like the
  /// generated field.)
  public init(
    stars: [StageStar], planets: [StagePlanet],
    random: @escaping () -> Double = { Double.random(in: 0..<1) }
  ) {
    self.stars = stars
    self.planets = planets
    self.random = random
  }

  public func advance(_ context: StageContext) {
    mode = context.bgMode
    switch mode {
    case .void:
      break
    case .stars:
      if stars.isEmpty { spawn() }
      phase += Self.step(context.dt)
    case .aurora:
      phase += Self.step(context.dt)
    }
  }

  /// A frame's elapsed time as the clock takes it: the model lives as long as the app, so one
  /// bad value (NaN, infinity, a negative step) must not poison every star and blob for good.
  /// (`StageModel` already clamps to 0...0.1 s; this guards a caller that does not.)
  static func step(_ dt: Double) -> Double { dt.isFinite ? max(0, dt) : 0 }

  /// `spawnStars` (which also spawns the planets): replace the starfield with a new one.
  public func spawn() {
    stars = StageBackdrop.makeStars(random: random)
    planets = StageBackdrop.makePlanets(random: random)
    spawns += 1
  }
}
