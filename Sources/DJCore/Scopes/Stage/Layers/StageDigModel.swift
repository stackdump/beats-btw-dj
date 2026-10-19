import Foundation

// StageDigModel: the "Dig" solo visualizer. A side-on tunnel, two blocks high, and a miner with
// a pickaxe at its face, digging for beats. The dig is the song's clock and its control track
// (`StageControlTimeline`):
//
//   mining         one block every two bars (`stepsPerBlock` = 32 steps): the block at head
//                  height, then the one at the feet, then the miner steps into the new column (so
//                  a stride is four bars, a phrase). The pickaxe strikes on every beat; the block
//                  cracks through ten stages over its two bars and breaks on the bar line, in a
//                  burst of its own pieces. Block `k` is mined over steps `32k ..< 32(k + 1)`: a
//                  pure function of the step, so a seek or a replay digs the same tunnel.
//   ores           what a block holds is what the music does the moment it breaks: the block that
//                  breaks on a drop is diamond (a white flash and sparkles), on any other section
//                  start gold, inside a fill redstone; otherwise stone, now and then coal or iron.
//                  The face shows its ore from the start, so a diamond is seen coming.
//   strata         the seam around the tunnel (two blocks above and below it) is the rock of the
//                  section that plays while its column is dug (stone, granite in a buildup,
//                  deepslate in a drop, andesite in a breakdown), so the walls behind the miner
//                  are a record of the song; deeper rock is stone.
//   torches        one on the back wall every `torchEvery` columns; they flicker while the hats
//                  play, and light the rock around them (the rest of the tunnel is dark).
//   rests          through a drop gap or a kick out the pickaxe is held up, ready, not swung.
//   hotbar         the ores mined so far, counted, top right (clear of the stage's status line).
//
// Deterministic: rock specks, ores off the timeline and debris come from the song's
// `StageControlTimeline.seed`; time from the feed's clock (steps), never the system clock. With
// no timeline (a loop) it digs on the clock alone. At visual level 2 and up the debris count drops.
//
// Allocation: the scene is written into one of two reused buffers (the view may still hold the
// other), as `StageMinecraftModel` does; the block table is built once per track.

/// What a mined block held.
public enum StageOre: Int, CaseIterable, Sendable {
  case stone, coal, iron, redstone, gold, diamond

  /// The colour of its specks (stone has none).
  public var color: ScopeColor {
    switch self {
    case .stone: rgb(128, 128, 128)
    case .coal: rgb(30, 30, 34)
    case .iron: rgb(222, 176, 140)
    case .redstone: rgb(232, 36, 28)
    case .gold: rgb(252, 214, 60)
    case .diamond: rgb(96, 236, 226)
    }
  }

  /// Hotbar slots, left to right (stone is not kept).
  public static let kept: [StageOre] = [.coal, .iron, .redstone, .gold, .diamond]
}

/// The rock a column is cut through.
public enum StageRock: Int, Sendable {
  case stone, granite, deepslate, andesite

  public static func of(section name: String) -> StageRock {
    switch StageBiome.of(section: name) {
    case .dusk: .granite
    case .night: .deepslate
    case .cave: .andesite
    case .plains, .forest, .sunset: .stone
    }
  }

  public var color: ScopeColor {
    switch self {
    case .stone: rgb(126, 126, 126)
    case .granite: rgb(150, 106, 88)
    case .deepslate: rgb(72, 72, 82)
    case .andesite: rgb(112, 118, 112)
    }
  }
}

/// Everything the layer draws for one frame.
public struct StageDigScene: Equatable, Sendable {
  public var width = 0.0
  public var height = 0.0
  /// The song step the scene shows.
  public var step = 0.0
  /// Block size, points.
  public var block = 0.0
  /// Blocks mined so far (`floor(step / stepsPerBlock)`).
  public var mined = 0
  /// The column being dug and whether the block at head height (else at the feet) is next.
  public var faceColumn = 0
  public var headNext = true
  /// What the block being dug holds.
  public var faceOre = StageOre.stone
  /// 0...9: its crack stage.
  public var crack = 0
  /// The pickaxe's angle above the strike, radians (0 = hitting the face).
  public var swing = 0.0
  /// Held up through a rest (no swing).
  public var holding = false
  /// 0...1: a white wash over everything (a diamond's break).
  public var flash = 0.0
  /// Ores mined so far, in `StageOre.kept` order.
  public var inventory: [Int] = Array(repeating: 0, count: StageOre.kept.count)
  /// The hotbar's slots, in `StageOre.kept` order (for the counts).
  public var slots: [StageRect] = []
  /// Back to front.
  public var voxels: [StageVoxel] = []

  public init() {}
}

/// An axis-aligned rectangle in stage coordinates.
public struct StageRect: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double

  public init(x: Double, y: Double, w: Double, h: Double) {
    self.x = x
    self.y = y
    self.w = w
    self.h = h
  }
}

@MainActor
public final class StageDigModel: StageLayerModel {
  /// Steps a block takes to mine: two bars of sixteenths.
  public static let stepsPerBlock = 32
  /// Crack stages a block goes through.
  public static let crackStages = 10
  /// Steps the miner takes to step into the next column.
  public static let strideSteps = 4.0
  /// A torch on the back wall every this many columns.
  public static let torchEvery = 6
  /// How long a block's pieces fly, seconds.
  public static let debrisLife = 0.9
  public static let debrisCount = 16
  public static let debrisCountMinimal = 6

  /// The control schedule of the song showing (empty for a loop or no net).
  public private(set) var timeline = StageControlTimeline.empty
  /// What each block of the song holds and the rock of each column (built per track).
  public private(set) var ores: [StageOre] = []
  public private(set) var rocks: [StageRock] = []

  private var scenes = [StageDigScene(), StageDigScene()]
  private var current = 0
  private var builtSerial: Int32?
  private var builtHasProject = false

  public init() {
    for i in scenes.indices {
      scenes[i].voxels.reserveCapacity(1600)
      scenes[i].slots.reserveCapacity(StageOre.kept.count)
    }
  }

  /// The last frame's scene.
  public var scene: StageDigScene { scenes[current] }

  public func reset() {}

  // MARK: per frame

  public func advance(_ ctx: StageContext) {
    guard ctx.visualizer == .dig else { return }
    guard let feed = ctx.feed else {
      advance(ctx, timeline: timeline, step: scene.step, tickSec: 0.125)
      return
    }
    let hasProject = feed.leadProject != nil
    if builtSerial != feed.trackSerial || builtHasProject != hasProject {
      builtSerial = feed.trackSerial
      builtHasProject = hasProject
      setTimeline(feed.leadProject.map { StageControlTimeline.build($0) } ?? .empty)
    }
    let c = feed.clock
    advance(ctx, timeline: timeline, step: max(0, Double(c.tick - 1) + c.tickPhase), tickSec: c.tickSec)
  }

  /// Install a schedule (tests, or a track change) and work out its blocks.
  public func setTimeline(_ t: StageControlTimeline) {
    timeline = t
    let n = (t.totalSteps + Self.stepsPerBlock - 1) / Self.stepsPerBlock
    ores = (0..<n).map { Self.ore(block: $0, timeline: t) }
    rocks = (0..<(n + 1) / 2).map { col in
      let k = t.sectionIndex(at: Double(col * 2 * Self.stepsPerBlock))
      return k.map { StageRock.of(section: t.sections[$0].name) } ?? .stone
    }
  }

  /// What block `k` holds: what the timeline does at the step it breaks on, else the seed's pick.
  static func ore(block k: Int, timeline t: StageControlTimeline) -> StageOre {
    let start = k * stepsPerBlock
    let breaks = start + stepsPerBlock
    for e in t.events(from: breaks, to: breaks + 1) {
      if e.kind == .drop && e.tick == breaks { return .diamond }
    }
    for e in t.events(from: breaks, to: breaks + 1) {
      if e.kind == .section && e.tick == breaks { return .gold }
    }
    for f in 0..<t.count(.fill) {
      let e = t.event(.fill, f)
      if e.tick < breaks && e.end > start { return .redstone }
    }
    return randomOre(block: k, seed: t.seed)
  }

  static func randomOre(block k: Int, seed: UInt64) -> StageOre {
    let r = unit(seed, 700, k)
    return r < 0.12 ? .coal : r < 0.18 ? .iron : .stone
  }

  func ore(block k: Int) -> StageOre {
    k >= 0 && k < ores.count ? ores[k] : Self.randomOre(block: k, seed: timeline.seed)
  }

  func rock(column c: Int) -> StageRock {
    guard !rocks.isEmpty else { return .stone }
    return rocks[min(max(0, c), rocks.count - 1)]
  }

  /// One frame at song step `step` (`ScopeClock`: `tick - 1 + tickPhase`), `tickSec` seconds a
  /// step.
  public func advance(
    _ ctx: StageContext, timeline t: StageControlTimeline, step: Double, tickSec: Double
  ) {
    if t != timeline { setTimeline(t) }
    current = 1 - current
    var s = scenes[current]
    scenes[current] = StageDigScene()  // drop the buffer's other reference
    compose(&s, ctx: ctx, step: max(0, step), tickSec: max(1e-3, tickSec))
    scenes[current] = s
  }

  // MARK: composition

  private func compose(_ s: inout StageDigScene, ctx: StageContext, step: Double, tickSec: Double) {
    let t = timeline
    let seed = t.seed
    let w = ctx.width
    let h = ctx.height
    s.voxels.removeAll(keepingCapacity: true)
    s.slots.removeAll(keepingCapacity: true)
    s.width = w
    s.height = h
    s.step = step
    s.flash = 0
    let bs = max(12, (h / 12).rounded())
    s.block = bs

    // Where the dig is.
    let per = Double(Self.stepsPerBlock)
    let k = Int((step / per).rounded(.down))
    let into = step - Double(k) * per
    let col = k / 2
    let head = k % 2 == 0
    s.mined = k
    s.faceColumn = col
    s.headNext = head
    s.faceOre = ore(block: k)
    s.crack = min(Self.crackStages - 1, Int(into / per * Double(Self.crackStages)))

    // The camera: the miner stands in the column before the face, and steps forward over the
    // first `strideSteps` after the feet block of a column breaks.
    let stride = head && k > 0 ? smooth(into / Self.strideSteps) : 1
    let minerCol = Double(col - 1) - (1 - stride)
    let minerX = w * 0.42
    let cam = minerCol * bs - minerX
    let floorY = ((h * 0.66) / bs).rounded() * bs
    let headY = floorY - 2 * bs

    // The pickaxe: up over the beat, down on it; held up through a rest.
    let rest = t.covering(.dropGap, at: step) != nil || t.covering(.kickOut, at: step) != nil
    s.holding = rest
    let beat = step.truncatingRemainder(dividingBy: 4) / 4
    let walking = stride < 1
    if rest || walking {
      s.swing = 1.25
    } else if beat < 0.12 {
      s.swing = 0.12 * sin(beat / 0.12 * Double.pi)  // the knock back off the rock
    } else {
      s.swing = 1.25 * smooth((beat - 0.12) / 0.7)
    }

    // Light: torches on the back wall, and the miner's own glow.
    let hats = hatsPlaying(ctx: ctx, step: step)
    let firstCol = Int((cam / bs).rounded(.down)) - 1
    let cols = Int((w / bs).rounded(.up)) + 3
    func torchAt(_ c: Int) -> Bool { c >= 0 && c < col && c % Self.torchEvery == 2 }
    func light(_ x: Double, _ y: Double) -> Double {
      var l = 0.16
      let dm = hypot(x - minerX, y - (floorY - bs)) / bs
      l = max(l, 0.85 - dm * 0.16)
      var c = firstCol
      while c < firstCol + cols {
        if torchAt(c) {
          let tx = Double(c) * bs - cam + bs / 2
          let flicker = hats ? 0.9 + 0.1 * sin(ctx.now * 23 + Double(c) * 1.3) : 1
          let d = hypot(x - tx, y - (headY + bs * 0.4)) / bs
          l = max(l, (1.05 - d * 0.17) * flicker)
        }
        c += 1
      }
      return min(1, l)
    }

    // The rock, the tunnel's back wall, and the face.
    let rows = Int((h / bs).rounded(.up)) + 1
    let faceRow = head ? 0 : 1
    for i in 0..<cols {
      let c = firstCol + i
      let x = Double(c) * bs - cam
      let seam = rock(column: c).color
      for row in 0..<rows {
        let y = Double(row) * bs
        let r = Int(((y - headY) / bs).rounded())
        let inTunnel = r == 0 || r == 1
        let air = inTunnel && (c < col || (c == col && r == 0 && !head))
        let lit = light(x + bs / 2, y + bs / 2)
        let rk = r >= -2 && r <= 3 ? seam : StageRock.stone.color
        if air {
          // the back wall: dark, flat, so the tunnel reads as open
          s.voxels.append(
            StageVoxel(x: x, y: y, w: bs, h: bs, color: rk.scaled(0.2 * lit), style: .flat))
          continue
        }
        var base = rk
        if unit(seed, 710, c &* 977 &+ row) < 0.08 { base = base.scaled(0.86) }
        s.voxels.append(StageVoxel(x: x, y: y, w: bs, h: bs, color: base.scaled(lit), style: .block))
        // ore in the walls, and the face's ore
        let isFace = c == col && r == faceRow
        let wallOre = !isFace && unit(seed, 720, c &* 131 &+ row) < 0.05
        let o: StageOre? = isFace ? s.faceOre : wallOre ? (unit(seed, 721, c &+ row) < 0.6 ? .coal : .iron) : nil
        if let o, o != .stone { specks(&s, x: x, y: y, bs: bs, ore: o, lit: lit, salt: c &* 31 &+ row) }
      }
    }

    // Cracks on the face.
    let fx = Double(col) * bs - cam
    let fy = headY + Double(faceRow) * bs
    if s.crack > 0 {
      let px = bs / 8
      for j in 0..<(s.crack * 3) {
        let gx = Double(Int(unit(seed, 730 + k, j) * 8))
        let gy = Double(Int(unit(seed, 731 + k, j) * 8))
        s.voxels.append(
          StageVoxel(
            x: fx + gx * px, y: fy + gy * px, w: px, h: px, color: rgb(20, 20, 22).withAlpha(0.85),
            style: .flat))
      }
    }

    // Torches.
    for i in 0..<cols where torchAt(firstCol + i) {
      let tx = Double(firstCol + i) * bs - cam + bs * 0.44
      let ty = headY + bs * 0.35
      s.voxels.append(
        StageVoxel(x: tx, y: ty, w: bs * 0.12, h: bs * 0.45, color: rgb(120, 84, 48), style: .flat))
      let flicker = hats ? 0.75 + 0.25 * sin(ctx.now * 23 + Double(firstCol + i) * 1.3) : 0.9
      let g = bs * (0.9 + 0.25 * flicker)
      s.voxels.append(
        StageVoxel(
          x: tx + bs * 0.06 - g / 2, y: ty - g / 2, w: g, h: g,
          color: rgb(255, 190, 90).withAlpha(0.8 * flicker), style: .glow))
    }

    miner(&s, x: minerX, floor: floorY, bs: bs, walk: walking ? into : 0, aimHead: head)

    // The last block's pieces.
    if k > 0 {
      let age = into * tickSec
      if age < Self.debrisLife {
        let broken = ore(block: k - 1)
        let bcol = (k - 1) / 2
        let brow = (k - 1) % 2
        let bx = Double(bcol) * bs - cam + bs / 2
        let by = headY + Double(brow) * bs + bs / 2
        let n = ctx.vizLevel >= 2 ? Self.debrisCountMinimal : Self.debrisCount
        let rk = rock(column: bcol).color
        for j in 0..<n {
          let a = Double.pi * (0.55 + 0.9 * unit(seed, 740 + k, j))
          let v = bs * (3 + 5 * unit(seed, 741 + k, j))
          let x = bx + cos(a) * v * age
          let y = by - sin(a) * v * age + 22 * bs * age * age
          let size = bs * (0.14 + 0.1 * unit(seed, 742 + k, j))
          let ofOre = broken != .stone && j % 3 == 0
          let fade = 1 - age / Self.debrisLife
          s.voxels.append(
            StageVoxel(
              x: x - size / 2, y: y - size / 2, w: size, h: size,
              color: (ofOre ? broken.color : rk).withAlpha(fade), style: .block))
        }
        if broken == .diamond {
          s.flash = 0.55 * exp(-age * 6)
          for j in 0..<8 {
            let a = Double(j) / 8 * 2 * Double.pi + age * 3
            let r = bs * (0.6 + 2.4 * age)
            let g = bs * 0.5 * (1 - age / Self.debrisLife)
            s.voxels.append(
              StageVoxel(
                x: bx + cos(a) * r - g / 2, y: by + sin(a) * r - g / 2, w: g, h: g,
                color: StageOre.diamond.color.withAlpha(0.9), style: .glow))
          }
        }
      }
    }

    // The hotbar.
    for i in s.inventory.indices { s.inventory[i] = 0 }
    for b in 0..<k {
      if let i = StageOre.kept.firstIndex(of: ore(block: b)) { s.inventory[i] += 1 }
    }
    let slot = (bs * 0.8).rounded()
    let barW = slot * Double(StageOre.kept.count) + 4
    let bx0 = (w - barW - 16).rounded()
    let by0 = 16.0
    s.voxels.append(
      StageVoxel(x: bx0 - 2, y: by0 - 2, w: barW + 4, h: slot + 4, color: rgb(16, 16, 18).withAlpha(0.85), style: .flat))
    for (i, o) in StageOre.kept.enumerated() {
      let x = bx0 + 2 + Double(i) * slot
      s.slots.append(StageRect(x: x, y: by0, w: slot, h: slot))
      s.voxels.append(
        StageVoxel(x: x + 1, y: by0 + 1, w: slot - 2, h: slot - 2, color: rgb(78, 78, 84), style: .flat))
      let has = s.inventory[i] > 0
      let g = slot * 0.5
      s.voxels.append(
        StageVoxel(
          x: x + (slot - g) / 2, y: by0 + (slot - g) / 2, w: g, h: g,
          color: o.color.withAlpha(has ? 1 : 0.22), style: .block))
    }
  }

  /// Four ore specks on a block, placed by `salt` (so an ore looks the same frame to frame).
  private func specks(
    _ s: inout StageDigScene, x: Double, y: Double, bs: Double, ore: StageOre, lit: Double,
    salt: Int
  ) {
    let px = bs / 6
    let glow = ore == .diamond || ore == .redstone || ore == .gold
    for j in 0..<4 {
      let gx = 0.5 + Double(Int(unit(timeline.seed, 750, salt &* 7 &+ j) * 4))
      let gy = 0.5 + Double(Int(unit(timeline.seed, 751, salt &* 7 &+ j) * 4))
      s.voxels.append(
        StageVoxel(
          x: x + gx * px, y: y + gy * px, w: px * 1.3, h: px * 1.3,
          color: ore.color.scaled(glow ? max(lit, 0.75) : lit), style: .flat))
    }
  }

  /// The miner: a pixel figure facing right, its pickaxe at `swing`.
  private func miner(
    _ s: inout StageDigScene, x: Double, floor: Double, bs: Double, walk: Double, aimHead: Bool
  ) {
    let p = bs / 8
    let bob = walk > 0 ? -abs(sin(walk / Self.strideSteps * Double.pi * 2)) * p : 0
    func px(_ gx: Double, _ gy: Double, _ gw: Double, _ gh: Double, _ c: ScopeColor) {
      s.voxels.append(
        StageVoxel(
          x: x + gx * p, y: floor - 16 * p + gy * p + bob, w: gw * p, h: gh * p, color: c,
          style: .flat))
    }
    let skin = rgb(214, 160, 120)
    let shirt = rgb(48, 160, 170)
    let pants = rgb(60, 56, 140)
    let boots = rgb(70, 70, 74)
    px(2, 0, 4, 1, rgb(232, 196, 40))  // helmet
    px(2, 1, 4, 3, skin)
    px(5, 2, 1, 1, rgb(30, 30, 40))  // eye
    px(2, 4, 4, 5, shirt)
    px(2, 9, 4, 4, pants)
    let step = walk > 0 ? (Int(walk) % 2 == 0 ? 1.0 : -1.0) : 0
    px(2 + step * 0.5, 13, 2, 3, boots)
    px(4 - step * 0.5, 13, 2, 3, boots)
    // the lamp on the helmet
    s.voxels.append(
      StageVoxel(
        x: x + 5 * p, y: floor - 16 * p + bob - p, w: 3 * p, h: 3 * p,
        color: rgb(255, 236, 170).withAlpha(0.6), style: .glow))

    // Arm and pickaxe from the shoulder; at swing 0 the head meets the face block.
    let sx = x + 5 * p
    let sy = floor - 11 * p + bob
    let aim = aimHead ? -0.55 : 0.35  // radians below the horizontal to the target
    let a = aim - s.swing
    let ca = cos(a)
    let sa = sin(a)
    for j in 0..<10 {
      let d = Double(j) * p
      px((sx + ca * d - x) / p, (sy + sa * d - (floor - 16 * p + bob)) / p, 1, 1,
        j < 3 ? skin : rgb(124, 86, 50))
    }
    // the head: a bar across the handle's end
    let hx = sx + ca * 10 * p
    let hy = sy + sa * 10 * p
    for j in -3...3 {
      let d = Double(j) * p
      s.voxels.append(
        StageVoxel(
          x: hx - sa * d - p / 2, y: hy + ca * d - p / 2 + 0 * bob, w: p * 1.1, h: p * 1.1,
          color: rgb(100, 220, 214), style: .flat))
    }
  }

  private func hatsPlaying(ctx: StageContext, step: Double) -> Bool {
    var seen = false
    for p in ctx.panels where StageMinecraftModel.role(of: p).lowercased().contains("hat") {
      seen = true
      if !p.muted { return true }
    }
    if seen { return false }
    for r in timeline.roles where r.lowercased().contains("hat") {
      if timeline.isActive(role: r, at: step) { return true }
    }
    return false
  }
}
