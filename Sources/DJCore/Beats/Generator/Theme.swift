import Foundation

// Port of generator/theme.js (cohesion v2) and groove.js.

public enum MotifMode {
  public static let ignore = 0
  public static let play = 1
  public static let transposed = 2
  public static let fragment = 3
  public static let augmented = 4
  public static let inverted = 5
  public static let layered = 6
}

public enum Groove {
  public static let fourOnFloor = 0
  public static let offbeat = 1
  public static let sidechained = 2
  public static let syncoPocket = 3
  public static let breakbeat = 4
  public static let walking = 5
  public static let bossa = 6
}

public struct ChordPlan {
  public var stepsPerChord: Int
  public var chords: [ChordDegree]
}

public struct MotifCell: Equatable {
  public var degrees: [Int]
  public var mask: [Bool]
  public var contour: Int
}

public struct TrackTheme {
  public var motif: MotifCell
  public var plan: ChordPlan
  public var harmonic: [String: Int]
  public var groove: Int
  public var energy: OrderedMap<SectionProfile>
}

func chordAt(_ plan: ChordPlan, _ step: Int) -> ChordDegree {
  if plan.chords.isEmpty { return ChordDegree(root: 0, tones: [0, 2, 4]) }
  let idx = (step / plan.stepsPerChord) % plan.chords.count
  return plan.chords[idx]
}

func cycleSteps(_ plan: ChordPlan) -> Int { plan.chords.count * plan.stepsPerChord }

func clampDegree(_ d: Int) -> Int {
  var d = d
  while d < 0 { d += 7 }
  while d >= 7 { d -= 7 }
  return d
}

/// FNV-32 over UTF-16 code units (`hashStr`).
func hashStr(_ s: String) -> UInt32 {
  var h: UInt32 = 2_166_136_261
  for u in s.utf16 {
    h = (h ^ UInt32(u)) &* 16_777_619
  }
  return h
}

public func cohesionGenreSupported(_ genre: String) -> Bool {
  BeatsTables.shared.themeTable(genre)?.supported ?? false
}

/// `buildTrackTheme(genreName, seed)` — pure function of its inputs.
public func buildTrackTheme(genre: String, seed: Double) -> TrackTheme {
  let tables = BeatsTables.shared
  let u = UInt32(bitPattern: jsToInt32(seed))
  let initial = Int32(bitPattern: u ^ hashStr("theme/" + genre))
  var rng = Mulberry32(seed: Int(initial))

  var plan = ChordPlan(stepsPerChord: 16, chords: [])
  if let progs = tables.genres[genre]?.theory?.chordProgs, !progs.isEmpty {
    plan.chords = progs[rng.nextInt(progs.count)].chords
  } else {
    _ = rng.nextInt(1)
    plan.chords = [
      ChordDegree(root: 0, tones: [0, 2, 4]), ChordDegree(root: 5, tones: [5, 0, 2]),
      ChordDegree(root: 3, tones: [3, 5, 0]), ChordDegree(root: 6, tones: [6, 1, 3]),
    ]
  }
  let motif = generateMotif(&rng, scaleLen: 7, plan: plan)
  let harmonic = [
    "intro": 0, "verse": 0, "buildup": 0, "drop": 0, "breakdown": 0, "bridge": 5, "chorus": 0,
    "outro": 0, "solo": 4,
  ]
  let table = tables.themeTable(genre)
  return TrackTheme(
    motif: motif, plan: plan, harmonic: harmonic, groove: table?.groove ?? 0,
    energy: table?.energy ?? OrderedMap())
}

func generateMotif(_ rng: inout Mulberry32, scaleLen: Int, plan: ChordPlan) -> MotifCell {
  let bars = 4
  let barSteps = 16
  let motifLen = bars * barSteps
  var degrees = [Int](repeating: 0, count: motifLen)
  var mask = [Bool](repeating: false, count: motifLen)

  for b in 0..<bars {
    let hits = 6 + rng.nextInt(3)
    let base = b * barSteps
    var have = 0
    var i = 0
    while i < barSteps {
      mask[base + i] = true
      have += 1
      i += 4
    }
    while have < hits {
      let j = rng.nextInt(barSteps)
      if !mask[base + j] {
        mask[base + j] = true
        have += 1
      }
    }
  }

  var cur = 0
  for i in 0..<motifLen {
    if !mask[i] {
      degrees[i] = -1
      continue
    }
    let bar = i / barSteps
    let chord = chordAt(plan, bar * plan.stepsPerChord)
    if i % 4 == 0 {
      cur = nearestToneOf(cur, scaleLen, chord.tones)
    } else {
      let delta = rng.nextInt(5) - 2
      cur += delta
      if cur < 0 { cur = 0 }
      if cur > scaleLen - 1 { cur = scaleLen - 1 }
    }
    degrees[i] = cur
  }

  var li = lastActiveIn(degrees, barSteps, 2 * barSteps)
  if li >= 0 {
    let c = chordAt(plan, plan.stepsPerChord)
    if c.tones.count > 1 { degrees[li] = clampDegree(c.tones[1]) }
  }
  li = lastActiveIn(degrees, 3 * barSteps, 4 * barSteps)
  if li >= 0 { degrees[li] = 0 }

  var first = -1
  var last = -1
  for d in degrees where d >= 0 {
    if first < 0 { first = d }
    last = d
  }
  var contour = 0
  if first >= 0 && last >= 0 {
    if last > first {
      contour = 1
    } else if last < first {
      contour = -1
    }
  }
  return MotifCell(degrees: degrees, mask: mask, contour: contour)
}

func nearestToneOf(_ cur: Int, _ scaleLen: Int, _ tones: [Int]) -> Int {
  if tones.contains(cur) { return cur }
  var dist = 1
  while dist < scaleLen {
    for t in tones where t == cur + dist && t < scaleLen { return t }
    for t in tones where t == cur - dist && t >= 0 { return t }
    dist += 1
  }
  if let t = tones.first { return clampDegree(t) }
  return 0
}

func lastActiveIn(_ degrees: [Int], _ from: Int, _ to: Int) -> Int {
  var i = to - 1
  while i >= from {
    if degrees[i] >= 0 { return i }
    i -= 1
  }
  return -1
}

/// `renderMotif(cell, mode, harmonicOffset)`
public func renderMotif(_ cell: MotifCell, mode: Int, harmonicOffset: Int = 0) -> MotifCell {
  switch mode {
  case MotifMode.ignore:
    return MotifCell(degrees: [], mask: [], contour: 0)
  case MotifMode.play, MotifMode.layered, MotifMode.transposed:
    var out = cell
    if mode == MotifMode.transposed || harmonicOffset != 0 {
      for i in 0..<out.degrees.count where out.degrees[i] >= 0 {
        out.degrees[i] = clampDegree(out.degrees[i] + harmonicOffset)
      }
    }
    return out
  case MotifMode.fragment:
    var out = cell
    let half = out.degrees.count / 2
    for i in half..<max(out.degrees.count, half) {
      out.degrees[i] = -1
      out.mask[i] = false
    }
    return out
  case MotifMode.augmented:
    let dl = cell.degrees.count * 2
    var out = MotifCell(
      degrees: [Int](repeating: 0, count: dl), mask: [Bool](repeating: false, count: dl),
      contour: cell.contour)
    for i in 0..<cell.degrees.count {
      out.degrees[i * 2] = cell.degrees[i]
      out.mask[i * 2] = cell.mask[i]
      out.degrees[i * 2 + 1] = -1
      out.mask[i * 2 + 1] = false
    }
    return out
  case MotifMode.inverted:
    var out = cell
    for i in 0..<out.degrees.count where out.degrees[i] >= 0 {
      out.degrees[i] = clampDegree((7 - 1) - out.degrees[i] + harmonicOffset)
    }
    out.contour = -cell.contour
    return out
  default:
    return cell
  }
}

/// `degreeToMidi`
func degreeToMidi(_ degree: Int, _ scale: [Int]) -> Int {
  if scale.isEmpty { return 60 }
  if degree < 0 { return 0 }
  if degree < scale.count { return scale[degree] }
  let octaves = degree / scale.count
  return scale[degree % scale.count] + 12 * octaves
}

// MARK: - Net builders

private func finishTrack(
  _ nb: inout NetBundle, _ params: GenParams, generator: String, ringSize: Int, beats: Int,
  seedKey: Bool = true
) {
  nb.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: generator, ringSize: Double(ringSize), beats: Double(beats),
    rotation: nil, note: nil,
    generatorParams: obj([("duration", .int(params.duration)), ("seed", .number(params.seed))]))
}

func motifNet(_ cell: MotifCell, scale: [Int], params: GenParams) -> NetBundle {
  var degrees = cell.degrees
  var mask = cell.mask
  var n = degrees.count
  if n == 0 {
    n = 16
    degrees = [Int](repeating: -1, count: n)
    mask = [Bool](repeating: false, count: n)
  }
  var nb = NetBundle.ring(n)
  for i in 0..<n where mask[i] && degrees[i] >= 0 {
    nb.bind(
      i, note: degreeToMidi(degrees[i], scale), channel: params.channel,
      velocity: clampVelocity(params.velocity), duration: params.duration)
  }
  finishTrack(&nb, params, generator: "motif", ringSize: n, beats: mask.filter { $0 }.count)
  return nb
}

func notedRing(_ notes: [Int], _ mask: [Bool], _ params: GenParams) -> NetBundle {
  notedRingDur(notes, mask, nil, params)
}

func notedRingDur(_ notes: [Int], _ mask: [Bool], _ durs: [Int]?, _ params: GenParams)
  -> NetBundle
{
  var m = mask
  var nt = notes
  var n = m.count
  if n == 0 {
    n = 16
    m = [Bool](repeating: false, count: n)
    nt = [Int](repeating: 0, count: n)
  }
  var nb = NetBundle.ring(n)
  for i in 0..<n where m[i] && i < nt.count {
    var dur = params.duration
    if let durs, i < durs.count, durs[i] > 0 { dur = durs[i] }
    nb.bind(
      i, note: nt[i], channel: params.channel, velocity: clampVelocity(params.velocity),
      duration: dur)
  }
  finishTrack(&nb, params, generator: "noted-ring", ringSize: n, beats: m.filter { $0 }.count)
  return nb
}

func chordPadNet(_ plan: ChordPlan, scale: [Int], params: GenParams) -> NetBundle {
  var n = cycleSteps(plan)
  if n == 0 { n = 64 }
  var nb = NetBundle.ring(n)
  for c in 0..<plan.chords.count {
    let chord = plan.chords[c]
    let base = c * plan.stepsPerChord
    var v = 0
    while v < chord.tones.count && v < 3 {
      let step = base + v
      if step >= n { break }
      nb.bind(
        step, note: degreeToMidi(clampDegree(chord.tones[v]), scale), channel: params.channel,
        velocity: clampVelocity(params.velocity), duration: params.duration)
      v += 1
    }
  }
  finishTrack(&nb, params, generator: "chord-pad", ringSize: n, beats: plan.chords.count * 3)
  return nb
}

func chordBassRing(
  _ plan: ChordPlan, barMask: [Bool], scale: [Int], params: GenParams, registerShift: Int = 0
) -> NetBundle {
  var barSteps = barMask.count
  var bm = barMask
  if barSteps == 0 {
    barSteps = 16
    bm = [Bool](repeating: false, count: barSteps)
  }
  var bars = plan.chords.count
  if bars == 0 { bars = 4 }
  let n = bars * barSteps
  var mask = [Bool](repeating: false, count: n)
  var notes = [Int](repeating: 0, count: n)
  for b in 0..<bars {
    let chord = chordAt(plan, b * plan.stepsPerChord)
    let root = degreeToMidi(clampDegree(chord.root), scale) + registerShift
    for i in 0..<barSteps {
      let idx = b * barSteps + i
      mask[idx] = bm[i]
      notes[idx] = root
    }
  }
  return notedRing(notes, mask, params)
}

func chordWalkingBassRing(
  _ plan: ChordPlan, scale: [Int], params: GenParams, registerShift: Int = 0
) -> NetBundle {
  var barSteps = plan.stepsPerChord
  if barSteps <= 0 { barSteps = 16 }
  var bars = plan.chords.count
  if bars == 0 { bars = 4 }
  let beats = 4
  var stride = barSteps / beats
  if stride < 1 { stride = 1 }
  let n = bars * barSteps
  var mask = [Bool](repeating: false, count: n)
  var notes = [Int](repeating: 0, count: n)
  for b in 0..<bars {
    let chord = chordAt(plan, b * plan.stepsPerChord)
    let next = chordAt(plan, ((b + 1) % bars) * plan.stepsPerChord)
    for beat in 0..<beats {
      let step = beat * stride
      if step >= barSteps { break }
      let idx = b * barSteps + step
      mask[idx] = true
      notes[idx] = walkingBassNote(beat, chord, next, scale, registerShift)
    }
  }
  return notedRing(notes, mask, params)
}

private func walkingBassNote(
  _ beat: Int, _ chord: ChordDegree, _ next: ChordDegree, _ scale: [Int], _ shift: Int
) -> Int {
  let root = degreeToMidi(clampDegree(chord.root), scale) + shift
  switch beat {
  case 1:
    return chord.tones.count > 1 ? degreeToMidi(clampDegree(chord.tones[1]), scale) + shift : root
  case 2:
    return chord.tones.count > 2 ? degreeToMidi(clampDegree(chord.tones[2]), scale) + shift : root
  case 3:
    let nextRoot = degreeToMidi(clampDegree(next.root), scale) + shift
    return nextRoot < root ? nextRoot + 1 : nextRoot - 1
  default:
    return root
  }
}

func chordBossaBassRing(
  _ plan: ChordPlan, scale: [Int], params: GenParams, registerShift: Int = 0, bpm: Double = 120
) -> NetBundle {
  var barSteps = plan.stepsPerChord
  if barSteps <= 0 { barSteps = 16 }
  var bars = plan.chords.count
  if bars == 0 { bars = 4 }
  var fifthStep = barSteps * 3 / 8
  if fifthStep <= 0 || fifthStep >= barSteps { fifthStep = barSteps / 2 }
  var barMs = 2000
  if bpm > 0 { barMs = Int((4.0 * 60000.0 / bpm * 0.95).rounded(.down)) }
  let rootDur = barMs * 3 / 8
  let fifthDur = barMs / 4
  let n = bars * barSteps
  var mask = [Bool](repeating: false, count: n)
  var notes = [Int](repeating: 0, count: n)
  var durs = [Int](repeating: 0, count: n)
  for b in 0..<bars {
    let chord = chordAt(plan, b * plan.stepsPerChord)
    let root = degreeToMidi(clampDegree(chord.root), scale) + registerShift
    var fifth = root
    if chord.tones.count > 2 {
      fifth = degreeToMidi(clampDegree(chord.tones[2]), scale) + registerShift
    }
    while fifth >= root { fifth -= 12 }
    let base = b * barSteps
    mask[base] = true
    notes[base] = root
    durs[base] = rootDur
    mask[base + fifthStep] = true
    notes[base + fifthStep] = fifth
    durs[base + fifthStep] = fifthDur
  }
  return notedRingDur(notes, mask, durs, params)
}

/// `kickHitMask(genre)`
func kickHitMask(_ genre: GenreDef) -> [Bool] {
  let k = genre.kick.count > 0 ? genre.kick[0] : 4
  let n = genre.kick.count > 1 ? genre.kick[1] : 16
  let rot = genre.kick.count > 2 ? genre.kick[2] : 0
  let pattern = bjorklund(k, n)
  let r = ((rot % n) + n) % n
  return (0..<n).map { pattern[($0 + r) % n] == 1 }
}

/// `grooveLock(kickMask, template, rng)`. composer.js passes its rng *object* where
/// grooveLock tests `typeof rng === 'function'`, so the breakbeat rotation is
/// always 0 and no RNG draw happens; that behaviour is the contract.
func grooveLock(_ kickMask: [Bool], template: Int) -> [Bool] {
  let n = kickMask.count
  var out = [Bool](repeating: false, count: n)
  switch template {
  case Groove.fourOnFloor:
    out = kickMask
  case Groove.offbeat:
    for i in 0..<n where kickMask[i] { out[((i - 1) % n + n) % n] = true }
  case Groove.sidechained:
    for i in 0..<n { out[i] = !kickMask[i] }
  case Groove.syncoPocket:
    out = kickMask
    var off1 = 6
    var off2 = 14
    if n == 8 {
      off1 = 3
      off2 = 7
    }
    if off1 < n { out[off1] = true }
    if off2 < n { out[off2] = true }
  case Groove.breakbeat:
    var hits = n * 3 / 8
    if hits < 1 { hits = 1 }
    for i in 0..<hits { out[(i * n / hits) % n] = true }
  default:
    out = kickMask
  }
  return out
}
