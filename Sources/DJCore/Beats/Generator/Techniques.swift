import Foundation

// dj-only composition techniques: opt-in `compose` overrides that beats does not have
// (COMPOSE-OPTIONS.md). Every one is off unless its key is in the overrides, and with none
// of them `compose` takes exactly the beats path (the parity fixtures run that path).
// They never draw from compose's own rng: switching one on changes only what it is about.

/// `chordSnap`: which melody notes are moved onto the sounding chord.
enum ChordSnap: String {
  case off, strong, all

  /// strong = beats 1 and 3 of each bar; all = every beat. (16th-note steps.)
  func applies(at step: Int) -> Bool {
    switch self {
    case .off: false
    case .strong: step % 8 == 0
    case .all: step % 4 == 0
    }
  }
}

/// The techniques an overrides object asks for.
struct ComposeTechniques {
  var hook = false
  var hookBars = 2
  var chordSnap = ChordSnap.off
  var chordSnapArp = false
  /// nil = off; 0 = auto (per section name); n = at most n melodic roles everywhere.
  var layerBudget: Int?
  var bassFollow = false
  var keyLock = false
  /// `melodyDensity` when it was given (it also thins motif cells, which ignore density).
  var melodyDensity: Double?

  init(_ ov: JSONValue) {
    hook = ov["hook"]?.bool ?? false
    if let b = ov["hookBars"]?.double, b == 1 || b == 2 { hookBars = Int(b) }
    if let s = ov["chordSnap"]?.string { chordSnap = ChordSnap(rawValue: s) ?? .off }
    chordSnapArp = ov["chordSnapArp"]?.bool ?? false
    switch ov["layerBudget"] {
    case .string("auto")?: layerBudget = 0
    case let v?: if let n = v.double, n >= 1 { layerBudget = Int(n) }
    default: break
    }
    bassFollow = ov["bassFollow"]?.bool ?? false
    keyLock = ov["keyLock"]?.bool ?? false
    melodyDensity = ov["melodyDensity"]?.double
  }

  /// Whether any technique acts while slots are composed (they share one context, whose
  /// chord plan is built as cohesion v2 would when it is off).
  var needsContext: Bool { hook || chordSnap != .off || bassFollow || keyLock }
}

/// What `expandVariants` needs to apply the techniques to a slot.
struct TechniqueContext {
  var t: ComposeTechniques
  var plan: ChordPlan
  var hook: HookCell?
  /// The key's scale an octave up (the melody's), for hooks and snapping.
  var melodyScale: [Int]
  var bassScale: [Int]
  /// The key's pitch classes per chord of `plan`.
  var chordPCs: [[Int]]
  /// `bassFollow`'s one seed for every bass slot.
  var bassSeed: Double
}

func techniqueContext(
  _ t: ComposeTechniques, genre: GenreDef, genreName: String, seed: Double, theme: TrackTheme?
) -> TechniqueContext? {
  guard t.needsContext else { return nil }
  let plan = theme?.plan ?? buildTrackTheme(genre: genreName, seed: seed).plan
  let key = genre.scale(genre.rootNote)
  var bassScale = key
  if bassScale.count > majorIntervals.count {
    bassScale = Array(bassScale[0..<majorIntervals.count])
  }
  let density = t.melodyDensity ?? genre.melodyDensity
  return TechniqueContext(
    t: t, plan: plan,
    hook: t.hook
      ? buildHook(genre: genreName, seed: seed, bars: t.hookBars, density: density) : nil,
    melodyScale: genre.scale(genre.rootNote + 12), bassScale: bassScale,
    chordPCs: plan.chords.map { c in
      c.tones.map { ((degreeToMidi(clampDegree($0), key) % 12) + 12) % 12 }
    },
    bassSeed: Double(UInt32(bitPattern: jsToInt32(seed)) ^ hashStr("bass-follow/" + genreName)))
}

// MARK: - hook

/// A 1–2 bar hook: a rhythm and a contour of chord-tone targets (scale degrees above the
/// melody root, measured on the tonic chord). Each bar of it is played against the chord
/// sounding there, every target moved to that chord's nearest tone — so the shape stays and
/// every note is a chord tone.
struct HookCell: Equatable {
  var mask: [Bool]
  /// Scale-degree target per step (-1 = rest).
  var target: [Int]
  var length: Int { mask.count }
}

/// Section → how the hook is varied there (the motif modes; Play where nothing is set).
let hookModes: [String: Int] = [
  "intro": MotifMode.fragment, "verse": MotifMode.play, "pre-chorus": MotifMode.fragment,
  "buildup": MotifMode.transposed, "drop": MotifMode.play, "chorus": MotifMode.play,
  "breakdown": MotifMode.fragment, "bridge": MotifMode.inverted, "solo": MotifMode.augmented,
  "outro": MotifMode.fragment,
]

/// Pure function of genre + seed + bars + density; its own rng (never compose's).
func buildHook(genre: String, seed: Double, bars: Int, density: Double) -> HookCell {
  let u = UInt32(bitPattern: jsToInt32(seed))
  var rng = Mulberry32(seed: Int(Int32(bitPattern: u ^ hashStr("hook/" + genre))))
  let bars = bars == 1 ? 1 : 2
  let len = 16 * bars
  // Rhythm: the downbeat, then onsets drawn from a pop/EDM-weighted pool.
  let hits = min(7, max(3, Int((density * 8).rounded())))
  func rhythm(_ fixed: [Int]) -> [Int] {
    var pool: [(step: Int, w: Int)] = [
      (3, 4), (6, 4), (8, 3), (10, 3), (12, 3), (14, 2), (4, 2), (2, 1), (11, 1), (7, 1),
    ]
    var on = fixed
    pool.removeAll { on.contains($0.step) }
    while on.count < hits && !pool.isEmpty {
      var r = rng.nextInt(pool.reduce(0) { $0 + $1.w })
      var k = 0
      while r >= pool[k].w {
        r -= pool[k].w
        k += 1
      }
      on.append(pool.remove(at: k).step)
    }
    return on.sorted()
  }
  let first = rhythm([0])
  // Contour: chord-tone index walk (0 root, 1 third, 2 fifth, 3 octave, 4 tenth).
  let degreeOf = [0, 2, 4, 7, 9]
  let moves = [-1, 1, 1, -1, 0, 2, -2]
  func walk(_ n: Int, from: Int) -> [Int] {
    var idx = from
    var out: [Int] = []
    for _ in 0..<n {
      out.append(idx)
      idx = min(4, max(0, idx + moves[rng.nextInt(moves.count)]))
    }
    return out
  }
  var mask = [Bool](repeating: false, count: len)
  var target = [Int](repeating: -1, count: len)
  let start = rng.nextInt(3)
  let a = walk(first.count, from: start)
  for (k, s) in first.enumerated() {
    mask[s] = true
    target[s] = degreeOf[a[k]]
  }
  if bars == 2 {
    // Answer: the first half of the call again, a new second half that comes home.
    let keep = first.filter { $0 < 8 }
    let tail = rhythm(keep).filter { $0 >= 8 }
    var b = walk(tail.count, from: a[min(keep.count, a.count - 1)])
    if !b.isEmpty { b[b.count - 1] = 0 }
    for (k, s) in keep.enumerated() {
      mask[16 + s] = true
      target[16 + s] = degreeOf[a[k]]
    }
    for (k, s) in tail.enumerated() {
      mask[16 + s] = true
      target[16 + s] = degreeOf[b[k]]
    }
  }
  return HookCell(mask: mask, target: target)
}

/// The hook as one section plays it (`mode` a `MotifMode`), over `plan`: a cell as long as
/// the plan cycle (or a multiple), every note on the sounding chord. Ignore plays it as is.
func renderHook(_ hook: HookCell, mode: Int, plan: ChordPlan) -> MotifCell {
  let cycle = max(cycleSteps(plan), 16)
  let stretch = mode == MotifMode.augmented ? 2 : 1
  let span = hook.length * stretch
  var n = cycle
  while n % span != 0 { n += cycle }
  var degrees = [Int](repeating: -1, count: n)
  var mask = [Bool](repeating: false, count: n)
  for i in 0..<n {
    if i % stretch != 0 { continue }
    let h = (i / stretch) % hook.length
    guard hook.mask[h] else { continue }
    if mode == MotifMode.fragment && h >= hook.length / 2 { continue }
    var t = hook.target[h]
    if mode == MotifMode.transposed { t += 2 }
    if mode == MotifMode.inverted { t = 9 - t }
    degrees[i] = nearestChordDegree(t, chordAt(plan, i))
    mask[i] = true
  }
  return MotifCell(degrees: degrees, mask: mask, contour: 0)
}

/// The tone of `chord` (any octave, degree ≥ 0) nearest to degree `t`; ties go down.
func nearestChordDegree(_ t: Int, _ chord: ChordDegree) -> Int {
  var best = -1
  for tone in chord.tones {
    var d = clampDegree(tone)
    while d <= t + 7 {
      if best < 0 || abs(d - t) < abs(best - t) || (abs(d - t) == abs(best - t) && d < best) {
        best = d
      }
      d += 7
    }
  }
  return max(0, best)
}

// MARK: - chord snap

/// Copy a ring net out to `length` steps (a multiple of its own), bindings repeated.
func tileRing(_ nb: NetBundle, to length: Int) -> NetBundle {
  let n = nb.transitions.count
  guard n > 0, length > n, length % n == 0 else { return nb }
  var out = NetBundle.ring(length)
  out.track = nb.track
  out.role = nb.role
  out.riffGroup = nb.riffGroup
  out.riffVariant = nb.riffVariant
  for i in 0..<length {
    if let b = nb.bindings["t\(i % n)"] { out.bindings["t\(i)"] = b }
  }
  out.track.ringSize = Double(length)
  out.track.beats = Double(out.bindings.count)
  return out
}

func isPlainRing(_ nb: NetBundle) -> Bool {
  let n = nb.transitions.count
  return n > 0 && nb.places.count == n && nb.transitions["t\(n - 1)"] != nil
    && nb.controlBindings.count == 0
}

func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

/// Move the notes on `mode`'s beats to the nearest pitch of the chord sounding there (the
/// ring is tiled out to the plan cycle first, so it can follow the chords).
func snapToChords(_ nb: inout NetBundle, _ ctx: TechniqueContext, mode: ChordSnap) {
  guard mode != .off, isPlainRing(nb), !ctx.plan.chords.isEmpty else { return }
  let n = nb.transitions.count
  let cycle = cycleSteps(ctx.plan)
  let l = n / gcd(n, cycle) * cycle
  if l != n { nb = tileRing(nb, to: l) }
  for i in 0..<l where mode.applies(at: i) {
    guard var b = nb.bindings["t\(i)"] else { continue }
    let pcs = ctx.chordPCs[(i / ctx.plan.stepsPerChord) % ctx.plan.chords.count]
    b.note = nearestPitch(b.note, pcs)
    nb.bindings["t\(i)"] = b
  }
}

/// The MIDI note with a pitch class in `pcs` nearest to `note`; ties go down.
func nearestPitch(_ note: Int, _ pcs: [Int]) -> Int {
  for d in 0...6 {
    if note - d >= 0 && pcs.contains(((note - d) % 12 + 12) % 12) { return note - d }
    if note + d <= 127 && pcs.contains((note + d) % 12) { return note + d }
  }
  return note
}

// MARK: - melody density on motif cells

/// Keep at most `density × 16` notes per bar of a motif cell, strongest steps first.
func thinCell(_ cell: MotifCell, density: Double) -> MotifCell {
  let keep = max(1, Int((density * 16).rounded(.down)))
  var out = cell
  var bar = 0
  while bar < cell.degrees.count {
    let end = min(bar + 16, cell.degrees.count)
    let on = (bar..<end).filter { cell.mask[$0] && cell.degrees[$0] >= 0 }
    if on.count > keep {
      func weight(_ i: Int) -> Int {
        let s = i - bar
        return s % 16 == 0 ? 4 : s % 8 == 0 ? 3 : s % 4 == 0 ? 2 : s % 2 == 0 ? 1 : 0
      }
      let kept = Set(on.sorted { (weight($0), -$0) > (weight($1), -$1) }.prefix(keep))
      for i in on where !kept.contains(i) {
        out.mask[i] = false
        out.degrees[i] = -1
      }
    }
    bar = end
  }
  return out
}

// MARK: - bass follow

/// One bass bar (a seeded Markov bass line, degrees from the chord root), played on every
/// chord of the plan: the same pattern each cycle, whatever the section.
func followBassRing(_ plan: ChordPlan, scale: [Int], params: GenParams) -> NetBundle {
  var rng = Mulberry32(seed: params.seed)
  let seq = composeSequence(
    steps: 16, scaleLen: 7, chordTones: [0, 2, 4], isBass: true, density: params.density,
    rng: &rng)
  let bars = max(plan.chords.count, 1)
  let barSteps = plan.chords.isEmpty ? 16 : plan.stepsPerChord
  var notes = [Int](repeating: 0, count: bars * barSteps)
  var mask = [Bool](repeating: false, count: bars * barSteps)
  for b in 0..<bars {
    let root = plan.chords.isEmpty ? 0 : clampDegree(chordAt(plan, b * barSteps).root)
    for s in 0..<barSteps where seq[s % 16] >= 0 {
      mask[b * barSteps + s] = true
      var note = degreeToMidi(root + seq[s % 16], scale)
      // keep it in the bass register an octave span above the key's root
      if let low = scale.first, note >= low + 12 + 7 { note -= 12 }
      notes[b * barSteps + s] = note
    }
  }
  var nb = notedRing(notes, mask, params)
  nb.track.generator = "bass-follow"
  return nb
}

// MARK: - layer budget

/// Melodic roles in the order a budget keeps them.
let layerPriority = ["bass", "melody", "lead", "harmony", "pad", "chord", "chords", "arp"]

/// `layerBudget: "auto"` per section name (others: 2).
let autoLayerBudget: [String: Int] = [
  "intro": 1, "verse": 2, "pre-chorus": 2, "buildup": 2, "drop": 3, "chorus": 3,
  "breakdown": 1, "bridge": 2, "solo": 2, "outro": 1,
]

/// Deactivate the lowest-priority melodic roles of each section beyond its budget: their
/// slots become -1 (the structure nets mute them there); nets are left in place.
func applyLayerBudget(_ tmpl: inout SongTemplate, budget: Int) {
  for si in 0..<tmpl.sections.count {
    let sec = tmpl.sections[si]
    let cap = budget > 0 ? budget : (autoLayerBudget[sec.name] ?? 2)
    let melodic = layerPriority.filter { sec.active.contains($0) }
    guard melodic.count > cap else { continue }
    let dropped = Set(melodic[cap...])
    tmpl.sections[si].active = OrderedFlags(sec.active.keys.filter { !dropped.contains($0) })
    for role in dropped {
      if var map = tmpl.slotMap[role], si < map.count {
        map[si] = [Int](repeating: -1, count: map[si].count)
        tmpl.slotMap[role] = map
      }
    }
  }
}
