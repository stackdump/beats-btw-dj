// Port of beats' wave-engine/net.js: the Petri-net executor compiled to flat arrays.
//
// Semantics are the sequencer worker's `_advanceOneTick` with deterministicLoop on:
// nets in project order, enabled transitions in key order, one winner per contested
// input place chosen by deterministicRand(tick, strHash(place)), controls applied
// immediately so a mute fired by an earlier net affects later nets in the same tick.
// Not ported (same as the JS): macros (`fire-macro`), loop/seek, drift — reported,
// not applied.

public enum ControlAction: UInt8 {
  case none = 0
  case mute = 1
  case unmute = 2
  case toggle = 3
  case muteNote = 4
  case unmuteNote = 5
  case toggleNote = 6
  case slot = 7
  case stop = 8
  case other = 9

  init(name: String) {
    switch name {
    case "mute-track": self = .mute
    case "unmute-track": self = .unmute
    case "toggle-track": self = .toggle
    case "mute-note": self = .muteNote
    case "unmute-note": self = .unmuteNote
    case "toggle-note": self = .toggleNote
    case "activate-slot": self = .slot
    case "stop-transport": self = .stop
    default: self = .other
    }
  }
}

/// `deterministicRand(tick, salt)` — identical to the sequencer worker.
public func deterministicRand(tick: Int, salt: Int32) -> Double {
  var rng = Mulberry32(seed: Int(Int32(truncatingIfNeeded: tick &+ Int(salt))))
  return rng.next()
}

/// `strHash`: `h = imul(31, h) + charCode | 0` over UTF-16 code units.
public func strHash(_ s: String) -> Int32 {
  var h: Int32 = 0
  for u in s.utf16 { h = 31 &* h &+ Int32(u) }
  return h
}

public final class CompiledNet {
  public let id: String
  public let index: Int
  public let bundle: NetBundle
  public let placeIds: [String]
  public let transIds: [String]
  public let nPlaces: Int
  public let nTrans: Int

  let inStart: [Int]
  let inPlace: [Int]
  let inW: [Double]
  let inInhib: [Bool]
  let outStart: [Int]
  let outPlace: [Int]
  let outW: [Double]
  let placeSalt: [Int32]
  let initial: [Double]
  public var state: [Double]

  public let midi: [Bool]
  public let note: [Int]
  public let vel: [Int]
  public let durMs: [Double]
  public let durSteps: [Double]
  let action: [ControlAction]
  let actionNote: [Int]
  let actionTarget: [String]
  var actionTargetIdx: [Int]
  public let group: String
  var groupIdx = -1
  /// Lane index of every MIDI-bound transition (filled by the runner); -1 otherwise.
  public var lane: [Int]

  // scratch, sized once
  var enabled: [Int]
  var blocked: [Bool]
  var consumers: [Int]
  var placeCount: [Int]

  init(id: String, nb: NetBundle, index: Int) {
    self.id = id
    self.index = index
    bundle = nb
    placeIds = nb.places.keys
    transIds = nb.transitions.keys
    nPlaces = placeIds.count
    nTrans = transIds.count
    var pIdx: [String: Int] = [:]
    for (i, p) in placeIds.enumerated() where pIdx[p] == nil { pIdx[p] = i }

    // nb.inputArcs[t] / outputArcs[t]: arcs by target / source, in document order.
    var inputArcs: [String: [Arc]] = [:]
    var outputArcs: [String: [Arc]] = [:]
    for arc in nb.arcs {
      inputArcs[arc.target, default: []].append(arc)
      outputArcs[arc.source, default: []].append(arc)
    }
    func weightSum(_ w: [Double]) -> Double { w.isEmpty ? 1 : w.reduce(0, +) }

    var inStart = [Int](repeating: 0, count: nTrans + 1)
    var outStart = [Int](repeating: 0, count: nTrans + 1)
    var ins: [(Int, Double, Bool)] = []
    var outs: [(Int, Double)] = []
    for (i, t) in transIds.enumerated() {
      inStart[i] = ins.count
      for ca in inputArcs[t] ?? [] {
        ins.append((pIdx[ca.source] ?? -1, weightSum(ca.weight), ca.inhibit))
      }
      outStart[i] = outs.count
      for ca in outputArcs[t] ?? [] { outs.append((pIdx[ca.target] ?? -1, weightSum(ca.weight))) }
    }
    inStart[nTrans] = ins.count
    outStart[nTrans] = outs.count
    self.inStart = inStart
    self.outStart = outStart
    inPlace = ins.map { $0.0 }
    inW = ins.map { $0.1 }
    inInhib = ins.map { $0.2 }
    outPlace = outs.map { $0.0 }
    outW = outs.map { $0.1 }
    placeSalt = placeIds.map(strHash)

    // nb.resetState(): the marking is the sum of each place's initial.
    var st = [Double](repeating: 0, count: nPlaces)
    for (i, p) in placeIds.enumerated() {
      st[i] = nb.places[p]!.initial.reduce(0, +)
    }
    initial = st
    // A separate buffer: `state = st` would share storage with `initial`, and the first
    // write on the audio thread would copy it (an allocation).
    state = [Double](unsafeUninitializedCapacity: st.count) { buf, count in
      for i in 0..<st.count { buf[i] = st[i] }
      count = st.count
    }

    var midi = [Bool](repeating: false, count: nTrans)
    var note = [Int](repeating: 0, count: nTrans)
    var vel = [Int](repeating: 0, count: nTrans)
    var durMs = [Double](repeating: 0, count: nTrans)
    var durSteps = [Double](repeating: 0, count: nTrans)
    var action = [ControlAction](repeating: .none, count: nTrans)
    var actionNote = [Int](repeating: 0, count: nTrans)
    var actionTarget: [String] = []
    for (i, t) in transIds.enumerated() {
      if let b = nb.bindings[t] {
        midi[i] = true
        note[i] = Int(Int16(truncatingIfNeeded: b.note))
        vel[i] = Int(Int16(truncatingIfNeeded: b.velocity))
        durMs[i] = Double(b.duration)
        durSteps[i] = Double(b.durationSteps)
      }
      if let c = nb.controlBindings[t] {
        actionTarget.append(c.targetNet)
        action[i] = ControlAction(name: c.action)
        actionNote[i] = c.targetNote
      } else {
        actionTarget.append("")
      }
    }
    self.midi = midi
    self.note = note
    self.vel = vel
    self.durMs = durMs
    self.durSteps = durSteps
    self.action = action
    self.actionNote = actionNote
    self.actionTarget = actionTarget
    actionTargetIdx = [Int](repeating: -1, count: nTrans)
    group = nb.riffGroup
    lane = [Int](repeating: -1, count: nTrans)
    enabled = [Int](repeating: 0, count: nTrans)
    blocked = [Bool](repeating: false, count: nTrans)
    consumers = [Int](repeating: 0, count: max(1, ins.count))
    placeCount = [Int](repeating: 0, count: nPlaces)
  }
}

public final class WaveGraph {
  public let project: Project
  public let nets: [CompiledNet]
  public let byId: [String: Int]
  /// strHash(netId) → net index (first net wins on a hash collision): lets the audio
  /// thread address a net without a string.
  public let byHash: [Int32: Int]
  public let groups: [String]
  public var tempo: Double
  public var tick = 0
  public var muted: [UInt8]
  public var mutedNotes: [UInt8]
  public var mutedGroups: [UInt8]
  public var stopRequested = false
  /// Events of the last tick, for the UI: (net, transition) pairs flattened. Fixed capacity.
  public var fired = [Int32](repeating: 0, count: 8192)
  public var firedCount = 0
  public var controls = [Int32](repeating: 0, count: 1024)
  public var controlCount = 0
  public var overflow = 0
  /// Where every fired transition is also reported (see `FireEventSink`). Set on the
  /// main thread before the graph is handed to the audio thread.
  public var fireSink: FireEventSink?

  // Live-performance state (not in the JS executor: see WaveMacros.swift).
  /// Per net: drum channel / control net. Computed once at compile time.
  let isDrumNet: [Bool]
  let isControlNet: [Bool]
  let isKickNet: [Bool]
  /// Role name hash → group index (>= 0) or `-(net index) - 2` for a plain net.
  let roleTargets: [Int32: Int]
  /// Net indices of each group, in project order.
  let groupNets: [[Int]]
  /// The slot a group last activated (-1: none yet).
  var activeSlot: [Int]
  // Tick-locked timers (the restore half of a macro): fixed capacity, never grown.
  static let timerCapacity = 512
  var timerRemaining = [Int32](repeating: 0, count: WaveGraph.timerCapacity)
  /// 0 free, 1 unmute, 2 mute, 3 delayed mute macro
  var timerKind = [UInt8](repeating: 0, count: WaveGraph.timerCapacity)
  var timerNet = [Int32](repeating: 0, count: WaveGraph.timerCapacity)
  var timerArg = [Int32](repeating: 0, count: WaveGraph.timerCapacity)
  public internal(set) var timerOverflow = 0
  // Reversible history (WaveHistory.swift): what each recent tick fired and every state
  // change it (or a macro command just before it) made, so the clock can run backwards.
  static let historyTicks = 512
  static let fireCapacity = 1 << 17
  static let changeCapacity = 6 << 14
  var hFires = [Int32](repeating: 0, count: WaveGraph.fireCapacity)
  var hChanges = [Int32](repeating: 0, count: WaveGraph.changeCapacity)
  var hFireEnd = [Int32](repeating: 0, count: WaveGraph.historyTicks)
  var hChangeEnd = [Int32](repeating: 0, count: WaveGraph.historyTicks)
  var hTicks = 0  // ticks currently recorded (oldest first)
  var hFireCount = 0
  var hChangeCount = 0
  var recording = true
  var fireNeedCache = -1
  // Beat-repeat: bursts of mutes every `repeatStep` ticks.
  var repeatRemaining = 0
  var repeatElapsed = 0
  var repeatStep = 2
  var repeatBurst = 1

  /// `compileProject(json)`: the project is round-tripped through `parseProject` in the JS,
  /// so a composed Project goes through its own JSON form here for the same rounding.
  public convenience init(project p: Project) {
    self.init(parsed: Project(json: p.toJSON()))
  }

  public convenience init(json: JSONValue) { self.init(parsed: Project(json: json)) }

  init(parsed proj: Project) {
    project = proj
    let ids = proj.nets.keys
    let nets = ids.enumerated().map { CompiledNet(id: $1, nb: proj.nets[$1]!, index: $0) }
    self.nets = nets
    var byId: [String: Int] = [:]
    for (i, id) in ids.enumerated() { byId[id] = i }
    self.byId = byId
    var byHash: [Int32: Int] = [:]
    for (i, id) in ids.enumerated() where byHash[strHash(id)] == nil { byHash[strHash(id)] = i }
    self.byHash = byHash
    var groups: [String] = []
    for n in nets where !n.group.isEmpty && !groups.contains(n.group) { groups.append(n.group) }
    self.groups = groups
    for n in nets {
      n.groupIdx = n.group.isEmpty ? -1 : groups.firstIndex(of: n.group)!
      for t in 0..<n.nTrans {
        let tgt = n.actionTarget[t]
        if !tgt.isEmpty, let i = byId[tgt] { n.actionTargetIdx[t] = i }
      }
    }
    tempo = proj.tempo > 0 ? proj.tempo : 120
    isControlNet = nets.map { $0.bundle.role == "control" }
    isDrumNet = nets.map { isDrumChannel($0.bundle.track.channel) }
    isKickNet = nets.map { n in
      n.bundle.riffGroup == "kick" || n.id == "kick" || n.id.hasPrefix("kick:")
    }
    var roleTargets: [Int32: Int] = [:]
    var groupNets = [[Int]](repeating: [], count: groups.count)
    for n in nets where n.bundle.role != "control" {
      if n.groupIdx >= 0 { groupNets[n.groupIdx].append(n.index) }
    }
    for (gi, name) in groups.enumerated() { roleTargets[strHash(name)] = gi }
    for n in nets where n.bundle.role != "control" && n.groupIdx < 0 {
      // a plain net is addressed by its id, unless a group already claimed that name
      if roleTargets[strHash(n.id)] == nil { roleTargets[strHash(n.id)] = -n.index - 2 }
    }
    self.roleTargets = roleTargets
    self.groupNets = groupNets
    activeSlot = [Int](repeating: -1, count: groups.count)
    muted = [UInt8](repeating: 0, count: nets.count)
    mutedNotes = [UInt8](repeating: 0, count: nets.count * 128)
    mutedGroups = [UInt8](repeating: 0, count: max(1, groups.count))
    reset()
  }

  public func reset() {
    tick = 0
    stopRequested = false
    for i in 0..<muted.count { muted[i] = 0 }
    for i in 0..<mutedNotes.count { mutedNotes[i] = 0 }
    for i in 0..<mutedGroups.count { mutedGroups[i] = 0 }
    // In place (never `state = initial`): reset runs on the audio thread via stop().
    for n in nets { for p in 0..<n.nPlaces { n.state[p] = n.initial[p] } }
    for id in project.initialMutes {
      if let i = byId[id] { muted[i] = 1 }
    }
    clearMacros()
    clearHistory()
    for gi in 0..<groupNets.count { activeSlot[gi] = groupNets[gi].first { muted[$0] == 0 } ?? -1 }
  }

  // MARK: executor

  private func isEnabled(_ n: CompiledNet, _ t: Int) -> Bool {
    let end = n.inStart[t + 1]
    if n.inStart[t] == end { return false }
    for a in n.inStart[t]..<end {
      let tok = n.inPlace[a] >= 0 ? n.state[n.inPlace[a]] : 0
      if n.inInhib[a] {
        if tok >= n.inW[a] { return false }
      } else if tok < n.inW[a] {
        return false
      }
    }
    return true
  }

  private func fire(_ n: CompiledNet, _ t: Int) {
    for a in n.inStart[t]..<n.inStart[t + 1] {
      let p = n.inPlace[a]
      if !n.inInhib[a] && p >= 0 {
        n.state[p] -= n.inW[a]
        if n.state[p] < 0 { n.state[p] = 0 }
      }
    }
    for a in n.outStart[t]..<n.outStart[t + 1] {
      let p = n.outPlace[a]
      if p >= 0 { n.state[p] += n.outW[a] }
    }
  }

  /// Returns the number of survivors written back into `n.enabled`.
  private func resolveConflicts(_ n: CompiledNet, _ count: Int, _ tick: Int) -> Int {
    for i in 0..<n.nPlaces { n.placeCount[i] = 0 }
    var contested = false
    for i in 0..<count {
      let t = n.enabled[i]
      for a in n.inStart[t]..<n.inStart[t + 1] where !n.inInhib[a] && n.inPlace[a] >= 0 {
        n.placeCount[n.inPlace[a]] += 1
        if n.placeCount[n.inPlace[a]] > 1 { contested = true }
      }
    }
    if !contested { return count }
    for i in 0..<n.nTrans { n.blocked[i] = false }
    for p in 0..<n.nPlaces {
      if n.placeCount[p] < 2 { continue }
      var c = 0
      for i in 0..<count {
        let t = n.enabled[i]
        for a in n.inStart[t]..<n.inStart[t + 1] where !n.inInhib[a] && n.inPlace[a] == p {
          n.consumers[c] = t
          c += 1
        }
      }
      let r = deterministicRand(tick: tick, salt: n.placeSalt[p])
      let winner = n.consumers[Int((r * Double(c)).rounded(.down))]
      for i in 0..<c where n.consumers[i] != winner { n.blocked[n.consumers[i]] = true }
    }
    var w = 0
    for i in 0..<count where !n.blocked[n.enabled[i]] {
      n.enabled[w] = n.enabled[i]
      w += 1
    }
    return w
  }

  private func applyControl(_ n: CompiledNet, _ t: Int) {
    let tgt = n.actionTargetIdx[t]
    switch n.action[t] {
    case .mute: if tgt >= 0 { setMuted(tgt, 1) }
    case .unmute: if tgt >= 0 { setMuted(tgt, 0) }
    case .toggle: if tgt >= 0 { setMuted(tgt, muted[tgt] ^ 1) }
    case .muteNote: if tgt >= 0 { mutedNotes[tgt * 128 + (n.actionNote[t] & 127)] = 1 }
    case .unmuteNote: if tgt >= 0 { mutedNotes[tgt * 128 + (n.actionNote[t] & 127)] = 0 }
    case .toggleNote: if tgt >= 0 { mutedNotes[tgt * 128 + (n.actionNote[t] & 127)] ^= 1 }
    case .slot:
      if tgt >= 0 {
        let gi = nets[tgt].groupIdx
        if gi >= 0 {
          for o in nets where o.groupIdx == gi && o.index != tgt { setMuted(o.index, 1) }
          if mutedGroups[gi] == 0 { setMuted(tgt, 0) }
          logChange(2, gi, activeSlot[gi])
          activeSlot[gi] = tgt
        }
      }
    case .stop: stopRequested = true
    case .none, .other: break
    }
    if controlCount + 2 <= controls.count {
      controls[controlCount] = Int32(n.index)
      controls[controlCount + 1] = Int32(t)
      controlCount += 2
    } else {
      overflow += 1
    }
  }

  /// Advance every net one tick. `onNote(net, t)` is called for each fired transition
  /// whose MIDI binding is audible (net un-muted, note un-muted), in firing order.
  public func advance() { advance { _, _ in } }

  public func advance(_ onNote: (CompiledNet, Int) -> Void) {
    tick += 1
    firedCount = 0
    controlCount = 0
    ensureHistoryRoom()
    for ni in 0..<nets.count {
      let n = nets[ni]
      var count = 0
      for t in 0..<n.nTrans where isEnabled(n, t) {
        n.enabled[count] = t
        count += 1
      }
      if count > 1 { count = resolveConflicts(n, count, tick) }
      for i in 0..<count {
        let t = n.enabled[i]
        fire(n, t)
        logFire(ni, t)
        if n.action[t] != .none { applyControl(n, t) }
        let audible = n.midi[t] && muted[ni] == 0 && mutedNotes[ni * 128 + (n.note[t] & 127)] == 0
        if let sink = fireSink {
          sink.push(
            FireEvent(
              net: Int16(truncatingIfNeeded: ni), transition: Int16(truncatingIfNeeded: t),
              note: n.midi[t] ? Int16(truncatingIfNeeded: n.note[t] & 127) : -1,
              velocity: UInt8(truncatingIfNeeded: max(0, min(127, n.vel[t]))),
              flags: (audible ? FireEvent.audibleFlag : 0)
                | (n.action[t] != .none ? FireEvent.controlFlag : 0),
              tick: Int32(truncatingIfNeeded: tick), frame: sink.frame))
        }
        if audible {
          if firedCount + 2 <= fired.count {
            fired[firedCount] = Int32(ni)
            fired[firedCount + 1] = Int32(t)
            firedCount += 2
          } else {
            overflow += 1
          }
          onNote(n, t)
        }
      }
    }
    serviceMacros()
    endTickRecord()
  }

  /// Plain marking `{netId: {place: tokens}}` — for the UI, allocates.
  public func marking() -> [String: [String: Double]] {
    var out: [String: [String: Double]] = [:]
    for n in nets {
      var m: [String: Double] = [:]
      for p in 0..<n.nPlaces { m[n.placeIds[p]] = n.state[p] }
      out[n.id] = m
    }
    return out
  }
}

// MARK: - Incidence matrix and nPlaces-invariants

extension CompiledNet {
  /// `mat[p][t] = Σ weight(t→p) − Σ weight(p→t)`, inhibitor arcs excluded.
  public func incidenceMatrix() -> [[Double]] {
    var mat = [[Double]](repeating: [Double](repeating: 0, count: nTrans), count: nPlaces)
    for t in 0..<nTrans {
      for a in inStart[t]..<inStart[t + 1] where !inInhib[a] && inPlace[a] >= 0 {
        mat[inPlace[a]][t] -= inW[a]
      }
      for a in outStart[t]..<outStart[t + 1] where outPlace[a] >= 0 {
        mat[outPlace[a]][t] += outW[a]
      }
    }
    return mat
  }
}

/// Basis of `{ y : yᵀC = 0 }` by Gaussian elimination on Cᵀ (nTrans×nPlaces, row-major).
public func pInvariants(_ mat: [[Double]]) -> [[Double]] {
  let nPlaces = mat.count
  let nTrans = nPlaces > 0 ? mat[0].count : 0
  var work = [Double](repeating: 0, count: nTrans * nPlaces)
  for t in 0..<nTrans { for p in 0..<nPlaces { work[t * nPlaces + p] = mat[p][t] } }
  var pivots: [Int] = []
  work.withUnsafeMutableBufferPointer { a in
    var r = 0
    var c = 0
    while c < nPlaces && r < nTrans {
      defer { c += 1 }
      var best = r
      var i = r + 1
      while i < nTrans {
        if abs(a[i * nPlaces + c]) > abs(a[best * nPlaces + c]) { best = i }
        i += 1
      }
      if abs(a[best * nPlaces + c]) < 1e-12 { continue }
      if best != r { for j in 0..<nPlaces { a.swapAt(r * nPlaces + j, best * nPlaces + j) } }
      let piv = a[r * nPlaces + c]
      for j in 0..<nPlaces { a[r * nPlaces + j] /= piv }
      for i in 0..<nTrans {
        if i == r || a[i * nPlaces + c] == 0 { continue }
        let f = a[i * nPlaces + c]
        for j in 0..<nPlaces { a[i * nPlaces + j] -= f * a[r * nPlaces + j] }
      }
      pivots.append(c)
      r += 1
    }
  }
  var isPivot = [Bool](repeating: false, count: nPlaces)
  for c in pivots { isPivot[c] = true }
  var out: [[Double]] = []
  for fc in 0..<nPlaces where !isPivot[fc] {
    var y = [Double](repeating: 0, count: nPlaces)
    y[fc] = 1
    for (row, pc) in pivots.enumerated() { y[pc] = -work[row * nPlaces + fc] }
    out.append(y)
  }
  return out
}
