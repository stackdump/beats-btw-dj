// Port of generator/euclidean.js and riffs.js.

/// Bjorklund: K pulses spread over N steps as evenly as possible (0/1 array).
public func bjorklund(_ k: Int, _ n: Int) -> [Int] {
  if k >= n { return [Int](repeating: 1, count: max(n, 0)) }
  if k == 0 { return [Int](repeating: 0, count: n) }
  var groups: [[Int]] = (0..<n).map { $0 < k ? [1] : [0] }
  var kk = k
  while true {
    let remainder = groups.count - kk
    if remainder <= 1 { break }
    var merges = kk
    if remainder < merges { merges = remainder }
    var next: [[Int]] = []
    for i in 0..<merges { next.append(groups[i] + groups[groups.count - 1 - i]) }
    for i in merges..<(groups.count - merges) { next.append(groups[i]) }
    groups = next
    kk = merges
    if groups.count - kk <= 1 { break }
  }
  return groups.flatMap { $0 }
}

/// Rotation as euclidean/ghost hihat apply it: `pattern[(i + rot) % n]`.
func rotated(_ pattern: [Int], by rotation: Int) -> [Int] {
  guard rotation != 0 else { return pattern }
  let n = pattern.count
  var rot = rotation % n
  if rot < 0 { rot += n }
  return (0..<n).map { pattern[($0 + rot) % n] }
}

/// `euclidean(k, n, rotation, note, params)`
public func euclidean(_ k: Int, _ n: Int, _ rotation: Int, _ note: Int, _ params: GenParams)
  -> NetBundle
{
  let pattern = rotated(bjorklund(k, n), by: rotation)
  var nb = NetBundle.ring(n)
  for i in 0..<n where pattern[i] == 1 {
    let vel = accentVelocity(step: i, total: n, base: params.velocity, accent: params.accent)
    nb.bind(
      i, note: note, channel: params.channel, velocity: clampVelocity(vel),
      duration: params.duration)
  }
  nb.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "euclidean", ringSize: Double(n), beats: Double(k),
    rotation: Double(rotation), note: Double(note),
    generatorParams: obj([
      ("duration", .int(params.duration)), ("seed", .number(params.seed)),
      ("accent", .int(params.accent.rawValue)),
    ]))
  return nb
}

/// `euclideanMelodic(notes, steps, seed, params)` — every step bound, cycling `notes`.
public func euclideanMelodic(_ notes: [Int], steps: Int, seed: Double, _ params: GenParams)
  -> NetBundle
{
  let notes = notes.isEmpty ? [60] : notes
  var nb = NetBundle.ring(steps)
  for i in 0..<steps {
    nb.bind(
      i, note: notes[i % notes.count], channel: params.channel, velocity: params.velocity,
      duration: params.duration)
  }
  nb.track = Track(
    channel: params.channel, defaultVelocity: params.velocity, instrument: "", instrumentSet: [],
    mix: nil, group: nil, generator: "euclidean-melodic", ringSize: Double(steps),
    beats: Double(steps), rotation: nil, note: nil,
    generatorParams: obj([
      ("scale", jsonArray(notes)), ("seed", .number(seed)), ("duration", .int(params.duration)),
    ]))
  return nb
}

// MARK: - riffs.js

/// `drumRiff(variant, hits, steps, rotation, note, params, style)`
public func drumRiff(
  variant: String, hits: Int, steps: Int, rotation: Int, note: Int, params: GenParams,
  style: DrumVariant?
) -> NetBundle {
  var params = params
  var hits = hits
  var rotation = rotation
  if let style, variant != "A" {
    hits += style.hitsAdd
    if let mul = style.hitsMul, mul != 0, mul != 1.0 {
      hits = Int((Double(hits) * mul).rounded(.down))
    }
    rotation = (rotation + style.rotationAdd) % steps
    if hits < 1 { hits = 1 }
    if hits > steps { hits = steps }
  } else {
    switch variant {
    case "B":
      params.velocity = min(127, params.velocity + 15)
      params.duration = Int((Double(params.duration) * 1.4).rounded(.down))
    case "C":
      params.velocity = max(40, params.velocity - 20)
      params.duration = Int((Double(params.duration) * 0.6).rounded(.down))
    default: break
    }
  }
  return euclidean(hits, steps, rotation, note, params)
}

/// `melodyRiff(variant, params)`
public func melodyRiff(variant: String, params: GenParams) -> NetBundle {
  var params = params
  var rng = Mulberry32(seed: params.seed)
  switch variant {
  case "B":
    params.density = params.density * 1.4
    if params.density > 1.0 { params.density = 1.0 }
    params.seed = params.seed + 1000 + (rng.float64() * 1000).rounded(.down)
  case "C":
    params.density = params.density * 0.5
    params.duration = Int((Double(params.duration) * 1.5).rounded(.down))
    params.seed = params.seed + 2000 + (rng.float64() * 1000).rounded(.down)
  default: break
  }
  return markovMelody(params)
}
