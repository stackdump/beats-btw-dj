import Testing

@testable import DJCore

// The stage model against real offline engines: panels from the sounding project, live tokens,
// fires mapped to panels, the 100 ms flash, mutes that dim and flip variants but never reflow,
// source switches.

@MainActor
struct StageModelTests {
  @Test func thePanelsAreTheMusicNetsInTheRingOrder() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.2)
    let c = h.ctx
    // techno `standard`: melody 4, bass 6, harmony 7, kick 10, snare 11, hihat 12; every
    // variant group collapses to its first net (all muted at the start, except kick-0, hihat-0),
    // the hit tracks are muted so they get none; stride 5 spreads them
    #expect(
      c.panels.map(\.id) == [
        "A/melody-0", "A/hihat-0", "A/snare", "A/kick-0", "A/harmony", "A/bass-0",
      ])
    #expect(c.panels.map(\.label) == ["melody", "hihat", "drums", "kick", "dark-pad", "bass"])
    #expect(c.panels.map(\.channel) == [4, 12, 11, 10, 7, 6])
    #expect(c.panels.allSatisfy { $0.deck == "A" && $0.ring != nil })
    #expect(c.hasNet && c.source == .deck("A") && c.epoch == 1)
  }

  @Test func theContextCarriesTheFeedOfTheSource() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.2)
    #expect(h.ctx.feed === h.rig.hub.feed(.deck("A")), "layers that need audio read it from here")
    #expect(h.ctx.feed?.isActive == true && h.ctx.feed?.history.count ?? 0 > 0)
    h.model.settings.source = .master
    h.run(0.1)
    #expect(h.ctx.feed === h.rig.hub.feed(.master))
  }

  @Test func theRingIsLaidOutByLayoutRing() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.2)
    let c = h.ctx
    let want = StagePanelLayout.layoutRing(width: 1000, height: 800, count: 6)
    #expect(c.layout == want)
    for (i, p) in c.panels.enumerated() {
      #expect(p.center == want.panelCenters[i] && p.ring == want.panelCenters[i])
      #expect(p.side == want.side)
    }
    #expect(
      c.ringCenter == StagePoint(x: 500, y: 400) && c.darkPlanetRadius == want.darkPlanetRadius)
    // each panel carries its net's geometry and a fitted view
    for p in c.panels {
      #expect(p.shape.placeIds.count > 0 && p.shape.transitionIds.count > 0)
      #expect(p.view != nil && p.shape.arcs.count > 0)
      #expect(p.tokens.count == p.shape.placeIds.count)
      #expect(p.firedAt.count == p.shape.transitionIds.count)
    }
  }

  @Test func theShapeIsTheComposersRingLayout() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.1)
    let project = scopeProject("techno", seed: 42, structure: "standard")
    let kick = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
    let net = try #require(project.nets["kick-0"])
    // places p0..p15 at 0.7r, transitions t0..t15 at r (i + 0.5)/n: the project's own numbers
    for (i, id) in kick.shape.placeIds.enumerated() {
      let p = try #require(net.places[id])
      #expect(stageNear(kick.shape.placeX[i], p.x) && stageNear(kick.shape.placeY[i], p.y))
    }
    for (i, id) in kick.shape.transitionIds.enumerated() {
      let t = try #require(net.transitions[id])
      #expect(
        stageNear(kick.shape.transitionX[i], t.x) && stageNear(kick.shape.transitionY[i], t.y))
      #expect(kick.shape.transitionHasMidi[i] == (net.bindings[id] != nil))
    }
    #expect(kick.shape.arcs.count == net.arcs.count && kick.shape.arcs.count == 32)
    // ring layout: n = 16 -> r = max(150, 16 * 70 / (2 pi 0.7)) = 254.65..., centre r + 80
    let r = 16 * 70 / (2 * 3.141592653589793 * 0.7)
    let cx = r + 80
    #expect(stageNear(kick.shape.placeX[0], cx + r * 0.7, 1e-9))
    #expect(stageNear(kick.shape.placeY[0], cx, 1e-9))
    // the bounding box is the places' and transitions' box
    let b = try #require(kick.shape.bounds)
    #expect(b.minX < cx && b.maxX > cx && stageNear((b.minX + b.maxX) / 2, cx, 1.0))
  }

  @Test func controlNetsKeepNoArcGeometryButStillCountTheirArcs() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.1)
    let layout = try #require(h.rig.hub.feed(.deck("A")).marking()?.layout)
    let control = layout.nets.filter { $0.role == "control" }
    let music = layout.nets.filter { $0.role != "control" }
    #expect(control.count > 10 && music.count == 40)
    // The stage never draws a control net, and two thirds of a techno song's arcs are theirs: the
    // layout (kept 8 times per deck) holds geometry for the music nets only.
    #expect(control.allSatisfy { $0.arcs.isEmpty }, "no geometry kept for control nets")
    #expect(control.reduce(0) { $0 + $1.arcCount } > 8000, "but the count is still known")
    #expect(music.allSatisfy { $0.arcs.count == $0.arcCount && $0.arcCount > 0 })
    #expect(music.reduce(0) { $0 + $1.arcs.count } == 4224, "the stats line's 4224 arcs")
  }

  @Test func liveTokensComeFromTheEnginesMarking() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    func tokenPlace() throws -> Int {
      let kick = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
      #expect(stageNear(kick.tokens.reduce(0, +), 1), "a ring has exactly one token")
      return try #require(kick.tokens.firstIndex { $0 > 0 })
    }
    let a = try tokenPlace()
    h.run(0.2)  // four steps at 300 BPM
    let b = try tokenPlace()
    #expect(a != b, "the token moved with the net clock (\(a) -> \(b))")
    // and it is the engine's own number
    let snapshot = try #require(h.rig.hub.feed(.deck("A")).marking())
    let layout = try #require(snapshot.layout)
    let n = try #require(layout.netIds.firstIndex(of: "kick-0"))
    let kick = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
    #expect(Array(snapshot.tokens(ofNet: n)) == kick.tokens)
  }

  @Test func everyFireReachesItsPanelWithItsPosition() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(3)
    var seen = 0
    for c in h.frames {
      for f in c.fires {
        seen += 1
        #expect(f.deck == "A" && f.note >= 0 && f.note <= 127)
        #expect(f.velocity >= 1 && f.velocity <= 127 && f.durSec > 0)
        #expect(f.time <= c.audioNow, "no fire after now")
        let panel = c.panels.firstIndex { $0.netId == f.netId }
        #expect(f.panel == panel, "\(f.netId) -> panel")
        if let p = f.panel {
          let t = try #require(f.transition)
          #expect(c.panels[p].shape.transitionIds[t] == f.transitionId)
          let origin = try #require(f.origin)
          #expect(origin == c.panels[p].nodeCenterInStage(transition: t))
          // and it is inside the stage
          #expect(origin.x > 0 && origin.x < 1000 && origin.y > 0 && origin.y < 800)
        }
        #expect(f.wallTime <= c.now && f.wallTime > c.now - 0.5)
      }
    }
    #expect(seen > 20, "the song fires (\(seen))")
    // kick and hihat are the audible nets at the start
    let ids = Set(h.frames.flatMap(\.fires).map(\.netId))
    #expect(ids.contains("kick-0") && ids.contains("hihat-0"))
  }

  @Test func aFiredTransitionFlashesForAHundredMilliseconds() throws {
    let h = try StageHarness()
    defer { h.stop() }
    var found: (panel: Int, transition: Int, time: Double)?
    var guardFrames = 0
    while found == nil, guardFrames < 100 {
      h.step()
      guardFrames += 1
      if let f = h.ctx.fires.first(where: { $0.panel != nil }) {
        found = (f.panel!, f.transition!, f.time)
      }
    }
    let hit = try #require(found)
    func flash() -> Double {
      h.ctx.panels[hit.panel].flash(transition: hit.transition, now: h.ctx.audioNow)
    }
    #expect(flash() > 0.5, "lit right after the fire (\(flash()))")
    let nowAtFire = h.ctx.audioNow
    h.step()  // 50 ms later: still lit (a ring cannot fire the same transition twice in 50 ms)
    #expect(h.ctx.audioNow > nowAtFire)
    #expect(h.ctx.panels[hit.panel].firedAt[hit.transition] == hit.time)
    #expect(flash() > 0 && flash() < 1, "fading (\(flash()))")
    h.step(3)  // 200 ms after the fire
    #expect(h.ctx.panels[hit.panel].firedAt[hit.transition] == hit.time)
    #expect(flash() == 0, "dark again 200 ms later")
  }

  @Test func flashesAreKeptPerTransitionNotPerPanel() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(1.6)
    // some panel has fired more than one distinct transition by now
    let kick = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
    let fired = kick.firedAt.filter { $0 > -.infinity }
    #expect(fired.count >= 2, "distinct transitions remember their own fire time")
    #expect(Set(fired).count == fired.count)
  }

  @Test func mutedPanelsDimButNeverReflow() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    let before = h.ctx.panels.map(\.center)
    let epoch = h.ctx.epoch
    let kick0 = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
    #expect(!kick0.muted && kick0.opacity == 1)
    let bass = try #require(h.ctx.panels.first { $0.id == "A/bass-0" })
    #expect(bass.muted && bass.opacity == StageFade.mutedOpacity, "built muted: dimmed at once")
    h.deck.wave.setMute("kick-0", true)
    h.step()  // the mute lands in the next block
    h.step()
    let dimming = try #require(h.ctx.panels.first { $0.id == "A/kick-0" })
    #expect(dimming.muted && dimming.opacity < 1 && dimming.opacity > StageFade.mutedOpacity)
    h.run(0.4)
    let dim = try #require(h.ctx.panels.first { $0.id == "A/kick-0" })
    #expect(dim.muted && stageNear(dim.opacity, StageFade.mutedOpacity))
    #expect(h.ctx.panels.map(\.center) == before, "no reflow")
    #expect(h.ctx.epoch == epoch, "no rebuild")
    h.deck.wave.setMute("kick-0", false)
    h.run(0.5)
    let lit = try #require(h.ctx.panels.first { $0.id == "A/kick-0" })
    #expect(!lit.muted && stageNear(lit.opacity, 1))
  }

  @Test func aCollapsedPanelFlipsToTheUnmutedVariant() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    let bassIndex = try #require(h.ctx.panels.firstIndex { $0.id == "A/bass-0" })
    let before = h.ctx.panels[bassIndex]
    #expect(before.netId == "bass-0" && before.riffGroup == "bass")
    let epoch = h.ctx.epoch
    // the arrangement hands over from slot A to slot B: bass-3 becomes the unmuted variant
    h.deck.wave.setMute("bass-3", false)
    h.run(0.1)
    let after = h.ctx.panels[bassIndex]
    #expect(after.id == "A/bass-0", "the panel keeps its slot")
    #expect(after.netId == "bass-3" && !after.muted)
    #expect(after.label == "bass" && after.shape.netId == "bass-3")
    #expect(after.center == before.center, "same place in the ring")
    #expect(h.ctx.epoch == epoch, "a flip is not a rebuild")
    #expect(after.firedAt.count == after.shape.transitionIds.count)
    // and the flip follows the first unmuted variant, in project order
    h.deck.wave.setMute("bass-1", false)
    h.run(0.1)
    #expect(h.ctx.panels[bassIndex].netId == "bass-1")
  }

  @Test func switchingTheSourceRebuildsWithoutTurning() throws {
    let h = try StageHarness(net: ["A", "B"], source: .deck("A"))
    defer { h.stop() }
    h.run(0.3)
    let epoch = h.ctx.epoch
    #expect(h.ctx.panels.allSatisfy { $0.deck == "A" })
    h.model.settings.source = .master
    h.run(0.2)
    let c = h.ctx
    // both net decks' panels: ids carry the deck
    #expect(c.panels.contains { $0.deck == "A" } && c.panels.contains { $0.deck == "B" })
    #expect(Set(c.panels.map(\.id)).count == c.panels.count)
    #expect(c.panels.allSatisfy { $0.id.hasPrefix("\($0.deck)/") })
    // and the feeds follow: A's tap is still on (master listens to both decks' events)
    h.model.settings.source = .deck("B")
    h.run(0.2)
    #expect(h.ctx.panels.allSatisfy { $0.deck == "B" } && h.ctx.panels.count > 0)
  }

  @Test func aSampleDeckHasNoPanelsAndSaysSo() throws {
    let h = try StageHarness(net: ["A"], samples: ["B"], source: .deck("B"))
    defer { h.stop() }
    h.run(0.3)
    #expect(h.ctx.panels.isEmpty && !h.ctx.hasNet)
    #expect(h.ctx.stats == "0 bars · 0/0 nets · 0 places · 0 transitions · 0 arcs · 0 notes")
    #expect(h.ctx.layout.panelCenters.isEmpty && h.ctx.fires.isEmpty)
  }

  @Test func theMasterShowsBothDecksAndTheirFires() throws {
    let h = try StageHarness(net: ["A", "B"], source: .master)
    defer { h.stop() }
    h.run(2)
    #expect(Set(h.ctx.panels.map(\.deck)) == ["A", "B"])
    let fires = h.frames.flatMap(\.fires)
    #expect(Set(fires.map(\.deck)) == ["A", "B"], "fires of both decks reach the stage")
    for c in h.frames {
      for f in c.fires {
        let panel = try #require(f.panel)
        #expect(c.panels[panel].deck == f.deck)
      }
    }
  }

  @Test func theStatsLineCountsTheProjectsNets() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.1)
    let project = scopeProject("techno", seed: 42, structure: "standard")
    var nets = 0
    var places = 0
    var transitions = 0
    var arcs = 0
    var notes = 0
    var muted = 0
    for (id, net) in project.nets.pairs where net.role != "control" {
      if net.places.count == 0 || net.transitions.count == 0 { continue }
      nets += 1
      places += net.places.count
      transitions += net.transitions.count
      arcs += net.arcs.count
      notes += net.bindings.count
      if project.initialMutes.contains(id) { muted += 1 }
    }
    let bars = project.bars ?? 0
    let want =
      "\(bars) bars · \(nets - muted)/\(nets) nets · \(places) places · \(transitions) transitions · \(arcs) arcs · \(notes) notes"
    #expect(h.ctx.stats == want)
    #expect(bars == 56 && nets == 40)
  }

  @Test func hitTracksAppearOnlyWhenTheyAreUnmutedAtABuild() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.2)
    #expect(!h.ctx.panels.contains { $0.netId.hasPrefix("hit") })
    // unmuting one does not add a panel: panels are not torn down on a mute
    h.deck.wave.setMute("hit1", false)
    h.run(0.2)
    #expect(!h.ctx.panels.contains { $0.netId.hasPrefix("hit") })
    // a rebuild (the expand toggle) takes it in
    h.model.settings.expandVariants = true
    h.run(0.1)
    #expect(h.ctx.panels.contains { $0.netId == "hit1" })
    #expect(!h.ctx.panels.contains { $0.netId == "hit2" })
  }

  @Test func aStingerFiresEvenThoughItsNetHasNoPanel() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.2)
    h.deck.wave.fireStinger("hit1", ticks: 16)
    h.run(0.6)
    let fires = h.frames.flatMap(\.fires).filter { $0.netId == "hit1" }
    #expect(fires.count > 0, "the stinger sounds")
    #expect(fires.allSatisfy { $0.panel == nil && $0.origin == nil && $0.transition == nil })
    #expect(fires.allSatisfy { $0.isStinger })
  }

  @Test func firesDuringAMacroSayso() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    #expect(!h.frames.flatMap(\.fires).contains { $0.macroRunning })
    h.deck.wave.fire(.beatRepeat)
    h.run(0.8)
    #expect(h.ctx.macroRunning || h.frames.suffix(8).contains { $0.macroRunning })
    #expect(h.frames.flatMap(\.fires).contains { $0.macroRunning }, "fires carry the macro flag")
  }

  @Test func theMinimalVisualLevelSkipsFireEffects() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.rig.hub.vizLevel = 2
    h.run(1)
    #expect(h.frames.allSatisfy { $0.fires.isEmpty && $0.vizLevel == 2 })
    let kick = try #require(h.ctx.panels.first { $0.netId == "kick-0" })
    #expect(kick.firedAt.allSatisfy { $0 == -.infinity }, "nothing flashes either")
    #expect(h.model.minFrameInterval == StageFramePacer.minInterval(level: 2))
    h.rig.hub.vizLevel = 0
    h.run(0.5)
    #expect(h.frames.suffix(10).contains { !$0.fires.isEmpty })
  }

  @Test func firesOlderThanTwoSecondsAreDropped() throws {
    let h = try StageHarness()
    defer { h.stop() }
    #expect(StageModel.staleFireSeconds == 2.0)
    // render 2.5 s with the model asleep, then wake it: the backlog is not replayed
    h.rig.hub.pump()
    h.rig.render(frames: StageHarness.block * 50)  // 2.5 s
    h.model.advance(now: 200, dt: 0.05, width: 1000, height: 800)
    let c = h.model.context
    let ages = c.fires.map { c.audioNow - $0.time }
    #expect(ages.allSatisfy { $0 <= 2.0 }, "nothing older than 2 s: \(ages.max() ?? 0)")
    #expect(ages.contains { $0 > 1.5 }, "but the fires of the last two seconds are kept")
    #expect(c.fires.count < 60)
  }

  @Test func theLayerModelsAreAdvancedEveryFrameAndClearedOnARebuild() throws {
    let h = try StageHarness()
    defer { h.stop() }
    let spy = SpyLayer()
    h.model.observers = [spy]
    h.run(0.2)
    #expect(spy.advances == 4 && spy.resets == 1, "the first build clears too")
    #expect(spy.last?.panels.count == 6 && spy.last?.epoch == h.ctx.epoch)
    h.model.settings.expandVariants = true
    h.run(0.05)
    #expect(spy.resets == 2, "a rebuild clears per-panel state")
    #expect(h.model.layers.all.count == 10 && h.model.layers.clearedOnRebuild.count == 3)
  }

  @Test func theSoloModelDecidesWhatShows() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.1)
    #expect(h.ctx.visualizer == .constellation && !h.ctx.isSolo)
    h.model.settings.visualizer = .sonar
    h.run(0.05)
    #expect(h.ctx.visualizer == .sonar && h.ctx.selection == .sonar && h.ctx.isSolo)
    h.model.settings.visualizer = .shuffle
    h.run(0.05)
    #expect(h.ctx.selection == .shuffle && h.ctx.visualizer != .shuffle, "never shuffle itself")
    #expect(StageVisualizer.allCases.count == 7 && StageVisualizer.real.count == 6)
    #expect(StageVisualizer.constellation.rawValue == "mandala")
    #expect(!StageVisualizer.constellation.isSolo && !StageVisualizer.shuffle.isSolo)
    #expect(
      StageVisualizer.corona.isSolo && StageVisualizer.sonar.isSolo && StageVisualizer.petal.isSolo
        && StageVisualizer.minecraft.isSolo && StageVisualizer.dig.isSolo)
  }

  @Test func detachingSwitchesTheTapsOff() throws {
    let h = try StageHarness()
    h.run(0.1)
    #expect(h.deck.tap.isEnabled)
    h.model.detach()
    #expect(!h.deck.tap.isEnabled && !h.model.isAttached)
    h.model.detach()  // safe to repeat
    h.rig.stop()
  }

  @Test func theHostEntryDrawsOncePerTimelineDate() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.rig.render(frames: StageHarness.block)
    let a = h.model.frame(now: 500, width: 1000, height: 800)
    h.rig.render(frames: StageHarness.block)
    let b = h.model.frame(now: 500, width: 1000, height: 800)
    #expect(b.audioNow == a.audioNow, "the same date: the same frame")
    let c = h.model.frame(now: 500.05, width: 1000, height: 800)
    #expect(c.audioNow > a.audioNow && stageNear(c.dt, 0.05, 1e-9))
    let d = h.model.frame(now: 510, width: 1000, height: 800)
    #expect(stageNear(d.dt, 0.1), "dt is clamped to 100 ms like the rAF loop")
    let e = h.model.frame(now: 510, width: 800, height: 600)
    #expect(e.layout.width == 800, "a new size is a new frame")
  }
}
