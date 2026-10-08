import Testing

@testable import DJCore

@MainActor
struct NetSnapshotTests {
  func deck(_ spec: TrackSpec) throws -> (DJEngine, Deck) {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    a.loadNet(PreparedTrack(spec: spec, sampleRate: 22_050))
    return (dj, a)
  }

  @Test func tokensAreWhereTheExecutorPutThem() throws {
    let spec = TrackSpec(genre: "techno", seed: 42, extra: JSONObject([("bpm", .number(480))]))
    let (dj, a) = try deck(spec)
    let g = WaveGraph(project: compose(genre: "techno", overrides: spec.overrides))
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    var checked = 0
    var lastTick = -1
    for _ in 0..<400 {
      _ = try renderOffline(dj, frames: 128)
      let snap = try #require(a.netSnapshot)
      // bring the reference graph to the same tick
      while g.tick < snap.tick { g.advance() }
      guard snap.tick != lastTick, g.tick == snap.tick else { continue }
      lastTick = snap.tick
      for ring in snap.rings {
        let net = g.nets[g.byId[ring.id]!]
        let token = (0..<net.nPlaces).first { net.state[$0] == 1 }
        #expect(token == ring.token, "\(ring.id) @tick \(snap.tick)")
        checked += 1
      }
    }
    #expect(checked > 200)
  }

  @Test func ringsCarryTheirHitsAndRoles() throws {
    let (_, a) = try deck(TrackSpec(genre: "techno", seed: 42))
    let snap = try #require(a.netSnapshot)
    #expect(snap.tick == 0)
    let byRole = Dictionary(uniqueKeysWithValues: snap.rings.map { ($0.role, $0) })
    #expect(
      Set(byRole.keys).isSuperset(of: [
        "kick", "snare", "hihat", "bass", "melody", "harmony", "hit1", "hit4",
      ]))
    let kick = try #require(byRole["kick"])
    #expect(kick.size == 16 && kick.hits.filter { $0 }.count == 4, "techno kick: 4 on the floor")
    #expect(kick.token == 0 && kick.lastFired == -1 && !kick.muted)
    #expect(byRole["harmony"]?.size == 64)
    #expect(byRole["hit1"]?.muted == true, "stingers start muted")
    // velocities where there are hits, zero elsewhere
    #expect(zip(kick.hits, kick.velocities).allSatisfy { $0 ? $1 > 0 : $1 == 0 })
  }

  @Test func songsShowTheAudibleSlotOfEachRole() async throws {
    let (dj, a) = try deck(TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    a.wave.setTempo(600)
    a.setPlaying(true)
    try dj.start()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 4096)
    let snap = try #require(a.netSnapshot)
    let bass = try #require(snap.rings.first { $0.role == "bass" })
    #expect(bass.id.hasPrefix("bass-"), "a slot net: \(bass.id)")
    let g = try #require(a.wave.latest?.graph)
    #expect(a.wave.isNetMuted(index: g.byId[bass.id]!) == bass.muted)
    // muting the role dims its ring
    a.setRole("bass", on: false)
    _ = try renderOffline(dj, frames: 2048)
    #expect(try #require(a.netSnapshot?.rings.first { $0.role == "bass" }).muted)
  }

  @Test func sampleDecksHaveNoNetView() throws {
    let dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    #expect(dj["A"]!.netSnapshot == nil)
  }

  @Test func onlySingleTokenRingsQualify() {
    var nb = NetBundle.ring(8)
    #expect(RingShape(nb)?.size == 8)
    nb.arcs[3].inhibit = true
    #expect(RingShape(nb) == nil)
    var two = NetBundle.ring(8)
    two.places["p3"]!.initial = [1]
    #expect(RingShape(two) == nil)
    #expect(RingShape(NetBundle()) == nil)
  }
}
