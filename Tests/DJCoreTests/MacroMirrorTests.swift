import Testing

@testable import DJCore

// SPEC mode 26, engine side: the audio thread publishes which macros are in effect and which
// nets they hold muted; the main thread reads it. Everything here drives a bare `WaveDeckSource`
// block by block, the way the deck's source node does.

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

private func project(_ genre: String, _ seed: Double, _ structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// A source at 300 BPM (a tick every 50 ms, 1102.5 frames at 22.05 kHz), playing.
private func makeSource(_ p: Project, tempo: Double = 300, rate: Double = 22_050) -> WaveDeckSource
{
  let src = WaveDeckSource(sampleRate: rate)
  src.load(WaveRunner.prepare(p, sampleRate: rate))
  src.setTempo(tempo)
  src.play()
  return src
}

private let roleNames = ["kick", "snare", "hihat", "clap", "bass", "melody", "harmony", "arp"]

/// The roles of this song, in mixer order.
private func roles(_ src: WaveDeckSource) -> [String] {
  roleNames.filter { src.latest?.graph.roleTargets[strHash($0)] != nil }
}

/// Drives `src` block by block and remembers what it saw.
private final class Driver {
  let src: WaveDeckSource
  var frame = 0
  private var l = [Float](repeating: 0, count: 128)
  private var r = [Float](repeating: 0, count: 128)
  init(_ src: WaveDeckSource) { self.src = src }

  @discardableResult
  func run(blocks: Int, each: (() -> Void)? = nil) -> Int {
    for _ in 0..<blocks {
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          src.render(frames: 128, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: frame)
        }
      }
      frame += 128
      each?()
    }
    return frame
  }
}

struct MacroMirrorTests {
  @Test func aMuteMacroIsInEffectUntilItsRestore() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    #expect(src.activeMacros.isEmpty && !src.isMacroActive)
    #expect(src.rolesHeldByMacros(roles(src)).isEmpty)
    let audible = roles(src).filter { src.isRoleAudible($0) }
    src.fire(.drop, ticks: 16)  // 16 ticks = 800 ms = ~138 blocks
    d.run(blocks: 3)
    #expect(src.activeMacros == [.drop] && src.isActive(.drop) && !src.isActive(.cut))
    // the non-drum roles that were sounding are the ones held; the drums are not
    let held = src.rolesHeldByMacros(roles(src))
    #expect(held == audible.filter { !["kick", "snare", "hihat", "clap"].contains($0) })
    #expect(held.count >= 3, "techno has bass, melody, harmony...: \(held)")
    #expect(src.rolesHeld(by: .drop, among: roles(src)) == held, "all of it is the drop's")
    #expect(src.rolesHeld(by: .breakdown, among: roles(src)).isEmpty, "none of it is another's")
    d.run(blocks: 100)
    #expect(src.isActive(.drop), "still held at 600 ms")
    d.run(blocks: 60)
    #expect(src.activeMacros.isEmpty, "restored on the 16th tick")
    #expect(src.rolesHeldByMacros(roles(src)).isEmpty)
    #expect(roles(src).filter { src.isRoleAudible($0) } == audible, "and the roles are back")
  }

  @Test func eachMacroHoldsTheRolesItsSelectorPicks() {
    let all = ["kick", "snare", "hihat", "clap", "bass", "melody", "harmony", "arp"]
    let drums = Set(["kick", "snare", "hihat", "clap"])
    let cases: [(NetMacro, ticks: Int, expect: (String) -> Bool)] = [
      (.breakdown, 16, { drums.contains($0) }),
      (.soloDrums, 16, { !drums.contains($0) }),
      (.cut, 8, { _ in true }),
    ]
    for (macro, ticks, expect) in cases {
      let src = makeSource(project("techno", 42))
      let d = Driver(src)
      d.run(blocks: 50)
      let audible = all.filter { src.latest?.graph.roleTargets[strHash($0)] != nil }.filter {
        src.isRoleAudible($0)
      }
      src.fire(macro, ticks: ticks)
      d.run(blocks: 3)
      #expect(src.activeMacros == [macro], "\(macro)")
      #expect(
        src.rolesHeldByMacros(roles(src)) == audible.filter(expect),
        "\(macro): \(src.rolesHeldByMacros(roles(src)))")
      d.run(blocks: 400)
      #expect(src.activeMacros.isEmpty, "\(macro) ends")
    }
  }

  @Test func aRoleSomeoneMutedIsNotHeldByTheMacro() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.setRoleMuted("bass", true)
    d.run(blocks: 3)
    src.fire(.drop, ticks: 8)
    d.run(blocks: 3)
    let held = src.rolesHeldByMacros(roles(src))
    #expect(!held.contains("bass") && held.contains("melody"), "\(held)")
  }

  @Test func aRoleThePerformerSwitchesBackOnIsNoLongerHeld() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.drop, ticks: 32)
    d.run(blocks: 3)
    let held = src.rolesHeld(by: .drop, among: roles(src))
    #expect(held.contains("bass") && held.contains("melody"))
    src.setRoleMuted("bass", false)  // back on, mid-drop
    d.run(blocks: 3)
    let after = src.rolesHeld(by: .drop, among: roles(src))
    #expect(after == held.filter { $0 != "bass" }, "the bass is audible again: \(after)")
    #expect(src.isActive(.drop), "the macro itself is still running")
    #expect(src.isRoleAudible("bass"))
  }

  @Test func theBeatRepeatCountsWhileItRunsEvenBetweenBursts() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.beatRepeat, ticks: 32)  // 1.6 s = ~275 blocks
    var seenHeld = 0
    var seenFree = 0
    var kickHeld = false
    var always = true
    d.run(blocks: 240) {
      always = always && src.isActive(.beatRepeat)
      if src.rolesHeldByMacros(roles(src)).isEmpty { seenFree += 1 } else { seenHeld += 1 }
      kickHeld = kickHeld || src.rolesHeldByMacros(roles(src)).contains("kick")
    }
    #expect(always, "in effect for the whole run")
    #expect(
      seenHeld > 20 && seenFree > 20, "bursts hold nets and gaps do not: \(seenHeld)/\(seenFree)")
    #expect(!kickHeld, "the kick keeps its pulse")
    d.run(blocks: 200)
    #expect(src.activeMacros.isEmpty)
  }

  @Test func theDoubleDropNeverLeavesTheMirrorBetweenItsHalves() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.doubleDrop, ticks: 8)  // cut for 2 ticks, then a drop 5 ticks in (260 ms) for 8
    var active: [Bool] = []
    var heldCounts: [Int] = []
    d.run(blocks: 400) {
      active.append(src.isActive(.doubleDrop))
      heldCounts.append(src.rolesHeldByMacros(roles(src)).count)
    }
    let first = active.firstIndex(of: true)
    let last = active.lastIndex(of: true)
    #expect(first != nil && last != nil)
    guard let first, let last else { return }
    #expect(first <= 1, "in effect from the block after the fire")
    #expect(
      active[first...last].allSatisfy { $0 }, "no gap while the second half waits on its timer")
    // 2 ticks of cut + 3 of waiting + 8 of drop = ~13 ticks = 650 ms = ~112 blocks
    #expect(last - first > 90 && last - first < 140, "ran \(last - first) blocks")
    // the wait is a stretch with nothing held, between a cut that held more and a drop that held less
    let peak = heldCounts[first]
    let waitingCount = heldCounts[first...last].filter { $0 == 0 }.count
    #expect(waitingCount > 10, "the gap between the halves holds no role: \(waitingCount) blocks")
    #expect(
      peak > (heldCounts[first...last].last { $0 > 0 } ?? 0), "cut holds more than drop: \(peak)")
    d.run(blocks: 100)
    #expect(src.activeMacros.isEmpty)
  }

  @Test func tempoMacrosAreInEffectButHoldNoRole() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.halfTime, ticks: 8)
    d.run(blocks: 3)
    #expect(src.activeMacros == [.halfTime])
    #expect(src.rolesHeldByMacros(roles(src)).isEmpty, "a tempo macro mutes nothing")
    src.fire(.tapeStop, ticks: 8)  // stacked on the first
    d.run(blocks: 3)
    #expect(src.activeMacros == [.halfTime, .tapeStop])
    src.panic()
    d.run(blocks: 3)
    #expect(src.activeMacros.isEmpty, "panic ends them")
  }

  @Test func panicClearsEveryMacroAndEveryHeldNet() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.drop, ticks: 64)
    src.fire(.beatRepeat, ticks: 64)
    d.run(blocks: 5)
    #expect(src.activeMacros.count == 2)
    #expect(!src.rolesHeldByMacros(roles(src)).isEmpty)
    src.panic()
    d.run(blocks: 3)
    #expect(src.activeMacros.isEmpty && src.rolesHeldByMacros(roles(src)).isEmpty)
  }

  @Test func aMacroFiredOverAnotherChasesOnlyWhatItMutedItself() {
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    let drums = Set(["kick", "snare", "hihat", "clap"])
    let audible = roles(src).filter { src.isRoleAudible($0) }
    src.fire(.drop, ticks: 24)  // holds the non-drums
    src.fire(.cut, ticks: 8)  // finds only the drums still sounding
    d.run(blocks: 3)
    #expect(src.activeMacros == [.drop, .cut])
    let drop = src.rolesHeld(by: .drop, among: roles(src))
    let cut = src.rolesHeld(by: .cut, among: roles(src))
    #expect(drop == audible.filter { !drums.contains($0) } && !drop.isEmpty, "drop: \(drop)")
    #expect(cut == audible.filter { drums.contains($0) } && !cut.isEmpty, "cut: \(cut)")
    #expect(Set(drop).isDisjoint(with: cut), "two chases, no role in both")
    #expect(Set(src.rolesHeldByMacros(roles(src))) == Set(audible), "together they hold it all")
    // the cut ends first (8 ticks = 400 ms): the drop keeps what it had, the drums are back
    d.run(blocks: 80)
    #expect(src.activeMacros == [.drop], "cut over")
    #expect(src.rolesHeld(by: .drop, among: roles(src)) == drop)
    #expect(src.rolesHeld(by: .cut, among: roles(src)).isEmpty)
    #expect(audible.filter { drums.contains($0) }.allSatisfy { src.isRoleAudible($0) })
  }

  @Test func aHandOverWaitingForItsBarIsNotChasedThroughTheNewProjectsTables() {
    let rate = 22_050.0
    let src = makeSource(project("techno", 42))
    let d = Driver(src)
    d.run(blocks: 50)
    src.fire(.drop, ticks: 64)  // 3.2 s: it will still be running at the hand-over
    d.run(blocks: 3)
    let before = src.rolesHeld(by: .drop, among: roles(src))
    #expect(src.isActive(.drop) && !before.isEmpty)
    // a new song is handed over; it is installed at the next bar line (16 ticks = 0.8 s), and
    // until then the running graph is the old one
    src.load(WaveRunner.prepare(project("house", 7), sampleRate: rate))
    d.run(blocks: 3)
    #expect(src.isActive(.drop), "the old graph still runs its macro")
    #expect(
      src.rolesHeld(by: .drop, among: roles(src)).isEmpty,
      "its net numbers are not looked up in the new song's role table")
    // at the bar line the new song starts clean: no macro, nothing held, and the chase has gone
    d.run(blocks: 200)
    #expect(src.activeMacros.isEmpty)
    #expect(src.rolesHeldByMacros(roles(src)).isEmpty)
    // and a macro fired on the new song is chased by its own roles again
    src.fire(.drop, ticks: 16)
    d.run(blocks: 3)
    #expect(!src.rolesHeld(by: .drop, among: roles(src)).isEmpty)
  }

  @Test func theSelectorIsTheRuleFireMuteUses() {
    // `selects` is what `fireMute` mutes by: the nets muted equal the nets selected that were sounding
    for which in [MacroTargets.nonDrums, .drumsOnly, .everything, .nonKick] {
      let g = WaveGraph(project: project("techno", 42))
      let before = g.nets.map { g.muted[$0.index] != 0 }
      g.fireMute(which, ticks: 4)
      for n in g.nets {
        let muted = g.muted[n.index] != 0
        let expected = before[n.index] || g.selects(which, net: n.index)
        #expect(muted == expected, "\(which) net \(n.id)")
      }
      #expect(!g.nets.contains { g.isControlNet[$0.index] && g.selects(which, net: $0.index) })
    }
  }

  @Test func theTimerTagsRideThroughTheRestoreAndTheDelayedHalf() {
    let g = WaveGraph(project: project("techno", 42))
    func holders(_ s: MacroSnapshot, _ m: NetMacro? = nil) -> [CompiledNet] {
      g.nets.filter { n in m.map { s.isHeld(net: n.index, by: $0) } ?? s.isHeld(net: n.index) }
    }
    g.fireMute(.nonDrums, ticks: 2, macro: NetMacro.drop.tag)
    g.fireMute(.drumsOnly, ticks: 2)  // untagged: not a macro's
    var s = g.macroSnapshot()
    #expect(s.mask == NetMacro.drop.bit)
    let held = holders(s, .drop)
    #expect(!held.isEmpty && held.allSatisfy { !g.isDrumNet[$0.index] }, "only the tagged mutes")
    #expect(holders(s).count == held.count, "and nobody else holds anything")
    g.scheduleMute(.nonDrums, after: 4, ticks: 3, macro: NetMacro.doubleDrop.tag)
    s = g.macroSnapshot()
    #expect(s.mask == NetMacro.drop.bit | NetMacro.doubleDrop.bit, "the delayed half is tagged too")
    for _ in 0..<2 { g.advance() }  // the first drop restores; the delayed half is still waiting
    s = g.macroSnapshot()
    #expect(s.mask == NetMacro.doubleDrop.bit, "a waiting timer keeps its macro in effect")
    #expect(holders(s).isEmpty, "and holds nothing yet")
    for _ in 0..<2 { g.advance() }  // it fires: the tag rides on the mutes it makes
    s = g.macroSnapshot()
    #expect(s.mask == NetMacro.doubleDrop.bit)
    #expect(!holders(s, .doubleDrop).isEmpty && holders(s, .drop).isEmpty)
    for _ in 0..<3 { g.advance() }
    #expect(g.macroSnapshot().mask == 0 && g.pendingMacroTimers == 0)
  }

  @Test func aNetIsHeldByTheMacroThatMutedItAndByNoOther() {
    let g = WaveGraph(project: project("techno", 42))
    let silent = g.nets.map { g.muted[$0.index] != 0 }  // muted from the start (stingers...)
    g.fireMute(.nonDrums, ticks: 8, macro: NetMacro.drop.tag)
    // a cut over it: everything not yet muted, i.e. the drums only
    g.fireMute(.everything, ticks: 4, macro: NetMacro.cut.tag)
    let s = g.macroSnapshot()
    var ownedDrums = 0
    var ownedOthers = 0
    for n in g.nets where !g.isControlNet[n.index] {
      let drop = s.isHeld(net: n.index, by: .drop)
      let cut = s.isHeld(net: n.index, by: .cut)
      if silent[n.index] {
        #expect(!drop && !cut, "net \(n.id) was muted already: nobody's to restore")
        continue
      }
      if g.isDrumNet[n.index] { ownedDrums += 1 } else { ownedOthers += 1 }
      #expect(drop != cut, "net \(n.id) has exactly one owner")
      #expect(drop == !g.isDrumNet[n.index] && cut == g.isDrumNet[n.index], "net \(n.id)")
    }
    #expect(
      ownedDrums >= 1 && ownedOthers >= 1,
      "both macros muted something: \(ownedDrums)/\(ownedOthers)")
    #expect(s.mask == NetMacro.drop.bit | NetMacro.cut.bit)
    // the ownership words are the macro's own: another macro's slot is empty
    #expect(!g.nets.contains { s.isHeld(net: $0.index, by: .breakdown) })
  }

  @Test func theRecordCoversTheFirstTwoHundredFiftySixNetsAndOnlyThose() {
    var s = MacroSnapshot()
    s.hold(net: 0, slot: 0)
    s.hold(net: 255, slot: 8)
    s.hold(net: 256, slot: 0)  // past the table: ignored
    s.hold(net: -1, slot: 0)
    s.hold(net: 3, slot: 16)  // past the room for macros: ignored
    #expect(s.isHeld(net: 0, by: .drop) && s.isHeld(net: 255, by: .tempoAnchor))
    #expect(!s.isHeld(net: 256) && !s.isHeld(net: -1))
    #expect(!s.isHeld(net: 255, by: .drop) && !s.isHeld(net: 0, by: .tempoAnchor))
    #expect(!s.isHeld(net: 3))
    #expect(MacroSnapshot.capacity >= NetMacro.allCases.count)
  }

  @Test func theTagIsTheRawValuePlusOne() {
    for m in NetMacro.allCases {
      #expect(Int(m.tag) == Int(m.rawValue) + 1 && m.bit == 1 << UInt32(m.rawValue))
    }
    #expect(NetMacro.allCases.count <= 32, "the mask is 32 bits")
  }
}

struct MacroMirrorRealTimeTests {
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func publishingMacroStateOnTheAudioThreadDoesNotAllocate() {
    let src = makeSource(project("techno", 42), tempo: 480, rate: 48_000)
    let d = Driver(src)
    d.run(blocks: 200)  // warm up
    // every kind of macro at once: mute timers, a delayed half, the repeater, tempo effects
    src.fire(.drop, ticks: 24)
    src.fire(.beatRepeat, ticks: 24)
    src.fire(.doubleDrop, ticks: 8)
    src.fire(.tapeStop, ticks: 8)
    d.run(blocks: 2)  // the commands go through (outside the measured region)
    var tally = AllocationReport(allocations: 0, frees: 0)
    var seen = Set<NetMacro>()
    var maxHeld = 0
    for _ in 0..<60 {
      let r = countAllocations { d.run(blocks: 20) }
      tally.allocations += r.allocations
      tally.frees += r.frees
      seen.formUnion(src.activeMacros)
      maxHeld = max(maxHeld, (0..<64).filter { src.isNetHeldByMacro(index: $0) }.count)
    }
    #expect(tally.allocations == 0 && tally.frees == 0, "\(tally)")
    #expect(
      seen.isSuperset(of: [.drop, .beatRepeat, .doubleDrop, .tapeStop]),
      "the mirror carried every macro: \(seen)")
    #expect(maxHeld >= 3, "and held nets: \(maxHeld)")
    #expect(src.activeMacros.isEmpty, "all of them ran out inside the measured blocks")
  }
}

/// A writer thread publishes records in which every word, the mask and the generation all say
/// the same number; a reader checks that it never gets a mix of two of them.
struct MacroMirrorStressTests {
  @Test func aReaderNeverSeesHalfOfOneBlocksRecordAndHalfOfAnother() {
    let report = stressMacroMirror(publishes: 150_000)
    #expect(report.reads > 1000, "the reader got records: \(report.reads)")
    #expect(report.torn == 0, "torn reads: \(report.torn) of \(report.reads)")
    #expect(report.backwards == 0, "a later read returned an older record")
    #expect(report.changesSeen > 50, "and it saw the writer move: \(report.changesSeen)")
  }
}
