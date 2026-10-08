import Testing

@testable import DJCore

private func project(_ genre: String, _ seed: Double, _ structure: String?) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if let structure { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// Everything a tick can change.
private struct Snap: Equatable {
  var tick: Int
  var states: [[Double]]
  var muted: [UInt8]
  var groups: [UInt8]
  var slots: [Int]
  var timers: [Int32]
  var repeater: [Int]

  init(_ g: WaveGraph) {
    tick = g.tick
    states = g.nets.map { $0.state }
    muted = g.muted
    groups = g.mutedGroups
    slots = g.activeSlot
    timers = (0..<WaveGraph.timerCapacity).flatMap {
      g.timerKind[$0] == 0
        ? [Int32(0)]
        : [Int32(g.timerKind[$0]), g.timerNet[$0], g.timerRemaining[$0], g.timerArg[$0]]
    }
    repeater = [g.repeatRemaining, g.repeatElapsed]
  }
}

struct WaveHistoryTests {
  @Test(arguments: [
    ("techno", 42.0, "standard"), ("jazz", 7.0, "extended"), ("edm", 11.0, "standard"),
    ("ambient", 3.0, "minimal"),
  ])
  func rewindingRestoresEveryTickExactly(genre: String, seed: Double, structure: String) {
    let g = WaveGraph(project: project(genre, seed, structure))
    var forward: [Snap] = [Snap(g)]
    for _ in 0..<480 {
      g.advance()
      forward.append(Snap(g))
    }
    #expect(g.rewindableTicks == 480)
    for want in forward.dropLast().reversed() {
      #expect(g.unadvance { _, _ in })
      #expect(Snap(g) == want, "tick \(want.tick)")
      if Snap(g) != want { return }
    }
    #expect(!g.unadvance { _, _ in }, "nothing before tick 0")
    // and forward again reproduces the same history (deterministic conflict resolution)
    for want in forward.dropFirst() {
      g.advance()
      #expect(Snap(g) == want, "replay tick \(want.tick)")
      if Snap(g) != want { return }
    }
  }

  @Test func theLogIsBoundedAndTheNewestTicksStayRewindable() {
    let g = WaveGraph(project: project("techno", 42, "extended"))
    var history: [Int: Snap] = [:]
    for _ in 0..<1100 {
      g.advance()
      history[g.tick] = Snap(g)
    }
    let depth = g.rewindableTicks
    #expect(depth > 100 && depth <= WaveGraph.historyTicks)
    var undone = 0
    while g.unadvance({ _, _ in }) {
      undone += 1
      #expect(Snap(g) == history[g.tick], "tick \(g.tick)")
      if Snap(g) != history[g.tick] { return }
    }
    #expect(undone == depth)
  }

  @Test func undoingTicksReportsTheNotesTheyPlayed() {
    let g = WaveGraph(project: project("techno", 42, nil))
    var played: [[String]] = []
    for _ in 0..<32 {
      var hits: [String] = []
      g.advance { n, t in hits.append("\(n.id).\(n.transIds[t])") }
      played.append(hits)
    }
    #expect(played.contains { !$0.isEmpty })
    for expected in played.reversed() {
      var hits: [String] = []
      g.unadvance { n, t in hits.append("\(n.id).\(n.transIds[t])") }
      #expect(Set(hits) == Set(expected), "the same notes, undone")
    }
  }

  @Test func aMacroFiredJustBeforeATickIsUndoneWithIt() {
    let g = WaveGraph(project: project("techno", 42, nil))
    for _ in 0..<10 { g.advance() }
    let before = Snap(g)
    g.fireMute(.nonDrums, ticks: 12)
    g.fireBeatRepeat(ticks: 8)
    for _ in 0..<30 { g.advance() }
    for _ in 0..<30 { g.unadvance { _, _ in } }
    #expect(Snap(g) == before)
  }

  @Test func userMutesSurviveARewind() {
    let g = WaveGraph(project: project("techno", 42, nil))
    for _ in 0..<20 { g.advance() }
    g.setRoleMuted(hash: strHash("kick"), true)
    for _ in 0..<10 { g.advance() }
    for _ in 0..<25 { g.unadvance { _, _ in } }
    #expect(g.muted[g.byId["kick"]!] == 1, "a ring net has no control changes to undo")
  }

  @Test func stingersAndFastForwardStartAFreshLog() {
    let g = WaveGraph(project: project("jazz", 7, "standard"))
    g.fastForward(to: 200)
    #expect(g.tick == 200 && g.rewindableTicks == 0)
    for _ in 0..<8 { g.advance() }
    #expect(g.rewindableTicks == 8)
    g.fireStinger(hash: strHash("hit1"), ticks: 4)
    for _ in 0..<6 { g.advance() }
    for _ in 0..<6 { g.unadvance { _, _ in } }
    #expect(g.muted[g.byId["hit1"]!] == 1, "the stinger's unmute was undone")
  }
}
