import Foundation

// Port of generator/variety.js: ghost-note hihat, walking bass, call/response,
// modal interchange, drum fills, chorus.

struct Tension {
  var densityMul: Double
  var velocityAdd: Int
  var registerShift: Int
}

func tensionForVariant(_ variant: String) -> Tension {
  switch variant {
  case "B": Tension(densityMul: 1.3, velocityAdd: 10, registerShift: 2)
  case "C": Tension(densityMul: 0.6, velocityAdd: -10, registerShift: -3)
  default: Tension(densityMul: 1.0, velocityAdd: 0, registerShift: 0)
  }
}

public func ghostNoteHihat(
  hits: Int, steps: Int, rotation: Int, note: Int, params: GenParams, ghostDensity: Double
) -> NetBundle {
  let pattern = rotated(bjorklund(hits, steps), by: rotation)
  var lcg = LCG(seed: params.seed)
  var bundle = NetBundle.ring(steps)
  for i in 0..<steps {
    if pattern[i] == 1 {
      let vel = accentVelocity(step: i, total: steps, base: params.velocity, accent: params.accent)
      bundle.bind(
        i, note: note, channel: params.channel, velocity: clampVelocity(vel),
        duration: params.duration)
    } else if lcg.float64() < ghostDensity {
      let ghostVel = 30 + lcg.intn(20)
      bundle.bind(
        i, note: note, channel: params.channel, velocity: clampVelocity(ghostVel),
        duration: params.duration)
    }
  }
  bundle.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "euclidean-ghost", ringSize: Double(steps),
    beats: Double(hits), rotation: Double(rotation), note: Double(note),
    generatorParams: obj([
      ("duration", .int(params.duration)), ("seed", .number(params.seed)),
      ("accent", .int(params.accent.rawValue)), ("ghostDensity", .number(ghostDensity)),
    ]))
  return bundle
}

public func walkingBassLine(_ params: GenParams) -> NetBundle {
  var notes = params.scale
  if notes.isEmpty { notes = majorScale(params.rootNote) }
  var steps = params.steps ?? 16
  if steps <= 0 { steps = 16 }
  var lcg = LCG(seed: params.seed)

  var chordRoots = [Int](repeating: params.rootNote, count: steps)
  if let prog = params.chords, !prog.chords.isEmpty {
    var stepsPer = prog.stepsPer
    if stepsPer <= 0 { stepsPer = 4 }
    for i in 0..<steps {
      let chordIdx = (i / stepsPer) % prog.chords.count
      let rootDeg = prog.chords[chordIdx].root
      chordRoots[i] = rootDeg < notes.count ? notes[rootDeg] : params.rootNote
    }
  }

  var seq = [Int](repeating: 0, count: steps)
  seq[0] = chordRoots[0]
  for i in 1..<max(steps, 1) {
    let beatPos = i % 4
    let currentNote = seq[i - 1]
    let targetRoot = chordRoots[i]
    if beatPos == 0 {
      seq[i] = targetRoot
    } else {
      let nextStrongBeat = (i / 4 + 1) * 4
      var nextTarget = targetRoot
      if nextStrongBeat < steps { nextTarget = chordRoots[nextStrongBeat] }
      let diff = nextTarget - currentNote
      if diff == 0 {
        seq[i] = lcg.float64() < 0.5 ? currentNote + 1 : currentNote - 1
      } else {
        let stepsLeft = 4 - beatPos
        var stepSize = diff / stepsLeft  // Math.trunc
        if stepSize == 0 { stepSize = diff > 0 ? 1 : -1 }
        if lcg.float64() < 0.3 {
          seq[i] = diff > 0 ? currentNote + 1 : currentNote - 1
        } else {
          seq[i] = currentNote + stepSize
        }
      }
    }
    if seq[i] < 24 { seq[i] = 24 }
    if seq[i] > 72 { seq[i] = 72 }
  }

  var noteCount = Int((params.density * Double(steps)).rounded(.down))
  if noteCount < 1 { noteCount = 1 }
  var rests = Set<Int>()
  if noteCount < steps {
    let restsNeeded = steps - noteCount
    for _ in 0..<restsNeeded {
      var bestIdx = -1
      var bestScore = 1000
      for j in 1..<max(steps, 1) {
        if rests.contains(j) { continue }
        let score: Int
        switch j % 4 {
        case 0: score = 100
        case 2: score = 50
        default: score = 0
        }
        if score < bestScore {
          bestScore = score
          bestIdx = j
        }
      }
      if bestIdx >= 0 { rests.insert(bestIdx) }
    }
  }

  var bundle = NetBundle.ring(steps)
  for i in 0..<steps {
    if rests.contains(i) { continue }
    var dur = params.duration
    if params.durationVariation > 0 {
      dur = Int(
        (Double(dur) * (0.8 + lcg.float64() * 0.4 * params.durationVariation)).rounded(.down))
      if dur < 20 { dur = 20 }
    }
    var vel = params.velocity
    switch i % 4 {
    case 0: vel += 15
    case 2: vel += 5
    default: vel -= 10
    }
    bundle.bind(
      i, note: seq[i], channel: params.channel, velocity: clampVelocity(vel), duration: dur)
  }
  bundle.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "walking-bass", ringSize: Double(steps),
    beats: Double(steps - rests.count), rotation: nil, note: nil,
    generatorParams: obj([
      ("scale", jsonArray(notes)), ("rootNote", .int(params.rootNote)),
      ("chords", params.chords?.json), ("seed", .number(params.seed)),
      ("duration", .int(params.duration)), ("density", .number(params.density)),
      ("durationVariation", .number(params.durationVariation)),
    ]))
  return bundle
}

public func callResponseMelody(_ params: GenParams) -> NetBundle {
  var notes = params.scale
  if notes.isEmpty { notes = majorScale(params.rootNote) }
  var n = notes.count
  if n > 12 {
    n = 12
    notes = Array(notes[0..<n])
  }
  var rng = LCG(seed: params.seed)
  let tones = chordToneSet(params.chords, scaleLen: n)

  var totalSteps = params.steps ?? 0
  if totalSteps < 4 { totalSteps = 32 }
  let halfSteps = totalSteps / 2
  let resolveAt = max(1, Int((Double(halfSteps) * 0.75).rounded(.down)))

  let callSeq = composeSequence(
    steps: halfSteps, scaleLen: n, chordTones: tones, isBass: false, density: params.density,
    rng: &rng)
  var responseSeq = [Int](repeating: 0, count: halfSteps)
  var current = callSeq[0]
  for i in 0..<halfSteps {
    if callSeq[i] < 0 {
      responseSeq[i] = -1
      continue
    }
    if i >= resolveAt {
      if current > 0 {
        current -= 1
      } else if current < 0 {
        current += 1
      }
      responseSeq[i] = current
    } else {
      current = composeMelodyStep(current, i % 4, n, tones, &rng)
      responseSeq[i] = current
    }
  }
  if responseSeq[halfSteps - 1] != -1 { responseSeq[halfSteps - 1] = 0 }

  var seq = [Int](repeating: -1, count: totalSteps)
  for i in 0..<halfSteps { seq[i] = callSeq[i] }
  for i in 0..<halfSteps { seq[halfSteps + i] = responseSeq[i] }

  var bundle = NetBundle.ring(totalSteps)
  for i in 0..<totalSteps {
    let deg = seq[i]
    if deg < 0 { continue }
    let vel = computeVelocity(step: i % 16, deg: deg, baseVel: params.velocity, chordTones: tones)
    let dur = computeDuration(
      deg: deg, baseDur: params.duration, variation: params.durationVariation, chordTones: tones,
      rng: &rng)
    bundle.bind(
      i, note: notes[deg], channel: params.channel, velocity: clampVelocity(vel), duration: dur)
  }
  bundle.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "call-response", ringSize: Double(totalSteps),
    beats: Double(seq.filter { $0 >= 0 }.count), rotation: nil, note: nil,
    generatorParams: obj([
      ("scale", jsonArray(notes)), ("rootNote", .int(params.rootNote)),
      ("chords", params.chords?.json), ("seed", .number(params.seed)),
      ("duration", .int(params.duration)), ("density", .number(params.density)),
      ("durationVariation", .number(params.durationVariation)),
    ]))
  return bundle
}

public func applyModalInterchange(
  _ prog: ChordProg, scale: [Int], probability: Double, rng: inout Mulberry32
) -> ChordProg {
  if probability <= 0 { return prog }
  let isMajor = scale.count >= 3 && scale[2] - scale[0] == 4
  var result = prog
  for i in 0..<result.chords.count {
    if i == 0 { continue }
    if rng.float64() < probability {
      let chord = result.chords[i]
      var tones = chord.tones
      if tones.count >= 2 {
        if isMajor {
          if tones[1] > 0 { tones[1] -= 1 }
        } else {
          tones[1] += 1
        }
      }
      result.chords[i] = ChordDegree(root: chord.root, tones: tones)
    }
  }
  return result
}

public func drumFillNet(boundaryStep: Int, fillLength: Int) -> NetBundle {
  let fillLength = fillLength < 2 ? 4 : fillLength
  let fillNotes = [38, 45, 48, 43, 38, 48]
  let total = boundaryStep < 1 ? 1 : boundaryStep
  var bundle = NetBundle()
  let (cx, cy, radius) = ringLayout(total + 1)
  for i in 0...total {
    let angle = Double(i) / Double(total + 1) * 2 * Double.pi
    bundle.places["p\(i)"] = Place(
      initial: [i == 0 ? 1 : 0], x: cx + radius * 0.7 * cos(angle),
      y: cy + radius * 0.7 * sin(angle), label: nil)
  }
  for i in 0..<total {
    let angle = (Double(i) + 0.5) / Double(total + 1) * 2 * Double.pi
    bundle.transitions["t\(i)"] = Transition(
      x: cx + radius * cos(angle), y: cy + radius * sin(angle), label: nil)
    bundle.arcs.append(Arc(source: "p\(i)", target: "t\(i)", weight: [1], inhibit: false))
    bundle.arcs.append(Arc(source: "t\(i)", target: "p\(i + 1)", weight: [1], inhibit: false))
    let fillStart = total - fillLength
    if i >= fillStart {
      let fillPos = i - fillStart
      var vel = 60 + fillPos * 50 / fillLength
      if vel > 127 { vel = 127 }
      bundle.bind(
        i, note: fillNotes[fillPos % fillNotes.count], channel: 10, velocity: clampVelocity(vel),
        duration: 40)
    }
  }
  bundle.track = Track(channel: 10, defaultVelocity: 100, instrument: "", instrumentSet: [])
  bundle.role = "control"
  return bundle
}

/// `chorus(proj, genre, rng)`: adds a `harmony` net a fifth above the melody.
func addChorus(_ proj: inout Project, genre: GenreDef, rng: inout Mulberry32) {
  let melodyRoot = genre.rootNote + 12 + 7
  var p = GenParams()
  p.scale = genre.scale(melodyRoot)
  p.rootNote = melodyRoot
  p.channel = 7
  p.velocity = 75
  p.duration = genre.melodyDuration
  p.density = genre.melodyDensity * 0.8
  p.seed = Double(rng.nextInt63())
  p.steps = 16
  p.durationVariation = 0
  p.syncopation = 0
  proj.nets["harmony"] = markovMelody(p)
}
