import Foundation

// Port of generator/countermelody.js: the rule-based note kernel behind the
// `counterMelody` arrange directive. Rule-based only (answer / harmony / shadow).

/// PPQ matches sequencer-worker.js.
let counterPPQ = 4

/// fnv32a over the UTF-16 code units of the concatenated parts (JS `charCodeAt`).
func counterSeed(_ parts: [String]) -> UInt32 {
  var h: UInt32 = 0x811c_9dc5
  for part in parts {
    for u in part.utf16 {
      h = (h ^ UInt32(u)) &* 0x0100_0193
    }
  }
  return h
}

struct SourceNote {
  var tick: Int
  var note: Int
  var velocity: Int
}

struct CounterNote {
  var startTick: Int
  var note: Int
  var velocity: Int
  var duration: Int
}

/// The runtime half of `NetBundle` (arc index, `resetState`, `isEnabled`, `fire`) for the
/// transitions that carry a MIDI binding, with places densely indexed. Same semantics as the
/// JS: a transition with no input arcs is never enabled; tokens never go below zero.
struct CounterNetRuntime {
  private var initial: [Double] = []
  private var state: [Double] = []
  struct Input {
    var place: Int
    var weight: Double
    var inhibit: Bool
  }
  struct Output {
    var place: Int
    var weight: Double
  }
  private(set) var labels: [String] = []
  private(set) var bindings: [MidiBinding] = []
  private var inputs: [[Input]?] = []
  private var outputs: [[Output]] = []

  init(_ nb: NetBundle) {
    var index: [String: Int] = [:]
    func slot(_ name: String) -> Int {
      if let i = index[name] { return i }
      let i = index.count
      index[name] = i
      return i
    }
    for (id, p) in nb.places.pairs {
      _ = slot(id)
      initial.append(p.initial.reduce(0, +))
    }
    for a in nb.arcs {
      _ = slot(a.source)
      _ = slot(a.target)
    }
    while initial.count < index.count { initial.append(0) }
    func weightSum(_ w: [Double]) -> Double { w.isEmpty ? 1 : w.reduce(0, +) }

    // Object.keys(bindings).sort()
    labels = nb.bindings.keys.sorted(by: jsStringLess)
    for label in labels {
      bindings.append(nb.bindings[label]!)
      var ins: [Input] = []
      var outs: [Output] = []
      for a in nb.arcs {
        if a.target == label {
          ins.append(
            Input(place: index[a.source]!, weight: weightSum(a.weight), inhibit: a.inhibit))
        }
        if a.source == label {
          outs.append(Output(place: index[a.target]!, weight: weightSum(a.weight)))
        }
      }
      inputs.append(ins.isEmpty ? nil : ins)
      outputs.append(outs)
    }
    state = initial
  }

  mutating func reset() { state = initial }

  func isEnabled(_ li: Int) -> Bool {
    guard let ins = inputs[li] else { return false }
    for ca in ins {
      let tokens = state[ca.place]
      if ca.inhibit {
        if tokens >= ca.weight { return false }
      } else if tokens < ca.weight {
        return false
      }
    }
    return true
  }

  mutating func fire(_ li: Int) {
    if let ins = inputs[li] {
      for ca in ins where !ca.inhibit {
        state[ca.place] -= ca.weight
        if state[ca.place] < 0 { state[ca.place] = 0 }
      }
    }
    for o in outputs[li] { state[o.place] += o.weight }
  }
}

/// `simulateMusicNotes(proj, totalTicks, scopeNetID)`. `plain` lists the nets that exist in JS
/// as unparsed objects (no `resetState`): reaching one throws, exactly as the JS does.
func simulateMusicNotes(
  _ proj: Project, totalTicks: Int, scope: String?, plain: Set<String>
) throws -> (hits: [Bool], pitches: [Int], notes: [SourceNote]) {
  var hits = [Bool](repeating: false, count: totalTicks)
  var pitchSet = Set<Int>()
  var notes: [SourceNote] = []
  for id in proj.nets.keys.sorted(by: jsStringLess) {
    if let scope, id != scope { continue }
    guard let nb = proj.nets[id] else { continue }
    if nb.role == "control" { continue }
    if plain.contains(id) { throw ArrangeError.netNotParsed(id) }
    var rt = CounterNetRuntime(nb)
    rt.reset()
    for tick in 0..<totalTicks {
      var fired = false
      for li in 0..<rt.labels.count where rt.isEnabled(li) {
        rt.fire(li)
        fired = true
        let b = rt.bindings[li]
        if b.note > 0 {
          hits[tick] = true
          pitchSet.insert(b.note)
          var vel = b.velocity
          if vel <= 0 { vel = 90 }
          notes.append(SourceNote(tick: tick, note: b.note, velocity: vel))
        }
        break
      }
      if !fired { rt.reset() }
    }
  }
  return (hits, pitchSet.sorted(), notes)
}

private func clampPitch(_ p: Int) -> Int {
  var pitch = p
  while pitch < 24 { pitch += 12 }
  while pitch > 108 { pitch -= 12 }
  return pitch
}

func answerMode(
  hits: [Bool], pitches: [Int], register: String, density: Double, rng: inout Mulberry32
) -> [CounterNote] {
  let transpose = register == "below" ? -12 : 12
  var notes: [CounterNote] = []
  let total = hits.count
  var t = 0
  while t < total {
    if hits[t] {
      t += 1
      continue
    }
    let runStart = t
    while t < total && !hits[t] { t += 1 }
    let runLen = t - runStart
    if runLen < 2 { continue }
    if rng.float64() > density { continue }
    let basePitch = clampPitch(pitches[rng.intn(pitches.count)] + transpose)
    let startTick = runStart + runLen / 2
    var dur = runLen / 2
    if dur > 8 { dur = 8 }
    if dur < 1 { dur = 1 }
    notes.append(CounterNote(startTick: startTick, note: basePitch, velocity: 90, duration: dur))
  }
  return notes
}

func harmonyMode(src: [SourceNote], register: String, density: Double, rng: inout Mulberry32)
  -> [CounterNote]
{
  let interval = register == "below" ? -3 : 4
  var out: [CounterNote] = []
  for n in src {
    if rng.float64() > density { continue }
    out.append(
      CounterNote(
        startTick: n.tick, note: clampPitch(n.note + interval), velocity: n.velocity, duration: 4))
  }
  return out
}

func shadowMode(
  src: [SourceNote], totalTicks: Int, register: String, density: Double, rng: inout Mulberry32
) -> [CounterNote] {
  let transpose = register == "below" ? -12 : 12
  var out: [CounterNote] = []
  for n in src {
    if rng.float64() > density { continue }
    let echo = n.tick + 1
    if echo >= totalTicks { continue }
    var velocity = n.velocity / 2
    if velocity < 30 { velocity = 30 }
    out.append(
      CounterNote(
        startTick: echo, note: clampPitch(n.note + transpose), velocity: velocity, duration: 3))
  }
  return out
}

/// `generateCounterMelody`. nil: no source material; empty: the mode found nothing to add.
func generateCounterMelody(
  _ proj: Project, mode: String?, density rawDensity: Double, register: String?, seed: UInt32,
  totalTicks rawTicks: Int, sourceNetID: String?, plain: Set<String>
) throws -> [CounterNote]? {
  let register = register ?? "above"
  var density = rawDensity
  if density.isNaN || density <= 0 { density = 0.5 }
  if density > 1 { density = 1 }
  let totalTicks = rawTicks < 4 ? 4 : rawTicks
  let sim = try simulateMusicNotes(
    proj, totalTicks: totalTicks, scope: sourceNetID, plain: plain)
  if sim.pitches.isEmpty { return nil }
  var rng = Mulberry32(seed: Double(seed))
  switch mode {
  case "harmony":
    return harmonyMode(src: sim.notes, register: register, density: density, rng: &rng)
  case "shadow":
    return shadowMode(
      src: sim.notes, totalTicks: totalTicks, register: register, density: density, rng: &rng)
  default:
    return answerMode(
      hits: sim.hits, pitches: sim.pitches, register: register, density: density, rng: &rng)
  }
}

/// `buildMusicNet(notes, opts)` in its parsed form.
func buildCounterMelodyNet(
  notes: [CounterNote], totalTicks: Int, channel: Int, instrument: String, msPerTick: Double
) -> NetBundle? {
  if totalTicks <= 0 { return nil }
  // The JS writes all-zero coordinates; the worker's parse then recomputes the layout, which
  // for this single cycle is exactly the ring layout. (Coordinates are not in the model.)
  var nb = NetBundle.ring(totalTicks)
  nb.role = "music"
  nb.track = Track(
    channel: channel, defaultVelocity: 90, instrument: instrument, instrumentSet: [],
    group: "harmony")
  for n in notes {
    if n.startTick < 0 || n.startTick >= totalTicks { continue }
    var durMs = Int((Double(n.duration) * msPerTick).rounded(.down))
    if durMs < 1 { durMs = 1 }
    nb.bind(n.startTick, note: n.note, channel: channel, velocity: n.velocity, duration: durMs)
  }
  return nb
}

/// JS `Number.prototype.toFixed(6)`: the exact binary value rounded half up (not the
/// half-even a C `printf` does on exact ties such as 0.0078125).
func jsToFixed6(_ x: Double) -> String {
  if x.isNaN { return "NaN" }
  if abs(x) >= 1e21 { return jsNumberString(x) }
  let neg = x < 0
  let exact = String(format: "%.100f", abs(x))
  let parts = exact.split(separator: ".", omittingEmptySubsequences: false)
  var digits = Array(parts[0].utf8)  // integer digits then 6 fractional digits
  let frac = Array(parts[1].utf8)
  digits += frac[0..<6]
  if frac[6] >= UInt8(ascii: "5") {
    var i = digits.count - 1
    while i >= 0 {
      if digits[i] == UInt8(ascii: "9") {
        digits[i] = UInt8(ascii: "0")
        i -= 1
      } else {
        digits[i] += 1
        break
      }
    }
    if i < 0 { digits.insert(UInt8(ascii: "1"), at: 0) }
  }
  let intLen = digits.count - 6
  let s =
    String(decoding: digits[0..<intLen], as: UTF8.self) + "."
    + String(decoding: digits[intLen...], as: UTF8.self)
  return (neg ? "-" : "") + s
}
