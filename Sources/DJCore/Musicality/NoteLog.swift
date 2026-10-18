import Foundation

/// One audible note of a net, as the wave engine's clock fires it.
public struct NoteEvent: Sendable, Equatable {
  /// The graph's tick after the fire (1-based: the first tick of the song is 1); a tick is a
  /// sixteenth.
  public var tick: Int
  public var net: String
  /// The net's mixer group (`drums`, `bass`, `melody`, `arp`, `harmony`, `stinger`, …), else
  /// its riff group, else its id.
  public var group: String
  public var note: Int
  public var velocity: Int
  public var channel: Int
  /// Length in sixteenths (from `durationSteps`, else the ms length at the project's tempo).
  public var steps: Double
  public var isDrum: Bool { isDrumChannel(channel) }
}

/// A structure change: a control net muting, unmuting or switching a part.
public struct PartChange: Equatable {
  public var tick: Int
  public var net: String
  public var action: ControlAction
  public var target: String
  /// For a slot switch onto a ring net (`p0`…`pN-1`): where the ring's token sits after the
  /// tick, i.e. the step of its cycle the slot plays first. 0 = it comes in from the top.
  public var phase: Int? = nil
}

/// The notes a project plays, from simulating its nets tick by tick (no audio): what
/// `MusicalityReport` measures.
public enum NoteLog {
  /// The song's length in ticks: its structure, else `bars` × 16.
  public static func length(_ project: Project) -> Int {
    let s = project.structure.reduce(0) { $0 + $1.steps }
    return s > 0 ? s : max(1, project.bars ?? 4) * 16
  }

  /// A net's group: its mixer group, else its riff group, else its id (`NoteEvent.group`).
  static func groupName(_ nb: NetBundle, id: String) -> String {
    let tg = nb.track.group ?? ""
    return !tg.isEmpty ? tg : (!nb.riffGroup.isEmpty ? nb.riffGroup : id)
  }

  /// Every note `project` plays in its first `ticks` ticks (default: the whole song). Stops
  /// early when the song's own transport stops it. With `harmony`, tonal notes are mapped
  /// through the section plan, as the runner plays them under `.sectionHarmony`.
  public static func capture(
    _ project: Project, ticks: Int? = nil, harmony: SectionHarmony? = nil
  ) -> [NoteEvent] {
    run(WaveGraph(project: project), ticks: ticks ?? length(project), harmony: harmony).notes
  }

  /// The notes and the part changes (mute / unmute / slot switches) of the first `ticks`.
  public static func captureAll(
    _ project: Project, ticks: Int? = nil, harmony: SectionHarmony? = nil
  ) -> (notes: [NoteEvent], controls: [PartChange]) {
    run(WaveGraph(project: project), ticks: ticks ?? length(project), harmony: harmony)
  }

  static func run(_ g: WaveGraph, ticks: Int, harmony: SectionHarmony? = nil)
    -> (notes: [NoteEvent], controls: [PartChange])
  {
    var out: [NoteEvent] = []
    var controls: [PartChange] = []
    let tempo = g.tempo > 0 ? g.tempo : 120
    let msPerStep = 60000 / (tempo * 4)
    var group: [String] = []
    var harmonyGroup: [Int] = []
    for n in g.nets {
      let name = groupName(n.bundle, id: n.id)
      group.append(name)
      harmonyGroup.append(harmony?.groupIndex(name) ?? -1)
    }
    for _ in 0..<ticks {
      g.advance { n, t in
        let steps = n.durSteps[t] > 0 ? n.durSteps[t] : n.durMs[t] / msPerStep
        let channel = Int(n.channel[t])
        var note = n.note[t]
        if let h = harmony, harmonyGroup[n.index] >= 0, !isDrumChannel(channel) {
          note = h.note(note, group: harmonyGroup[n.index], step: g.tick - 1)
        }
        out.append(
          NoteEvent(
            tick: g.tick, net: n.id, group: group[n.index], note: note, velocity: n.vel[t],
            channel: channel, steps: steps))
      }
      for i in stride(from: 0, to: g.controlCount, by: 2) {
        let n = g.nets[Int(g.controls[i])]
        let t = Int(g.controls[i + 1])
        let a = n.action[t]
        guard a == .mute || a == .unmute || a == .toggle || a == .slot else { continue }
        var phase: Int?
        if a == .slot, let ti = g.byId[n.actionTarget[t]] { phase = ringPosition(g.nets[ti]) }
        controls.append(
          PartChange(
            tick: g.tick, net: n.id, action: a, target: n.actionTarget[t], phase: phase))
      }
      if g.stopRequested { break }
    }
    return (out, controls)
  }

  /// The index of the marked `p<i>` place of a ring net (one token, places `p0`…), else nil.
  static func ringPosition(_ n: CompiledNet) -> Int? {
    var at: Int?
    for (i, id) in n.placeIds.enumerated() where n.state[i] > 0 {
      guard at == nil, id.hasPrefix("p"), let k = Int(id.dropFirst()) else { return nil }
      at = k
    }
    return at
  }
}
