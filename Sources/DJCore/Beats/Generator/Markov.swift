// Port of generator/markov.js.

/// `composeSequence`: scale-degree indices, -1 for rests.
func composeSequence<R: RandomSource>(
  steps: Int, scaleLen: Int, chordTones: Set<Int>, isBass: Bool, density: Double, rng: inout R
) -> [Int] {
  var seq = [Int](repeating: 0, count: steps)
  var current = 0
  seq[0] = current
  for i in 1..<max(steps, 1) {
    let beatPos = i % 4
    if isBass {
      current = composeBassStep(current, beatPos, scaleLen, &rng)
    } else {
      current = composeMelodyStep(current, beatPos, scaleLen, chordTones, &rng)
    }
    seq[i] = current
  }

  var noteCount = Int((density * Double(steps)).rounded(.down))
  if noteCount < 1 { noteCount = 1 }
  if noteCount >= steps { return seq }
  let restsNeeded = steps - noteCount

  var candidates: [(idx: Int, score: Int)] = []
  for i in 0..<steps {
    var s: Int
    switch i % 4 {
    case 0: s = 100
    case 2: s = 50
    default: s = 0
    }
    if i == 0 { s = 200 }
    candidates.append((i, s))
  }
  // Insertion sort ascending by score (stable), as the JS does.
  if candidates.count > 1 {
    for i in 1..<candidates.count {
      var j = i
      while j > 0 && candidates[j].score < candidates[j - 1].score {
        candidates.swapAt(j, j - 1)
        j -= 1
      }
    }
  }
  var i = 0
  while i < restsNeeded && i < candidates.count {
    let idx = candidates[i].idx
    if idx != 0 { seq[idx] = -1 }
    i += 1
  }
  return seq
}

func composeMelodyStep<R: RandomSource>(
  _ current: Int, _ beatPos: Int, _ scaleLen: Int, _ chordTones: Set<Int>, _ rng: inout R
) -> Int {
  switch beatPos {
  case 0:
    return nearestChordTone(current, scaleLen, chordTones)
  case 2:
    if rng.float64() < 0.7 { return nearestChordTone(current, scaleLen, chordTones) }
    return stepwise(current, scaleLen, 1, &rng)
  default:
    let r = rng.float64()
    if r < 0.60 { return stepwise(current, scaleLen, 1, &rng) }
    if r < 0.85 { return stepwise(current, scaleLen, 2, &rng) }
    return current
  }
}

func composeBassStep<R: RandomSource>(
  _ current: Int, _ beatPos: Int, _ scaleLen: Int, _ rng: inout R
) -> Int {
  switch beatPos {
  case 0: return 0
  case 2:
    if scaleLen > 4 && rng.float64() < 0.6 { return 4 }
    return 0
  default:
    if rng.float64() < 0.5 { return current }
    return stepwise(current, scaleLen, 1, &rng)
  }
}

func nearestChordTone(_ current: Int, _ scaleLen: Int, _ chordTones: Set<Int>) -> Int {
  if chordTones.contains(current) { return current }
  var dist = 1
  while dist < scaleLen {
    let up = current + dist
    let down = current - dist
    if up < scaleLen && chordTones.contains(up) { return up }
    if down >= 0 && chordTones.contains(down) { return down }
    dist += 1
  }
  return 0
}

func stepwise<R: RandomSource>(_ current: Int, _ scaleLen: Int, _ interval: Int, _ rng: inout R)
  -> Int
{
  if rng.float64() < 0.5 {
    var next = current + interval
    if next >= scaleLen { next = current - interval }
    if next < 0 { next = 0 }
    return next
  }
  var next = current - interval
  if next < 0 { next = current + interval }
  if next >= scaleLen { next = scaleLen - 1 }
  return next
}

func computeVelocity(step: Int, deg: Int, baseVel: Int, chordTones: Set<Int>) -> Int {
  var vel = baseVel
  switch step % 4 {
  case 0: vel += 15
  case 2: vel += 5
  default: vel -= 10
  }
  if chordTones.contains(deg) { vel += 5 }
  return vel
}

func computeDuration<R: RandomSource>(
  deg: Int, baseDur: Int, variation: Double, chordTones: Set<Int>, rng: inout R
) -> Int {
  if variation <= 0 { return baseDur }
  var dur = Double(baseDur)
  if chordTones.contains(deg) {
    dur = (dur * (1.2 + rng.float64() * 0.8 * variation)).rounded(.down)
  } else {
    dur = (dur * (0.3 + rng.float64() * 0.5 * variation)).rounded(.down)
  }
  if dur < 20 { dur = 20 }
  return Int(dur)
}

func applySyncopation<R: RandomSource>(_ seq: inout [Int], _ probability: Double, _ rng: inout R) {
  var i = 2
  while i < seq.count {
    defer { i += 1 }
    if i % 2 != 0 { continue }
    if seq[i] < 0 || seq[i - 1] >= 0 { continue }
    if rng.float64() < probability {
      seq[i - 1] = seq[i]
      seq[i] = -1
    }
  }
}

/// Chord tones (scale-degree indices below `n`), defaulting to root/3rd/5th.
func chordToneSet(_ chords: ChordProg?, scaleLen n: Int) -> Set<Int> {
  var set = Set<Int>()
  for chord in chords?.chords ?? [] {
    for t in chord.tones where t < n { set.insert(t) }
  }
  if set.isEmpty { for deg in [0, 2, 4] where deg < n { set.insert(deg) } }
  return set
}

/// `markovMelody(params)`
public func markovMelody(_ params: GenParams) -> NetBundle {
  var notes = params.scale
  if notes.isEmpty {
    for oct in 0..<2 {
      for interval in majorIntervals {
        let n = params.rootNote + oct * 12 + interval
        if n <= 127 { notes.append(n) }
      }
    }
  }
  var n = notes.count
  if n > 12 {
    n = 12
    notes = Array(notes[0..<n])
  }
  var steps = params.steps ?? 16
  if steps <= 0 { steps = 16 }

  var rng = Mulberry32(seed: params.seed)
  let tones = chordToneSet(params.chords, scaleLen: n)
  let isBass = params.rootNote < 48

  var seq = composeSequence(
    steps: steps, scaleLen: n, chordTones: tones, isBass: isBass, density: params.density,
    rng: &rng)
  if params.syncopation > 0 { applySyncopation(&seq, params.syncopation, &rng) }

  var bundle = NetBundle.ring(steps)
  for i in 0..<steps {
    let deg = seq[i]
    if deg < 0 { continue }
    let vel = computeVelocity(step: i, deg: deg, baseVel: params.velocity, chordTones: tones)
    let dur = computeDuration(
      deg: deg, baseDur: params.duration, variation: params.durationVariation, chordTones: tones,
      rng: &rng)
    bundle.bind(
      i, note: notes[deg], channel: params.channel, velocity: clampVelocity(vel), duration: dur)
  }
  bundle.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "markov", ringSize: Double(steps),
    beats: Double(seq.filter { $0 >= 0 }.count), rotation: nil, note: nil,
    generatorParams: obj([
      ("scale", jsonArray(notes)), ("rootNote", .int(params.rootNote)),
      ("chords", params.chords?.json), ("seed", .number(params.seed)),
      ("duration", .int(params.duration)), ("density", .number(params.density)),
      ("durationVariation", .number(params.durationVariation)),
      ("syncopation", .number(params.syncopation)),
    ]))
  return bundle
}
