import Foundation

extension DJMusicality {
  /// `.layerBudget`: at most N melodic parts a section, the rest resting (p62-layer-budget).
  /// Its stretches of the deck's `RestSchedule` (`RestSchedule.build`); a pure function of the
  /// played project.
  ///
  /// beats' composer technique (`applyLayerBudget`) mutes the dropped roles' slots in the
  /// structure nets; this is the same rule, applied by the runner instead: per section, the
  /// melodic parts that play there (`slotWindows`) in `layerPriority` order, the first
  /// `autoLayerBudget[name]` (others 2) kept, the rest resting over the whole section. A rest
  /// drops a lane's hits, its nets keep running, so `NetSnapshot` and the visuals still show a
  /// rested part as playing. Parts are rest classes, not roles: roles that share a class
  /// (melody and lead; harmony, pad and chords) count once, at the place of the first.
  static func layerBudgetRests(_ project: Project) -> [RestSchedule.Entry] {
    let budgets = layerBudgets(project)
    var out: [RestSchedule.Entry] = []
    var start = 0
    for (i, s) in project.structure.enumerated() {
      defer { start += s.steps }
      let rested = budgets[i].rested
      guard !rested.isEmpty, s.steps > 0 else { continue }
      var mask: RestSchedule.Class = []
      for c in rested { mask.formUnion(c) }
      out.append(RestSchedule.Entry(from: start, to: start + s.steps, mask: mask))
    }
    return out
  }

  /// One section's budget: the melodic parts that play in it, in priority order, the ones kept
  /// and the ones over the budget (`rested`).
  struct LayerBudget: Equatable {
    var cap: Int
    var playing: [RestSchedule.Class]
    var kept: [RestSchedule.Class] { Array(playing.prefix(cap)) }
    var rested: [RestSchedule.Class] { Array(playing.dropFirst(cap)) }
  }

  /// The melodic parts in the order a budget keeps them: `layerPriority`'s roles by the rest
  /// class their group plays as (the composer's `groupFor`), each once: bass, melody,
  /// harmony, arp.
  static let layerClassPriority: [RestSchedule.Class] = {
    var out: [RestSchedule.Class] = []
    for role in layerPriority {
      let c = RestSchedule.Class.of(kind: "tonal", group: layerGroup(role), net: role)
      if !out.contains(c) { out.append(c) }
    }
    return out
  }()

  /// The group the composer gives a melodic role (`groupFor` in Composer.swift).
  static func layerGroup(_ role: String) -> String {
    switch role {
    case "melody", "lead": return "melody"
    case "pad", "chord", "chords", "harmony": return "harmony"
    default: return role
    }
  }

  /// Each section's budget (`autoLayerBudget`, others 2) and which of the melodic parts play
  /// in it: a part plays where any of its roles' slot nets has a window (`slotWindows`), or
  /// where a net of it with no slots (beats' single `harmony` pad) is unmuted (`netWindows`).
  static func layerBudgets(_ project: Project) -> [LayerBudget] {
    var roles: [String: RestSchedule.Class] = [:]
    var single: [String: RestSchedule.Class] = [:]
    for (id, nb) in project.nets.pairs where nb.role != "control" {
      guard nb.track.group != "stinger", !isStingerID(id), !id.hasPrefix("fill-") else {
        continue
      }
      let c = RestSchedule.Class.of(kind: "tonal", group: part(nb), net: id)
      guard layerClassPriority.contains(c) else { continue }
      if nb.riffGroup.isEmpty { single[id] = c } else { roles[nb.riffGroup] = c }
    }
    var playing = [RestSchedule.Class](repeating: [], count: project.structure.count)
    for (role, c) in roles.sorted(by: { $0.key < $1.key }) {
      for windows in slotWindows(project, role: role).values {
        for w in windows where w.section < playing.count { playing[w.section].formUnion(c) }
      }
    }
    for (id, c) in single.sorted(by: { $0.key < $1.key }) {
      for w in netWindows(project, net: id) where w.section < playing.count {
        playing[w.section].formUnion(c)
      }
    }
    return project.structure.enumerated().map { i, s in
      LayerBudget(
        cap: autoLayerBudget[s.name] ?? 2,
        playing: layerClassPriority.filter { playing[i].contains($0) })
    }
  }
}
