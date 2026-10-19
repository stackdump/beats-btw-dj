import Foundation

// StageMinecraftModel: the "Blocks" solo visualizer. A side-on blocky world whose story is the
// track's control track (`StageControlTimeline`), read ahead of the music, so the scene can
// anticipate what the arrangement is about to do instead of only reacting to hits.
//
//   section        biome and time of day, cross-faded over the section's first two beats:
//                  intro dawn plains, verse / chorus / solo day forest, buildup / pre-chorus
//                  dusk, drop night, breakdown / bridge a torch-lit cave, outro sunset. The sun
//                  (moon at night) crosses the sky once per section.
//   buildup → drop a TNT block sits in the middle of the view with its fuse lit at the buildup's
//                  first step; the fuse burns down as `1 - ticksUntilDrop / buildupLength`; the
//                  TNT flashes on every beat of the drop gap (and shakes through the kick out);
//                  on the drop's first tick it explodes: a white flash, a fireball and flying
//                  blocks (a pure function of the steps since the drop), and a crater that stays.
//   roles          each part is a creature or object, spawning and despawning (eased) as the
//                  structure mutes and unmutes it: kick = the ground's top blocks thump on the
//                  beat, bass = a pulsing cube critter, harmony / pads = clouds, melody = birds,
//                  arp = sparkles circling, hats = fireflies, other drums = a walker.
//                  While panels exist their LIVE mute state decides (a DJ's mute is seen at once);
//                  without one, the timeline's.
//   fills          block-break particles off the ground at every step of a `fill-N` chain.
//   stingers       fireworks (lightning in the dark biomes) per stinger fire (`StageFire.isStinger`).
//   macros         rain while one runs (`macroRunning`, or a `macro-curve` event); a tape stop
//                  (or an unnamed live macro) holds the sun back; a beat repeat stutters the blocks.
//   phrases        the camera pans one chunk (16 columns) to new terrain at every phrase start,
//                  except while a TNT is lit (it holds on the TNT until the drop's next phrase).
//
// Deterministic: the terrain, tree, mob colours and debris are hashed from the song's
// `StageControlTimeline.seed`; time comes from the feed's clock (steps) and `ctx.now`, never the
// system clock. The visual level is respected: at level 2 and up stinger effects are skipped (the
// context carries no fires there) and debris / particle counts drop.
//
// Allocation: the scene is written into one of two reused buffers (the view may still hold the
// other), so a frame appends into capacity it already has.

/// What the section looks like.
public enum StageBiome: String, CaseIterable, Sendable {
  case plains, forest, dusk, night, cave, sunset

  public static func of(section name: String) -> StageBiome {
    switch name {
    case "intro": .plains
    case "buildup", "pre-chorus": .dusk
    case "drop": .night
    case "breakdown", "bridge": .cave
    case "outro": .sunset
    default: .forest
    }
  }

  /// Sky colour at the top and at the horizon.
  public var sky: (top: ScopeColor, bottom: ScopeColor) {
    switch self {
    case .plains: (rgb(118, 150, 222), rgb(255, 196, 150))
    case .forest: (rgb(84, 150, 250), rgb(176, 218, 255))
    case .dusk: (rgb(58, 44, 116), rgb(238, 118, 72))
    case .night: (rgb(6, 8, 28), rgb(26, 28, 72))
    case .cave: (rgb(26, 22, 30), rgb(44, 38, 46))
    case .sunset: (rgb(84, 64, 150), rgb(255, 140, 78))
    }
  }

  /// How lit the blocks are (multiplies their colour) and the tint the light has.
  public var light: (level: Double, tint: ScopeColor) {
    switch self {
    case .plains: (0.95, rgb(255, 236, 214))
    case .forest: (1, rgb(255, 255, 255))
    case .dusk: (0.72, rgb(255, 196, 160))
    case .night: (0.42, rgb(150, 170, 255))
    case .cave: (0.58, rgb(255, 196, 140))
    case .sunset: (0.82, rgb(255, 200, 160))
    }
  }

  var hasTrees: Bool { self != .plains && self != .cave }
}

/// One rectangle of the scene, in stage coordinates.
public struct StageVoxel: Equatable, Sendable {
  public enum Style: UInt8, Sendable {
    /// A shaded block: lighter top edge, darker right and bottom edges, a few texture specks.
    case block
    /// A plain fill (pixels of a creature, rain, fuse).
    case flat
    /// A light: drawn additively with a soft halo (sparks, torches, fireworks).
    case glow
  }

  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double
  public var color: ScopeColor
  public var style: Style

  public init(x: Double, y: Double, w: Double, h: Double, color: ScopeColor, style: Style) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.color = color
    self.style = style
  }
}

/// What a role is in the world.
public enum StageMobKind: String, Sendable {
  case ground, critter, cloud, bird, sparkle, firefly, walker

  public static func of(role: String) -> StageMobKind {
    let r = role.lowercased()
    if r.contains("kick") { return .ground }
    if r.contains("bass") { return .critter }
    if r.contains("harmony") || r.contains("pad") || r.contains("chord") { return .cloud }
    if r.contains("melody") || r.contains("lead") { return .bird }
    if r.contains("arp") { return .sparkle }
    if r.contains("hat") { return .firefly }
    return .walker
  }
}

/// One role's creature this frame.
public struct StageMob: Equatable, Sendable {
  public var role: String
  public var kind: StageMobKind
  /// 0 gone ... 1 fully there (eased toward whether the role sounds).
  public var presence: Double
  /// Does the role sound right now (what `presence` eases toward)?
  public var active: Bool
  /// Where it is (its feet, or its centre for a flyer).
  public var x: Double
  public var y: Double
}

/// Everything the layer draws for one frame.
public struct StageMinecraftScene: Equatable, Sendable {
  public var width = 0.0
  public var height = 0.0
  /// The song step the scene shows.
  public var step = 0.0
  public var section = ""
  public var biome = StageBiome.forest
  public var skyTop = StageBiome.forest.sky.top
  public var skyBottom = StageBiome.forest.sky.bottom
  /// Sun (or moon) centre and size; nil underground.
  public var celestial: StagePoint?
  public var celestialSize = 0.0
  public var isMoon = false
  /// 0...1: how much of the starfield shows.
  public var stars = 0.0
  /// Block size, points.
  public var block = 0.0
  /// The camera's world x, points.
  public var cameraX = 0.0
  /// 0...1 while a TNT is lit (how far the fuse has burnt), nil otherwise.
  public var fuse: Double?
  /// 0...1: the TNT's white flash in the drop gap.
  public var tntFlash = 0.0
  /// Seconds since the drop's first tick while the explosion is on screen.
  public var explosionAge: Double?
  /// 0...1: a white wash over everything (explosion, lightning).
  public var flash = 0.0
  public var raining = false
  public var stutter = false
  /// The beat's thump of the ground, 0...1 (0 while the kick is out).
  public var thump = 0.0
  public var mobs: [StageMob] = []
  /// Back to front.
  public var voxels: [StageVoxel] = []

  public init() {}
}

@MainActor
public final class StageMinecraftModel: StageLayerModel {
  /// Columns per camera chunk.
  public static let chunkColumns = 16
  /// Steps a pan to the next chunk takes.
  public static let panSteps = 8.0
  /// Steps a biome cross-fade takes.
  public static let fadeSteps = 8.0
  /// How long the debris of an explosion flies, seconds.
  public static let explosionLife = 2.6
  /// Debris blocks per explosion (and at visual level 2 and up).
  public static let debrisCount = 44
  public static let debrisCountMinimal = 12
  /// Fireworks alive at once.
  public static let fireworkSlots = 6
  public static let fireworkLife = 1.3

  /// The control schedule of the song showing (empty for a loop or no net).
  public private(set) var timeline = StageControlTimeline.empty
  /// The roles creatures are kept for: the timeline's, then any panel role it lacks.
  public private(set) var roles: [String] = []

  private var scenes = [StageMinecraftScene(), StageMinecraftScene()]
  private var current = 0
  private var presence: [Double] = []
  private var builtSerial: Int32?
  private var builtEpoch: Int?
  private var builtHasProject = false
  private var macroLag = 0.0
  private var lastStep: Double?
  private var fireworks: [Firework] = []
  private var fireworkNext = 0

  private struct Firework {
    var born: Double
    var x: Double
    var y: Double
    var hue: Double
    var lightning: Bool
  }

  public init() {
    for i in scenes.indices {
      scenes[i].voxels.reserveCapacity(2200)
      scenes[i].mobs.reserveCapacity(16)
    }
    fireworks.reserveCapacity(Self.fireworkSlots)
  }

  /// The last frame's scene.
  public var scene: StageMinecraftScene { scenes[current] }

  public func reset() {
    presence = presence.map { _ in 0 }
    fireworks.removeAll(keepingCapacity: true)
    macroLag = 0
    lastStep = nil
  }

  // MARK: per frame

  public func advance(_ ctx: StageContext) {
    guard ctx.visualizer == .minecraft else { return }
    guard let feed = ctx.feed else {
      advance(ctx, timeline: timeline, step: lastStep ?? 0, tickSec: 0.125, macroActive: false)
      return
    }
    let hasProject = feed.leadProject != nil
    if builtSerial != feed.trackSerial || builtHasProject != hasProject || builtEpoch != ctx.epoch {
      // a new song (or the first one): its schedule, built once
      let serialChanged = builtSerial != feed.trackSerial || builtHasProject != hasProject
      builtSerial = feed.trackSerial
      builtHasProject = hasProject
      builtEpoch = ctx.epoch
      if serialChanged {
        let t = feed.leadProject.map { StageControlTimeline.build($0) } ?? .empty
        setTimeline(t, panels: ctx.panels)
      } else {
        setRoles(panels: ctx.panels)
      }
    }
    let c = feed.clock
    let step = max(0, Double(c.tick - 1) + c.tickPhase)
    advance(
      ctx, timeline: timeline, step: step, tickSec: c.tickSec,
      macroActive: ctx.macroRunning || c.macroActive)
  }

  /// Install a schedule (tests, or a track change).
  public func setTimeline(_ t: StageControlTimeline, panels: [StagePanel] = []) {
    timeline = t
    setRoles(panels: panels)
    macroLag = 0
    lastStep = nil
    fireworks.removeAll(keepingCapacity: true)
  }

  private func setRoles(panels: [StagePanel]) {
    var names = timeline.roles
    for p in panels {
      let r = Self.role(of: p)
      if !names.contains(r) { names.append(r) }
    }
    var kept: [Double] = []
    for r in names { kept.append(roles.firstIndex(of: r).map { presence[$0] } ?? 0) }
    roles = names
    presence = kept
  }

  static func role(of p: StagePanel) -> String { p.riffGroup.isEmpty ? p.netId : p.riffGroup }

  /// One frame at song step `step` (`ScopeClock`: `tick - 1 + tickPhase`), `tickSec` seconds a
  /// step. Everything else comes from `ctx`.
  public func advance(
    _ ctx: StageContext, timeline t: StageControlTimeline, step: Double, tickSec: Double,
    macroActive: Bool
  ) {
    if t != timeline { setTimeline(t, panels: ctx.panels) }
    if roles.isEmpty && !ctx.panels.isEmpty { setRoles(panels: ctx.panels) }
    let dSteps = lastStep.map { max(0, step - $0) } ?? 0
    lastStep = step
    current = 1 - current
    var s = scenes[current]
    scenes[current] = StageMinecraftScene()  // drop the buffer's other reference
    compose(
      &s, ctx: ctx, step: step, dSteps: dSteps, tickSec: max(1e-3, tickSec),
      macroActive: macroActive)
    scenes[current] = s
  }

  // MARK: composition

  private func compose(
    _ s: inout StageMinecraftScene, ctx: StageContext, step: Double, dSteps: Double,
    tickSec: Double, macroActive: Bool
  ) {
    let t = timeline
    let w = ctx.width
    let h = ctx.height
    let seed = t.seed
    let minimal = ctx.vizLevel >= 2
    s.voxels.removeAll(keepingCapacity: true)
    s.mobs.removeAll(keepingCapacity: true)
    s.width = w
    s.height = h
    s.step = step
    let bs = max(10, (h / 20).rounded())
    s.block = bs
    let groundBase = (h * 0.72 / bs).rounded() * bs

    // Section, biome, cross-fade from the previous section's.
    let k = t.sectionIndex(at: step)
    let name = k.map { t.sections[$0].name } ?? ""
    s.section = name
    let biome = k == nil ? StageBiome.forest : StageBiome.of(section: name)
    s.biome = biome
    var fade = 1.0
    var prev = biome
    if let k, k > 0 {
      prev = StageBiome.of(section: t.sections[k - 1].name)
      fade = smooth((step - Double(t.sections[k].startTick)) / Self.fadeSteps)
    }
    let sky = biome.sky
    let psky = prev.sky
    s.skyTop = blend(psky.top, sky.top, fade)
    s.skyBottom = blend(psky.bottom, sky.bottom, fade)
    let lightLevel = mixd(prev.light.level, biome.light.level, fade)
    let tint = blend(prev.light.tint, biome.light.tint, fade)

    // Macros: weather and time.
    let macro = t.covering(.macro, at: step)
    let running = macroActive || macro != nil
    let tape = macro?.name == "tape-stop" || (running && macro == nil)
    s.raining = running
    s.stutter = macro?.name == "beat-repeat"
    if tape {
      macroLag += dSteps * 0.8
    } else {
      macroLag *= exp(-ctx.dt * 1.5)
    }
    if running {
      s.skyTop = s.skyTop.scaled(0.7)
      s.skyBottom = s.skyBottom.scaled(0.75)
    }
    let light = lightLevel * (running ? 0.8 : 1)

    // Sun or moon: one crossing per section.
    let secSteps = k.map { Double(max(1, t.sections[$0].steps)) } ?? 256
    var progress =
      k == nil ? (step / 256).truncatingRemainder(dividingBy: 1) : t.sectionProgress(at: step)
    progress = min(1, max(0, progress - macroLag / secSteps))
    if biome == .cave {
      s.celestial = nil
    } else {
      let startX = biome == .sunset ? 0.35 : 0.08
      let span = biome == .sunset ? 0.55 : 0.84
      let rise = biome == .plains ? 0.45 + 0.4 * progress : 1
      s.celestial = StagePoint(
        x: w * (startX + span * progress),
        y: groundBase - sin(Double.pi * (biome == .sunset ? 0.5 + 0.5 * progress : progress))
          * groundBase * 0.75 * rise)
      s.celestialSize = bs * 2.4
      s.isMoon = biome == .night
    }
    s.stars =
      biome == .night ? fade : (prev == .night ? 1 - fade : (biome == .dusk ? 0.35 * progress : 0))

    // Camera: a chunk per phrase, held on a lit TNT until the drop's next phrase.
    let chunk = Double(Self.chunkColumns) * bs
    let (fromIdx, toIdx, panStart) = cameraIndices(step)
    let pan = smooth((step - panStart) / Self.panSteps)
    s.cameraX = chunk * (Double(fromIdx) + Double(toIdx - fromIdx) * pan)
    let cam = s.cameraX

    // The TNT: in the middle of the view the camera holds on through its buildup.
    let fuse = t.fuse(at: step)
    let drop = t.last(.drop, atOrBefore: step)
    let dropAge = drop.map { (step - Double($0.tick)) * tickSec }
    let centerCol = Int(((cam + w / 2) / bs).rounded(.down))
    // the column the TNT stands on: the held camera's centre
    func tntColumn(buildupTick: Int) -> Int {
      let idx = t.last(.phrase, atOrBefore: Double(buildupTick))?.index ?? 0
      return Int(((chunk * Double(idx) + w / 2) / bs).rounded(.down))
    }
    var tntCol: Int?
    if let f = fuse { tntCol = tntColumn(buildupTick: f.buildup.tick) }
    var blastCol: Int?
    var blastActive = false
    if let drop, let age = dropAge, step < Double(drop.end) {
      if let b = t.last(.buildup, atOrBefore: Double(drop.tick) - 1), b.end == drop.tick {
        blastCol = tntColumn(buildupTick: b.tick)
      } else {
        blastCol = centerCol
      }
      blastActive = age < Self.explosionLife
    }
    s.fuse = fuse?.progress
    let gap = t.covering(.dropGap, at: step)
    s.tntFlash = gap != nil ? 0.5 + 0.5 * cos(2 * Double.pi * step / 4) : 0
    s.explosionAge = blastActive ? dropAge : nil

    // Who sounds.
    var thumpPresence = 0.0
    for (i, r) in roles.enumerated() {
      let on = isActive(role: r, panels: ctx.panels, step: step)
      presence[i] += ((on ? 1 : 0) - presence[i]) * min(1, ctx.dt * 5)
      if presence[i] < 1e-3 && !on { presence[i] = 0 }
      if StageMobKind.of(role: r) == .ground { thumpPresence = max(thumpPresence, presence[i]) }
    }
    let beat = step.truncatingRemainder(dividingBy: 4)
    let kickOut = t.covering(.kickOut, at: step) != nil || gap != nil
    s.thump = kickOut ? 0 : thumpPresence * exp(-beat * 1.4)

    // Terrain.
    let firstCol = Int((cam / bs).rounded(.down)) - 1
    let cols = Int((w / bs).rounded(.up)) + 3
    let palette = Palette(biome: biome, prev: prev, fade: fade, light: light, tint: tint)
    func surface(_ c: Int) -> Int {
      var hgt = terrainHeight(c, seed: seed)
      if let bc = blastCol, step >= Double(drop?.tick ?? 0) {
        let d = abs(c - bc)
        if d <= 2 { hgt -= 3 - d }
      }
      return hgt
    }

    // underground nothing of the sky shows
    let caveness = biome == .cave ? fade : (prev == .cave ? 1 - fade : 0)
    let open = 1 - caveness
    s.stars *= open

    // stars
    if s.stars > 0.01 {
      for i in 0..<40 {
        let x = unit(seed, 900, i) * w
        let y = unit(seed, 901, i) * groundBase * 0.6
        let tw = 0.55 + 0.45 * sin(ctx.now * 2 + Double(i))
        let size = max(2, bs * (unit(seed, 902, i) < 0.2 ? 0.22 : 0.14))
        s.voxels.append(
          StageVoxel(
            x: x, y: y, w: size, h: size, color: ScopeColor(r: 1, g: 1, b: 0.92, a: s.stars * tw),
            style: .flat))
      }
    }

    // sun / moon
    if let c = s.celestial, open > 0.01 {
      let size = s.celestialSize
      let col =
        s.isMoon
        ? ScopeColor(r: 0.9, g: 0.92, b: 1)
        : (biome == .sunset || biome == .dusk
          ? ScopeColor(r: 1, g: 0.62, b: 0.3) : ScopeColor(r: 1, g: 0.93, b: 0.55))
      s.voxels.append(
        StageVoxel(
          x: c.x - size * 0.8, y: c.y - size * 0.8, w: size * 1.6, h: size * 1.6,
          color: col.withAlpha(0.25 * open), style: .glow))
      s.voxels.append(
        StageVoxel(
          x: c.x - size / 2, y: c.y - size / 2, w: size, h: size, color: col.withAlpha(open),
          style: .flat))
      if s.isMoon {
        // craters
        let q = size / 4
        s.voxels.append(
          StageVoxel(x: c.x - q * 1.2, y: c.y - q, w: q, h: q, color: col.scaled(0.8), style: .flat)
        )
        s.voxels.append(
          StageVoxel(
            x: c.x + q * 0.4, y: c.y + q * 0.3, w: q * 0.8, h: q * 0.8, color: col.scaled(0.82),
            style: .flat))
      }
    }

    // clouds (harmony)
    for (i, r) in roles.enumerated() where StageMobKind.of(role: r) == .cloud && presence[i] > 0.01
    {
      for j in 0..<3 {
        let span = w + 8 * bs
        let x0 = unit(seed, 300 + i, j) * span + step * bs * 0.04 * Double(j + 2)
        let x = x0.truncatingRemainder(dividingBy: span) - 4 * bs
        let y = groundBase * (0.12 + 0.12 * Double(j)) + unit(seed, 310 + i, j) * bs
        cloud(
          &s, x: x, y: y, bs: bs, alpha: presence[i] * open * (biome == .night ? 0.35 : 0.92),
          seed: seed, j: j)
        if j == 0 {
          s.mobs.append(
            StageMob(
              role: r, kind: .cloud, presence: presence[i], active: presence[i] > 0.5, x: x, y: y))
        }
      }
    }

    // the cave's back wall and ceiling
    if caveness > 0.01 {
      for i in 0..<cols {
        let c = firstCol + i
        let x = Double(c) * bs - cam
        var wy = 0.0
        while wy < groundBase {
          let dark = unit(seed, 502, c &* 131 &+ Int(wy / bs)) < 0.12 ? 0.32 : 0.4
          s.voxels.append(
            StageVoxel(
              x: x, y: wy, w: bs, h: bs, color: palette.stone.scaled(dark).withAlpha(caveness),
              style: .block))
          wy += bs
        }
        let depth = 1 + Int(unit(seed, 500, c) * 3)
        for row in 0..<depth {
          s.voxels.append(
            StageVoxel(
              x: x, y: Double(row) * bs, w: bs, h: bs,
              color: palette.stone.scaled(0.75).withAlpha(caveness), style: .block))
        }
        if unit(seed, 501, c) < 0.25 {
          s.voxels.append(
            StageVoxel(
              x: x + bs * 0.3, y: Double(depth) * bs, w: bs * 0.4, h: bs * 0.5,
              color: palette.stone.scaled(0.65).withAlpha(caveness), style: .flat))
        }
      }
    }

    // ground
    let thumpLift = s.thump * bs * 0.32
    for i in 0..<cols {
      let c = firstCol + i
      let x = Double(c) * bs - cam
      let hgt = surface(c)
      var top = groundBase - Double(hgt) * bs
      // the kick's thump ripples out from the middle
      let ripple = exp(-Double(abs(c - centerCol)) * 0.12)
      top -= thumpLift * ripple
      if s.stutter, c % 2 != 0 {
        top += (Int(step * 2) % 2 == 0 ? 1 : -1) * bs * 0.25
      }
      var y = top
      var row = 0
      while y < h {
        let color: ScopeColor
        if row == 0 {
          color = biome == .cave ? palette.mossyStone : palette.grass
        } else if row < 3 {
          color = palette.dirt
        } else if unit(seed, 700 + row, c) < 0.06 {
          color = palette.ore
        } else {
          color = palette.stone
        }
        s.voxels.append(StageVoxel(x: x, y: y, w: bs, h: bs, color: color, style: .block))
        y += bs
        row += 1
      }
      // grass tuft on the top
      if row > 0, biome != .cave, unit(seed, 710, c) < 0.5 {
        s.voxels.append(
          StageVoxel(
            x: x, y: top, w: bs, h: bs * 0.22, color: palette.grass.scaled(1.15), style: .flat))
      }
      // flora: trees, flowers, torches
      let nearBlast =
        (tntCol.map { abs(c - $0) <= 2 } ?? false) || (blastCol.map { abs(c - $0) <= 3 } ?? false)
      if !nearBlast {
        if biome.hasTrees, unit(seed, 720, c) < 0.11, c % 3 != 0 {
          tree(&s, x: x, top: top, bs: bs, palette: palette, seed: seed, c: c)
        } else if biome == .plains || biome == .sunset, unit(seed, 730, c) < 0.22 {
          let fc =
            unit(seed, 731, c) < 0.5
            ? ScopeColor(r: 0.95, g: 0.25, b: 0.25) : ScopeColor(r: 1, g: 0.85, b: 0.2)
          s.voxels.append(
            StageVoxel(
              x: x + bs * 0.45, y: top - bs * 0.45, w: bs * 0.1, h: bs * 0.45, color: palette.leaf,
              style: .flat))
          s.voxels.append(
            StageVoxel(
              x: x + bs * 0.35, y: top - bs * 0.6, w: bs * 0.3, h: bs * 0.25,
              color: palette.lit(fc),
              style: .flat))
        }
        if caveness > 0.01, c % 7 == 0 {
          let flicker = 0.75 + 0.25 * sin(ctx.now * 9 + Double(c))
          s.voxels.append(
            StageVoxel(
              x: x + bs * 0.42, y: top - bs * 0.6, w: bs * 0.16, h: bs * 0.6,
              color: ScopeColor(r: 0.45, g: 0.3, b: 0.15, a: caveness), style: .flat))
          s.voxels.append(
            StageVoxel(
              x: x + bs * 0.36, y: top - bs * 0.78, w: bs * 0.28, h: bs * 0.26,
              color: ScopeColor(r: 1, g: 0.8, b: 0.3, a: caveness), style: .flat))
          s.voxels.append(
            StageVoxel(
              x: x - bs * 0.9, y: top - bs * 2.1, w: bs * 2.8, h: bs * 2.8,
              color: ScopeColor(r: 1, g: 0.6, b: 0.2, a: 0.22 * flicker * caveness), style: .glow))
        }
      }
    }

    // ground creatures
    var walkers = 0
    for (i, r) in roles.enumerated() where presence[i] > 0.01 {
      let kind = StageMobKind.of(role: r)
      let p = presence[i]
      switch kind {
      case .critter:
        let x = w * 0.27 + sin(step * 2 * Double.pi / 64 + Double(i)) * bs * 3
        let c = Int(((x + cam) / bs).rounded(.down))
        let foot = groundBase - Double(surface(c)) * bs
        let pulse = 1 + 0.2 * exp(-beat * 1.5)
        critter(&s, x: x, foot: foot, bs: bs, scale: p * pulse, seed: seed, i: i, palette: palette)
        s.mobs.append(StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: x, y: foot))
      case .walker:
        let x =
          w * (0.74 + 0.09 * Double(walkers)) + sin(step * 2 * Double.pi / 128 + Double(i)) * bs
          * 2.5
        let c = Int(((x + cam) / bs).rounded(.down))
        let foot = groundBase - Double(surface(c)) * bs
        walker(
          &s, x: x, foot: foot, bs: bs, alpha: p, step: step, seed: seed, i: i, palette: palette)
        s.mobs.append(StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: x, y: foot))
        walkers += 1
      case .firefly:
        var fx = 0.0
        var fy = 0.0
        for j in 0..<6 {
          let x = unit(seed, 400 + i, j) * w + sin(step * 0.13 + Double(j)) * bs * 2
          let y =
            groundBase - bs * (2.2 + unit(seed, 401 + i, j) * 2) + cos(step * 0.17 + Double(j)) * bs
          let on = 0.5 + 0.5 * sin(ctx.now * 4 + Double(j) * 1.7)
          s.voxels.append(
            StageVoxel(
              x: x - bs * 0.5, y: y - bs * 0.5, w: bs, h: bs,
              color: ScopeColor(r: 0.8, g: 1, b: 0.3, a: 0.25 * p * on), style: .glow))
          s.voxels.append(
            StageVoxel(
              x: x - bs * 0.1, y: y - bs * 0.1, w: bs * 0.2, h: bs * 0.2,
              color: ScopeColor(r: 0.9, g: 1, b: 0.5, a: p), style: .flat))
          if j == 0 {
            fx = x
            fy = y
          }
        }
        s.mobs.append(StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: fx, y: fy))
      case .bird:
        var bx = 0.0
        var by = 0.0
        for j in 0..<3 {
          let span = w + 6 * bs
          let x =
            (unit(seed, 600 + i, 0) * span + step * bs * 0.3 + Double(j) * bs * 1.8)
            .truncatingRemainder(dividingBy: span) - 3 * bs
          let y =
            groundBase * 0.32 + Double(j % 2) * bs * 0.8 + sin(step * 0.2 + Double(j)) * bs * 0.6
          bird(
            &s, x: x, y: y, bs: bs, alpha: p * open, up: (Int(step) + j) % 2 == 0,
            palette: palette, seed: seed, i: i)
          if j == 0 {
            bx = x
            by = y
          }
        }
        s.mobs.append(StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: bx, y: by))
      case .sparkle:
        let cx = w * 0.5
        let cy = groundBase - bs * 5
        for j in 0..<8 {
          let a = step * 0.4 + Double(j) * 2 * Double.pi / 8
          let x = cx + cos(a) * bs * 2.6
          let y = cy + sin(a) * bs * 1.2
          let col = ScopeColor.hsla(Double((j * 45 + Int(step) * 12) % 360), 90, 65, p)
          s.voxels.append(
            StageVoxel(
              x: x - bs * 0.15, y: y - bs * 0.15, w: bs * 0.3, h: bs * 0.3, color: col, style: .glow
            ))
        }
        s.mobs.append(StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: cx, y: cy))
      case .ground:
        s.mobs.append(
          StageMob(role: r, kind: kind, presence: p, active: p > 0.5, x: w / 2, y: groundBase))
      case .cloud:
        break  // drawn behind the terrain
      }
    }

    // The TNT and its fuse.
    if let f = fuse, let tc = tntCol {
      let x0 = Double(tc) * bs - cam
      let shake =
        t.covering(.kickOut, at: step) != nil ? (Int(step) % 2 == 0 ? 1 : -1) * bs * 0.06 : 0
      let x = x0 + shake
      let top = groundBase - Double(surface(tc)) * bs - bs
      let white = s.tntFlash
      let red = blend(
        palette.lit(ScopeColor(r: 0.86, g: 0.16, b: 0.12)), .init(r: 1, g: 1, b: 1), white)
      s.voxels.append(StageVoxel(x: x, y: top, w: bs, h: bs, color: red, style: .block))
      s.voxels.append(
        StageVoxel(
          x: x, y: top + bs * 0.36, w: bs, h: bs * 0.28,
          color: blend(
            palette.lit(ScopeColor(r: 0.92, g: 0.9, b: 0.86)), .init(r: 1, g: 1, b: 1), white),
          style: .flat))
      // "TNT" in three dark pixel bars
      for j in 0..<3 {
        s.voxels.append(
          StageVoxel(
            x: x + bs * (0.16 + 0.26 * Double(j)), y: top + bs * 0.42, w: bs * 0.16, h: bs * 0.16,
            color: ScopeColor(r: 0.15, g: 0.12, b: 0.12), style: .flat))
      }
      // the fuse: shorter as it burns
      let len = (1 - f.progress) * bs * 1.2
      let segs = max(1, Int((len / (bs * 0.15)).rounded(.up)))
      for j in 0..<segs {
        let fy = top - Double(j + 1) * bs * 0.15
        let fx = x + bs * 0.45 + sin(Double(j) * 0.9) * bs * 0.12
        s.voxels.append(
          StageVoxel(
            x: fx, y: fy, w: bs * 0.12, h: bs * 0.15, color: ScopeColor(r: 0.75, g: 0.7, b: 0.6),
            style: .flat))
      }
      let tipY = top - Double(segs) * bs * 0.15
      let flick = 0.7 + 0.3 * sin(ctx.now * 23)
      s.voxels.append(
        StageVoxel(
          x: x + bs * 0.05, y: tipY - bs * 0.4, w: bs * 0.9, h: bs * 0.9,
          color: ScopeColor(r: 1, g: 0.75, b: 0.2, a: 0.45 * flick), style: .glow))
      s.voxels.append(
        StageVoxel(
          x: x + bs * 0.4, y: tipY - bs * 0.05, w: bs * 0.2, h: bs * 0.2,
          color: ScopeColor(r: 1, g: 0.95, b: 0.6), style: .glow))
      if white > 0.5 {
        s.voxels.append(
          StageVoxel(
            x: x - bs, y: top - bs, w: bs * 3, h: bs * 3,
            color: ScopeColor(r: 1, g: 1, b: 1, a: 0.3 * white), style: .glow))
      }
    }

    // Fill: blocks breaking off the ground at every step of the fill.
    if let fill = t.covering(.fill, at: step) {
      let per = minimal ? 2 : 6
      var k = fill.tick
      while Double(k) <= step && k < fill.end {
        let age = (step - Double(k)) * tickSec
        if age < 0.6 {
          let c = centerCol + Int(unit(seed, 800 + fill.index, k) * 13) - 6
          let x = Double(c) * bs - cam + bs / 2
          let y = groundBase - Double(surface(c)) * bs
          for j in 0..<per {
            let a = -Double.pi * (0.15 + 0.7 * unit(seed, 810 + k, j))
            let v = h * (0.35 + 0.5 * unit(seed, 811 + k, j))
            let px = x + cos(a) * v * age
            let py = y + sin(a) * v * age + 0.5 * h * 2.2 * age * age
            let size = bs * (0.2 + 0.15 * unit(seed, 812 + k, j))
            let col = j % 2 == 0 ? palette.dirt : palette.grass
            s.voxels.append(
              StageVoxel(
                x: px - size / 2, y: py - size / 2, w: size, h: size,
                color: col.withAlpha(1 - age / 0.6), style: .block))
          }
          // a crack on the struck block
          s.voxels.append(
            StageVoxel(
              x: x - bs * 0.3, y: y + bs * 0.2, w: bs * 0.6, h: bs * 0.08,
              color: ScopeColor(r: 0, g: 0, b: 0, a: 0.6 * (1 - age / 0.6)), style: .flat))
        }
        k += 1
      }
    }

    // The explosion.
    var flash = 0.0
    if blastActive, let age = dropAge, let bc = blastCol, let drop {
      let ox = Double(bc) * bs - cam + bs / 2
      let oy = groundBase - Double(terrainHeight(bc, seed: seed)) * bs - bs / 2
      // (not quite white: the world's silhouette stays readable through it)
      flash = max(flash, 0.88 * (1 - age / 0.45))
      if age < 0.6 {
        let r = bs * (1.5 + age * 14)
        s.voxels.append(
          StageVoxel(
            x: ox - r, y: oy - r, w: 2 * r, h: 2 * r,
            color: ScopeColor(r: 1, g: 0.7, b: 0.25, a: 0.7 * (1 - age / 0.6)), style: .glow))
        s.voxels.append(
          StageVoxel(
            x: ox - r * 0.45, y: oy - r * 0.45, w: r * 0.9, h: r * 0.9,
            color: ScopeColor(r: 1, g: 0.95, b: 0.7, a: 1 - age / 0.6), style: .glow))
      }
      let n = minimal ? Self.debrisCountMinimal : Self.debrisCount
      let g = h * 1.8
      let fadeOut = min(1, (Self.explosionLife - age) / 0.6)
      for j in 0..<n {
        let a = -Double.pi * (0.06 + 0.88 * unit(seed, 1000 + drop.index, j))
        let v = h * (0.55 + 0.75 * unit(seed, 1001 + drop.index, j))
        let px = ox + cos(a) * v * age
        let py = oy + sin(a) * v * age + 0.5 * g * age * age
        guard py < h + bs else { continue }
        let size = bs * (0.35 + 0.4 * unit(seed, 1002 + drop.index, j))
        let pick = Int(unit(seed, 1003 + drop.index, j) * 5)
        let col: ScopeColor =
          switch pick {
          case 0: ScopeColor(r: 0.86, g: 0.16, b: 0.12)
          case 1: palette.grass
          case 2: palette.dirt
          case 3: palette.stone
          default: ScopeColor(r: 0.95, g: 0.9, b: 0.85)
          }
        s.voxels.append(
          StageVoxel(
            x: px - size / 2, y: py - size / 2, w: size, h: size, color: col.withAlpha(fadeOut),
            style: .block))
      }
    }

    // Stingers: fireworks, or lightning in the dark.
    if !minimal {
      for f in ctx.fires where f.isStinger {
        let dark = biome == .night || biome == .cave || biome == .dusk
        let fw = Firework(
          born: f.wallTime, x: w * (0.15 + 0.7 * unit(seed, 1100, f.note + Int(f.wallTime * 10))),
          y: groundBase * (0.18 + 0.2 * unit(seed, 1101, f.note)), hue: Double((f.note * 47) % 360),
          lightning: dark)
        if fireworks.count < Self.fireworkSlots {
          fireworks.append(fw)
        } else {
          fireworks[fireworkNext] = fw
          fireworkNext = (fireworkNext + 1) % Self.fireworkSlots
        }
      }
    }
    for fw in fireworks {
      let age = ctx.now - fw.born
      guard age >= 0, age < Self.fireworkLife else { continue }
      if fw.lightning {
        flash = max(flash, 0.55 * exp(-age * 9))
        if age < 0.35 {
          var y = 0.0
          var x = fw.x
          var j = 0
          while y < groundBase {
            s.voxels.append(
              StageVoxel(
                x: x - bs * 0.15, y: y, w: bs * 0.3, h: bs * 0.5,
                color: ScopeColor(r: 0.9, g: 0.95, b: 1, a: 1 - age / 0.35), style: .glow))
            y += bs * 0.5
            x += (unit(seed, 1200, j + Int(fw.born * 100)) - 0.5) * bs * 0.9
            j += 1
          }
        }
      } else {
        let a = 1 - age / Self.fireworkLife
        let col = ScopeColor.hsla(fw.hue, 95, 65, a)
        for j in 0..<16 {
          let ang = Double(j) * 2 * Double.pi / 16
          let r = bs * 6 * (1 - exp(-age * 3))
          let px = fw.x + cos(ang) * r
          let py = fw.y + sin(ang) * r + h * 0.08 * age * age
          s.voxels.append(
            StageVoxel(
              x: px - bs * 0.18, y: py - bs * 0.18, w: bs * 0.36, h: bs * 0.36, color: col,
              style: .glow
            ))
        }
        flash = max(flash, 0.12 * exp(-age * 10))
      }
    }

    // Rain.
    if s.raining {
      let drops = minimal ? 30 : 90
      for j in 0..<drops {
        let x = unit(seed, 1300, j) * w
        let y =
          (unit(seed, 1301, j) * h + ctx.now * h * 1.4).truncatingRemainder(dividingBy: h + bs) - bs
        s.voxels.append(
          StageVoxel(
            x: x, y: y, w: max(1, bs * 0.08), h: bs * 0.6,
            color: ScopeColor(r: 0.6, g: 0.7, b: 1, a: 0.55), style: .flat))
      }
    }

    s.flash = min(1, flash)
  }

  /// The camera's chunk: (pan from, pan to, the step the pan started).
  private func cameraIndices(_ step: Double) -> (Int, Int, Double) {
    let t = timeline
    guard let p = t.last(.phrase, atOrBefore: step) else { return (0, 0, 0) }
    let idx = heldIndex(step, phrase: p)
    let before = p.tick > 0 ? t.last(.phrase, atOrBefore: Double(p.tick) - 1) : nil
    let prevIdx = before.map { heldIndex(Double(p.tick) - 1, phrase: $0) } ?? idx
    return (prevIdx, idx, Double(p.tick))
  }

  /// The phrase index the camera wants at `step`: the phrase's own, or the buildup's first one
  /// while a TNT is lit and through the drop's first phrase.
  private func heldIndex(_ step: Double, phrase p: StageControlEvent) -> Int {
    let t = timeline
    if let b = t.covering(.buildup, at: step) {
      return t.last(.phrase, atOrBefore: Double(b.tick))?.index ?? p.index
    }
    if let d = t.covering(.drop, at: step),
      let first = t.last(.phrase, atOrBefore: Double(d.tick)), first.index == p.index,
      let b = t.last(.buildup, atOrBefore: Double(d.tick) - 1), b.end == d.tick
    {
      return t.last(.phrase, atOrBefore: Double(b.tick))?.index ?? p.index
    }
    return p.index
  }

  private func isActive(role r: String, panels: [StagePanel], step: Double) -> Bool {
    var seen = false
    for p in panels where Self.role(of: p) == r {
      seen = true
      if !p.muted { return true }
    }
    if seen { return false }
    return timeline.isActive(role: r, at: step)
  }

  // MARK: sprites (original pixel art: blocks and simple figures)

  private func tree(
    _ s: inout StageMinecraftScene, x: Double, top: Double, bs: Double, palette: Palette,
    seed: UInt64, c: Int
  ) {
    let trunk = 3 + Int(unit(seed, 721, c) * 2)
    for j in 0..<trunk {
      s.voxels.append(
        StageVoxel(
          x: x, y: top - Double(j + 1) * bs, w: bs, h: bs, color: palette.wood, style: .block)
      )
    }
    let crown = top - Double(trunk) * bs
    for dy in 0..<3 {
      let half = dy == 0 ? 0 : 1
      for dx in -half...half {
        s.voxels.append(
          StageVoxel(
            x: x + Double(dx) * bs, y: crown - Double(dy + 1) * bs + bs * 0.5, w: bs, h: bs,
            color: palette.leaf, style: .block))
      }
    }
  }

  private func cloud(
    _ s: inout StageMinecraftScene, x: Double, y: Double, bs: Double, alpha: Double, seed: UInt64,
    j: Int
  ) {
    let len = 4 + Int(unit(seed, 320, j) * 3)
    let col = ScopeColor(r: 1, g: 1, b: 1, a: alpha)
    s.voxels.append(
      StageVoxel(x: x, y: y, w: Double(len) * bs, h: bs * 0.8, color: col, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x + bs, y: y - bs * 0.6, w: Double(len - 2) * bs, h: bs * 0.7, color: col, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x, y: y + bs * 0.6, w: Double(len) * bs, h: bs * 0.2,
        color: ScopeColor(r: 0.85, g: 0.88, b: 0.95, a: alpha), style: .flat))
  }

  private func critter(
    _ s: inout StageMinecraftScene, x: Double, foot: Double, bs: Double, scale: Double,
    seed: UInt64, i: Int, palette: Palette
  ) {
    let size = bs * 1.8 * scale
    guard size > 1 else { return }
    let hue = 160 + unit(seed, 200, i) * 140  // teal to violet
    let body = palette.lit(ScopeColor.hsla(hue, 55, 50, 1))
    let x0 = x - size / 2
    let y0 = foot - size
    s.voxels.append(StageVoxel(x: x0, y: y0, w: size, h: size, color: body, style: .block))
    // a lighter belly and two eyes with pupils
    let u = size / 6
    s.voxels.append(
      StageVoxel(
        x: x0 + u, y: y0 + u * 3.6, w: u * 4, h: u * 1.4, color: body.scaled(1.25), style: .flat))
    for e in [1.0, 3.6] {
      s.voxels.append(
        StageVoxel(
          x: x0 + u * e, y: y0 + u * 1.2, w: u * 1.4, h: u * 1.4,
          color: ScopeColor(r: 1, g: 1, b: 1), style: .flat))
      s.voxels.append(
        StageVoxel(
          x: x0 + u * (e + 0.6), y: y0 + u * 1.6, w: u * 0.8, h: u * 1.0,
          color: ScopeColor(r: 0.08, g: 0.08, b: 0.12), style: .flat))
    }
  }

  private func walker(
    _ s: inout StageMinecraftScene, x: Double, foot: Double, bs: Double, alpha: Double,
    step: Double, seed: UInt64, i: Int, palette: Palette
  ) {
    let u = bs / 4
    // a drummer in a warm tunic and a pointed cap (warm hues only: an original figure, not any
    // game's default character)
    let warm = unit(seed, 210, i) * 70 - 20  // red through orange to gold
    let shirt = palette.lit(ScopeColor.hsla(warm, 65, 48, alpha))
    let cap = palette.lit(ScopeColor.hsla(warm + 180, 45, 35, alpha))
    let pants = palette.lit(ScopeColor.hsla(30, 35, 26, alpha))
    let tone = unit(seed, 211, i)
    let skin = palette.lit(
      ScopeColor(r: 0.95 - 0.35 * tone, g: 0.78 - 0.36 * tone, b: 0.62 - 0.32 * tone, a: alpha))
    let swing = Int(step) % 2 == 0 ? u * 0.6 : -u * 0.6
    let x0 = x - u * 2
    // legs
    s.voxels.append(
      StageVoxel(
        x: x0 + swing * 0.5, y: foot - u * 3, w: u * 1.8, h: u * 3, color: pants, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 2.2 - swing * 0.5, y: foot - u * 3, w: u * 1.8, h: u * 3,
        color: pants.scaled(0.85), style: .flat))
    // body, arms
    s.voxels.append(
      StageVoxel(x: x0, y: foot - u * 7, w: u * 4, h: u * 4, color: shirt, style: .block))
    s.voxels.append(
      StageVoxel(
        x: x0 - u, y: foot - u * 7 + swing * 0.3, w: u, h: u * 3.5, color: skin.scaled(0.92),
        style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 4, y: foot - u * 7 - swing * 0.3, w: u, h: u * 3.5, color: skin.scaled(0.92),
        style: .flat))
    // head, hair, eyes
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 0.2, y: foot - u * 10.6, w: u * 3.6, h: u * 3.6, color: skin, style: .block))
    // the cap: a brim and a stepped point
    s.voxels.append(
      StageVoxel(
        x: x0 - u * 0.3, y: foot - u * 11.1, w: u * 4.6, h: u * 0.9, color: cap, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 0.6, y: foot - u * 12.2, w: u * 2.8, h: u * 1.2, color: cap, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 1.5, y: foot - u * 13.0, w: u * 1.2, h: u * 0.9, color: cap.scaled(1.2),
        style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 0.9, y: foot - u * 9.2, w: u * 0.6, h: u * 0.6,
        color: ScopeColor(r: 0.1, g: 0.1, b: 0.2, a: alpha), style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x0 + u * 2.5, y: foot - u * 9.2, w: u * 0.6, h: u * 0.6,
        color: ScopeColor(r: 0.1, g: 0.1, b: 0.2, a: alpha), style: .flat))
  }

  private func bird(
    _ s: inout StageMinecraftScene, x: Double, y: Double, bs: Double, alpha: Double, up: Bool,
    palette: Palette, seed: UInt64, i: Int
  ) {
    let u = bs / 4
    let col = palette.lit(ScopeColor.hsla(unit(seed, 220, i) * 60, 15, 20, alpha))
    let wingY = up ? y - u * 1.2 : y + u * 0.4
    s.voxels.append(StageVoxel(x: x - u, y: y - u * 0.5, w: u * 2, h: u, color: col, style: .flat))
    s.voxels.append(
      StageVoxel(x: x - u * 2.6, y: wingY, w: u * 1.8, h: u * 0.8, color: col, style: .flat))
    s.voxels.append(
      StageVoxel(x: x + u * 0.8, y: wingY, w: u * 1.8, h: u * 0.8, color: col, style: .flat))
    s.voxels.append(
      StageVoxel(
        x: x + u, y: y - u * 0.3, w: u * 0.6, h: u * 0.4,
        color: ScopeColor(r: 1, g: 0.7, b: 0.2, a: alpha), style: .flat))
  }
}

// MARK: - colours, terrain, hashing

private struct Palette {
  let grass: ScopeColor
  let dirt: ScopeColor
  let stone: ScopeColor
  let mossyStone: ScopeColor
  let ore: ScopeColor
  let wood: ScopeColor
  let leaf: ScopeColor
  let light: Double
  let tint: ScopeColor

  init(biome: StageBiome, prev: StageBiome, fade: Double, light: Double, tint: ScopeColor) {
    self.light = light
    self.tint = tint
    func grassOf(_ b: StageBiome) -> ScopeColor {
      switch b {
      case .plains: rgb(124, 196, 82)
      case .forest: rgb(86, 160, 60)
      case .dusk: rgb(96, 150, 66)
      case .night: rgb(70, 130, 64)
      case .cave: rgb(90, 120, 80)
      case .sunset: rgb(140, 170, 70)
      }
    }
    func leafOf(_ b: StageBiome) -> ScopeColor {
      switch b {
      case .sunset: rgb(170, 120, 40)
      case .plains: rgb(90, 170, 70)
      default: rgb(50, 120, 44)
      }
    }
    let lit = { (c: ScopeColor) in Palette.apply(c, light: light, tint: tint) }
    grass = lit(blend(grassOf(prev), grassOf(biome), fade))
    dirt = lit(rgb(134, 96, 67))
    stone = lit(rgb(122, 122, 128))
    mossyStone = lit(rgb(98, 118, 96))
    ore = lit(rgb(200, 170, 70))
    wood = lit(rgb(110, 80, 48))
    leaf = lit(blend(leafOf(prev), leafOf(biome), fade))
  }

  func lit(_ c: ScopeColor) -> ScopeColor { Palette.apply(c, light: light, tint: tint) }

  static func apply(_ c: ScopeColor, light: Double, tint: ScopeColor) -> ScopeColor {
    ScopeColor(
      r: min(1, c.r * light * tint.r), g: min(1, c.g * light * tint.g),
      b: min(1, c.b * light * tint.b), a: c.a)
  }
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> ScopeColor { ScopeColor(r8: r, g8: g, b8: b) }

func smooth(_ x: Double) -> Double {
  let t = min(1, max(0, x))
  return t * t * (3 - 2 * t)
}

/// Straight blend of two colours, exactly `a` at 0 and `b` at 1.
private func blend(_ a: ScopeColor, _ b: ScopeColor, _ f: Double) -> ScopeColor {
  if f <= 0 { return a }
  if f >= 1 { return b }
  return ScopeColor.lerp(a, b, f)
}

private func mixd(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

extension ScopeColor {
  /// The colour with its RGB multiplied by `f` (clamped), alpha kept.
  func scaled(_ f: Double) -> ScopeColor {
    ScopeColor(r: min(1, r * f), g: min(1, g * f), b: min(1, b * f), a: a)
  }
}

/// SplitMix64 of (seed, a, b): the world's only source of variety.
func stageHash(_ seed: UInt64, _ a: Int, _ b: Int) -> UInt64 {
  var z = seed &+ UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
  z = z &+ UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
  z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
  z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
  return z ^ (z >> 31)
}

/// 0..<1 from (seed, a, b).
func unit(_ seed: UInt64, _ a: Int, _ b: Int) -> Double {
  Double(stageHash(seed, a, b) >> 11) / Double(1 << 53)
}

/// The surface height of column `c`, in blocks above the base (0...5): two octaves of value noise.
private func terrainHeight(_ c: Int, seed: UInt64) -> Int {
  func noise(_ x: Double, _ octave: Int) -> Double {
    let i = Int(x.rounded(.down))
    let f = x - Double(i)
    let a = unit(seed, 50 + octave, i)
    let b = unit(seed, 50 + octave, i + 1)
    let u = f * f * (3 - 2 * f)
    return a + (b - a) * u
  }
  let v = 0.7 * noise(Double(c) / 7, 0) + 0.3 * noise(Double(c) / 2.5, 1)
  return Int((v * 5.5).rounded(.down))
}
