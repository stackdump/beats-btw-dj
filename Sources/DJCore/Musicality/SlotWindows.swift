import Foundation

/// A stretch of one section during which one slot net of a role plays: the bars a slot's
/// rewrite reaches (`DJMusicality.slotWindows`).
public struct SlotWindow: Equatable, Sendable {
  /// Index into `Project.structure`.
  public var section: Int
  public var sectionName: String
  /// Index into the section's `phrases[role]`: the phrase `start` falls in.
  public var phrase: Int
  /// Song steps (sixteenths from 0), `end` exclusive.
  public var start: Int
  public var end: Int
  /// The step of the net's ring cycle it plays at `start` (its marked `p<i>` then); nil for a
  /// net that isn't a one-token ring.
  public var ringStart: Int?
  /// The ring's length in steps (its `p<i>` places), nil with `ringStart`.
  public var ringLength: Int?
}

extension DJMusicality {
  /// Which slot net of `role` (the nets whose `riffGroup` is `role`: `melody-0`…, or `melody`
  /// when it has one slot) plays which steps of which section, keyed by net. Read-only; a pure
  /// function of the project, measured on the project as given (composed or `played`).
  ///
  /// From `NoteLog.captureAll`'s part changes (slot switches, mutes) replayed over the
  /// initial mutes, cut at every section start, every phrase start of the role, and every
  /// change. The phrase grid is `phraseLengths` (the `.phrases` fix) when every change in the
  /// section sits on it, else the even split beats composes. A section where the role is
  /// silent has no window; where it plays, its windows tile the section. In `played` every
  /// change is on a bar (`.timing`), so every window starts on one; in a composed track the
  /// changes land a tick or more late (`.timing` says why), so a window can start a few
  /// ticks past its bar and the outgoing slot keeps those ticks.
  ///
  /// `ringStart` is `(initial marking + start) mod ringLength`: a ring takes one step a tick
  /// from the song's first, muted or not — rings keep song time, not window time — so a
  /// switch's `PartChange.phase` is the same number (both checked against a simulation).
  ///
  /// Cost: one `captureAll` of only the control nets acting on the role (`partOnly`), not the
  /// song's ~3000 transitions a tick. On a 307 s song (reggae, extended, 1536 steps): 2.8 ms
  /// in release, 0.24 s in a debug build (≈ 10 s debug with every net simulated); linear in
  /// length.
  ///
  /// Spike (6.4): bars 5–8 of an 8-bar section (`A B`, or `C C`: beats gives every phrase its
  /// own slot net) are always a different net from bars 1–4. Both start at ringStart 0 where
  /// the ring is 4 bars (edm extended's buildups, bridge, outro); an 8-bar ring (its
  /// breakdown, starting on an odd 4-bar boundary of the song) gives 64 then 0 — bars 1–4
  /// play the second half of their ring. A 2-bar phrase (the last of a 12-bar `A A B B` drop,
  /// `phraseLengths` 4 + 4 + 2 + 2) starts at ringStart 32. So a slot rewrite needs no runner
  /// fallback, but must work on the ring steps the window covers (`ringStart ..< ringStart +
  /// end - start`, mod `ringLength`), not assume 0.
  public static func slotWindows(_ project: Project, role: String) -> [String: [SlotWindow]] {
    windows(
      project, role: role,
      nets: project.nets.pairs.filter {
        $0.value.riffGroup == role && $0.value.role != "control"
      })
  }

  /// The windows of one net that isn't a slot net (no `riffGroup`: a single `harmony` pad, a
  /// `snare`), keyed by its id: where its mutes / unmutes leave it playing, by `role`'s phrase
  /// grid (its id when it has no phrases). `slotWindows` never returns these, so the passes
  /// that rewrite slots don't see them.
  static func netWindows(_ project: Project, net id: String) -> [SlotWindow] {
    guard let nb = project.nets[id], nb.role != "control" else { return [] }
    return windows(project, role: id, nets: [(key: id, value: nb)])[id] ?? []
  }

  private static func windows(
    _ project: Project, role: String, nets: [(key: String, value: NetBundle)]
  ) -> [String: [SlotWindow]] {
    guard !nets.isEmpty, !project.structure.isEmpty else { return [:] }
    let ids = Set(nets.map(\.key))
    let rings: [String: (at: Int, count: Int)] = Dictionary(
      uniqueKeysWithValues: nets.compactMap { id, nb in ringShape(nb).map { (id, $0) } })

    // The role's changes, as (step from which they hold, net playing or nil). A change's
    // `tick` counts from 1 and section starts are steps from 0: compare on `PartChange.step`,
    // from the song's net order (`partOnly` ran without the targets, so its own `step` is the
    // tick). A control net before its target acts on the tick it fires (its step tick − 1:
    // a mute on a section's first step leaves the section silent); after it (beats' order),
    // from the next.
    let order = Dictionary(
      uniqueKeysWithValues: project.nets.keys.enumerated().map { ($1, $0) })
    let muted = Set(project.initialMutes)
    let initial = nets.first { !muted.contains($0.key) }?.key
    var playing = initial
    var changes: [(step: Int, net: String?)] = []
    for c in NoteLog.captureAll(partOnly(project, ids), ticks: NoteLog.length(project)).controls
    where ids.contains(c.target) {
      switch c.action {
      case .slot, .unmute: playing = c.target
      case .mute: if playing == c.target { playing = nil }
      case .toggle: playing = playing == c.target ? nil : c.target
      default: continue
      }
      let step = PartChange.actingStep(
        tick: c.tick, control: order[c.net] ?? Int.max, target: order[c.target])
      changes.append((step, playing))
    }

    var out: [String: [SlotWindow]] = [:]
    var sectionStart = 0
    var k = 0  // next change
    var current = initial
    for (si, s) in project.structure.enumerated() {
      let end = sectionStart + s.steps
      defer { sectionStart = end }
      let count = max(1, s.phrases[role]?.count ?? 1)
      let inside = changes.map(\.step).filter { $0 > sectionStart && $0 < end }
      let aligned = phraseStarts(sectionStart, phraseLengths(steps: s.steps, count: count))
      let even = phraseStarts(
        sectionStart, [Int](repeating: s.steps / count, count: count))
      // A change sits on a grid when it's at most the boundary stagger after a phrase start.
      func fits(_ grid: [Int]) -> Bool {
        inside.allSatisfy { c in grid.contains { c - $0 >= 0 && c - $0 <= boundaryStagger + 1 } }
      }
      let grid = fits(aligned) || !fits(even) ? aligned : even
      var cuts = Set(grid.filter { $0 >= sectionStart && $0 < end })
      cuts.insert(sectionStart)
      for c in inside { cuts.insert(c) }
      let starts = cuts.sorted()
      for (i, a) in starts.enumerated() {
        while k < changes.count && changes[k].step <= a {
          current = changes[k].net
          k += 1
        }
        guard let net = current else { continue }
        let b = i + 1 < starts.count ? starts[i + 1] : end
        let phrase = grid.lastIndex { $0 <= a } ?? 0
        let ring = rings[net].map { ($0.at + a) % $0.count }
        let w = SlotWindow(
          section: si, sectionName: s.name, phrase: phrase, start: a, end: b, ringStart: ring,
          ringLength: rings[net]?.count)
        // A change inside a phrase that keeps the same net (a re-sent slot) joins its window.
        if var last = out[net]?.last, last.end == a, last.section == si, last.phrase == phrase {
          last.end = b
          out[net]![out[net]!.count - 1] = last
        } else {
          out[net, default: []].append(w)
        }
      }
    }
    return out
  }

  /// `project` with only the control nets that act on the nets `ids`: their part changes are
  /// the same as in the whole song (control nets are independent sink chains, and conflicts
  /// resolve by tick and place), without the `phase` (the slot nets aren't there; `ringStart`
  /// doesn't need it), and the simulation skips every music net (a 300 s song is ~3000
  /// transitions a tick; `struct-melody` alone is a few dozen).
  static func partOnly(_ project: Project, _ ids: Set<String>) -> Project {
    var p = project
    p.nets = OrderedMap()
    for (id, nb) in project.nets.pairs
    where nb.controlBindings.values.contains(where: { ids.contains($0.targetNet) }) {
      p.nets[id] = nb
    }
    p.initialMutes = []
    return p
  }

  /// Start steps of phrases of `lengths` from `start`.
  private static func phraseStarts(_ start: Int, _ lengths: [Int]) -> [Int] {
    var t = start
    return lengths.map { l in
      defer { t += l }
      return t
    }
  }

  /// A one-token ring of places `p0`…`pN-1`: where its token starts and N.
  private static func ringShape(_ nb: NetBundle) -> (at: Int, count: Int)? {
    var at: Int?
    var count = 0
    for (id, place) in nb.places.pairs {
      guard id.hasPrefix("p"), let i = Int(id.dropFirst()) else { return nil }
      count = max(count, i + 1)
      if (place.initial.first ?? 0) > 0 {
        guard at == nil else { return nil }
        at = i
      }
    }
    guard let at, count > 0, count == nb.places.count else { return nil }
    return (at, count)
  }
}
