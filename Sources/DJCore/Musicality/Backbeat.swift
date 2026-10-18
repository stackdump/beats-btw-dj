import Foundation

extension DJMusicality {
  /// A drum part's figure, as shares of the part's loudest composed hit: `bar` by sixteenth in a
  /// 16-step bar, `beat` by sixteenth in one beat, for rings that hold whole beats but not a whole
  /// bar (jazz's drums are 12-step rings, three beats: a 2 and 4 can't stay on 2 and 4 there).
  struct BackbeatFigure: Sendable {
    var bar: [Int: Double]
    var beat: [Int: Double]
  }

  /// The chill family's kick and snare (`.backbeat`).
  struct BackbeatStyle: Sendable {
    var kick: BackbeatFigure
    var snare: BackbeatFigure

    func figure(_ role: String) -> BackbeatFigure { role == "kick" ? kick : snare }
  }

  /// The figures by genre; nil outside the chill / jazz family (ambient has no beat to give, and
  /// every other genre's verses and choruses already play one).
  static func backbeatStyle(genre: String) -> BackbeatStyle? {
    switch genre {
    case "lofi":
      // boom-bap: kick on 1, the a of 2 and the and of 3; the snare's crack on 2 and 4
      BackbeatStyle(
        kick: BackbeatFigure(bar: [0: 1, 7: 0.55, 10: 0.85], beat: [0: 0.9]),
        snare: BackbeatFigure(bar: [4: 1, 12: 1], beat: [0: 0.8]))
    case "jazz":
      // a feathered kick (soft, on every beat) under a soft 2 and 4; on a ring of whole beats
      // only (beats' 12-step jazz drums) the snare keeps time softly on every beat, as brushes do
      BackbeatStyle(
        kick: BackbeatFigure(bar: [0: 0.45, 4: 0.45, 8: 0.45, 12: 0.45], beat: [0: 0.45]),
        snare: BackbeatFigure(bar: [4: 0.55, 12: 0.55], beat: [0: 0.4]))
    case "bossa":
      // the surdo's dotted quarter and eighth, leaning on 3; the rim plays the bossa clave
      BackbeatStyle(
        kick: BackbeatFigure(bar: [0: 0.8, 6: 0.55, 8: 1, 14: 0.55], beat: [0: 0.8]),
        snare: BackbeatFigure(bar: [0: 0.9, 3: 0.75, 6: 0.85, 10: 0.9, 13: 0.75], beat: [0: 0.8]))
    default:
      nil
    }
  }

  /// The parts `.backbeat` brings in.
  static let backbeatRoles = ["kick", "snare"]

  /// Kick and snare on the backbeat in chill / jazz verses and choruses.
  ///
  /// beats' theme table leaves lofi, jazz and bossa's verses and choruses without a kick or snare
  /// (they come in only in buildup / drop / pre-chorus, jazz and bossa's kick in the outro): a
  /// `standard` song never plays a beat (ROADMAP 6.5's dj half). Each of the two parts comes in
  /// wherever the genre's style has a beat (`beatStyle`) as well as where the composer had it,
  /// playing the family's figure (`backbeatStyle`). Called from `apply` after `.timing`, before
  /// `.variety` (whose ghost hits then land around the figure).
  static func playBackbeat(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    backbeat(&p, genre: spec.genre)
  }

  /// `playBackbeat`'s work. Returns the parts it left alone and why (nothing for a genre outside
  /// the family or a song without sections, which it leaves alone entirely).
  ///
  /// Bindings and markings only, never topology:
  /// - the section edges are mute / unmute bindings on `struct-<role>`'s own stages when it has
  ///   as many as there are edges (its `p_delay_i` gaps retimed onto them, spare stages
  ///   repeating the last state a tick later). The composer builds one stage per change it made
  ///   (none at all for a part it never brings in), so usually it hasn't: then its stages are
  ///   rebound to say what the new plan says at their tick, and each edge goes on a free
  ///   transition of a `fill-N` chain that spans it (one transition per tick from the song's
  ///   start to its boundary, as `.buildup` and `.crash` use them; a muted net's controls still
  ///   fire). A change fires on the section's start tick, after that tick's notes: the
  ///   convention `.timing` gives the composer's own changes.
  /// - the part starts unmuted when the first section has a beat;
  /// - its ring's bindings are rewritten to the figure, on its own transitions.
  /// A slotted part (`kick-0`, `kick-1`…, driven by `activate-slot`) is skipped: its struct net
  /// picks a slot per phrase, and a mute laid over it would fight the slot it activates.
  @discardableResult
  static func backbeat(_ p: inout Project, genre: String) -> [String: String] {
    guard let style = backbeatStyle(genre: genre), let beat = beatStyle(genre: genre),
      !p.structure.isEmpty
    else { return [:] }
    var starts: [Int] = []
    var total = 0
    for s in p.structure {
      starts.append(total)
      total += s.steps
    }
    var skipped: [String: String] = [:]
    for role in backbeatRoles {
      if p.nets.values.contains(where: { $0.riffGroup == role }) {
        skipped[role] = "slotted: struct-\(role) activates a slot per phrase"
        continue
      }
      guard let net = p.nets[role] else {
        skipped[role] = "no \(role) net"
        continue
      }
      guard let figure = backbeatBindings(net, style.figure(role)) else {
        skipped[role] = "not a ring of whole beats"
        continue
      }
      guard let control = p.nets["struct-\(role)"], let stages = structureStages(control, role)
      else {
        skipped[role] = "struct-\(role) is not a chain of mutes and unmutes"
        continue
      }

      // Where the composer had the part (its state halfway through each section: without
      // `.timing` each stage fires a tick later than the one before), where the style wants
      // it, and the edges between.
      var composed: [Bool] = []
      for (start, section) in zip(starts, p.structure) {
        var on = !p.initialMutes.contains(role)
        for s in stages where s.tick <= start + section.steps / 2 { on = s.unmute }
        composed.append(on)
      }
      let wanted = p.structure.indices.map { composed[$0] || beat.contains(p.structure[$0].name) }
      var edges: [(tick: Int, unmute: Bool)] = []
      for k in wanted.indices.dropFirst() where wanted[k] != wanted[k - 1] {
        edges.append((starts[k], wanted[k]))
      }
      func wantedAt(step: Int) -> Bool { wanted[starts.lastIndex { $0 <= step } ?? 0] }
      func action(_ unmute: Bool) -> ControlBinding {
        controlBinding(unmute ? "unmute-track" : "mute-track", target: role)
      }

      var q = p
      var ctl = control
      if stages.count >= edges.count {
        // Retime the chain's own stages onto the edges.
        var prev = 0
        var last = wanted[0]
        for i in stages.indices {
          let tick = i < edges.count ? edges[i].tick : prev + 1
          let unmute = i < edges.count ? edges[i].unmute : last
          ctl.places["p_delay_\(i)"]?.initial = [Double(tick - prev - 1)]
          ctl.controlBindings["t_ctrl_\(i)"] = action(unmute)
          prev = tick
          last = unmute
        }
      } else {
        // Each stage says what the plan says at its tick; the edges ride on the fill chains.
        for (i, s) in stages.enumerated() {
          ctl.controlBindings["t_ctrl_\(i)"] = action(wantedAt(step: s.tick))
        }
        let chains = q.nets.pairs.filter { $0.key.hasPrefix("fill-") && isSinkChain($0.value) }
          .sorted {
            $0.value.transitions.count != $1.value.transitions.count
              ? $0.value.transitions.count > $1.value.transitions.count : $0.key < $1.key
          }.map(\.key)
        var carried = true
        for e in edges {
          let t = "t\(e.tick - 1)"
          guard
            let id = chains.first(where: {
              q.nets[$0]!.transitions[t] != nil && q.nets[$0]!.controlBindings[t] == nil
            })
          else {
            carried = false
            break
          }
          q.nets[id]!.controlBindings[t] = action(e.unmute)
        }
        guard carried else {
          skipped[role] = "no stage or fill chain left to carry a section edge"
          continue
        }
      }
      q.nets["struct-\(role)"] = ctl
      if wanted[0] {
        q.initialMutes.removeAll { $0 == role }
      } else if !q.initialMutes.contains(role) {
        q.initialMutes.append(role)
      }
      q.nets[role]!.bindings = figure
      p = q
    }
    return skipped
  }

  /// The stages of an accumulator control net (`buildAccumulatorNet`): the tick each fires on
  /// (stage i drains `p_delay_i`, then fires the tick after; the next one's gate opens on that
  /// tick) and whether it unmutes `role`. [] for the empty chain the composer builds for a part
  /// that never changes; nil for anything else (a slot net, another target, the ring flavour).
  static func structureStages(_ nb: NetBundle, _ role: String) -> [(tick: Int, unmute: Bool)]? {
    guard nb.role == "control" else { return nil }
    guard nb.places["p_delay_0"] != nil else { return nb.controlBindings.count == 0 ? [] : nil }
    var out: [(tick: Int, unmute: Bool)] = []
    var tick = 0
    while let gap = nb.places["p_delay_\(out.count)"]?.initial.first {
      guard let c = nb.controlBindings["t_ctrl_\(out.count)"], c.targetNet == role,
        c.action == "mute-track" || c.action == "unmute-track"
      else { return nil }
      tick += Int(gap) + 1
      out.append((tick, c.action == "unmute-track"))
    }
    return out
  }

  /// A chain `p0 → t0 → p1 → … → tN-1 → pN` (`drumFillNet`): transition i fires on tick i + 1.
  static func isSinkChain(_ nb: NetBundle) -> Bool {
    let n = nb.transitions.count
    return n > 0 && nb.places.count == n + 1 && nb.places["p0"]?.initial.first == 1
      && nb.transitions["t\(n - 1)"] != nil
  }

  /// `figure` on a one-token ring of drum hits, from where its token starts: every bar, or every
  /// beat for a ring of whole beats that isn't whole bars; each hit with the note, channel and
  /// length of the ring's loudest. nil when the net is no such ring or holds no whole beat.
  static func backbeatBindings(_ nb: NetBundle, _ figure: BackbeatFigure)
    -> OrderedMap<MidiBinding>?
  {
    let n = nb.transitions.count
    guard n >= 4, nb.places.count == n,
      (0..<n).allSatisfy({ nb.places["p\($0)"] != nil && nb.transitions["t\($0)"] != nil }),
      let at = (0..<n).first(where: { (nb.places["p\($0)"]?.initial.first ?? 0) > 0 }),
      let peak = nb.bindings.values.filter({ isDrumChannel($0.channel) })
        .max(by: { $0.velocity < $1.velocity })
    else { return nil }
    let (period, cell) = n % 16 == 0 ? (16, figure.bar) : (4, figure.beat)
    guard n % period == 0 else { return nil }
    var share = [Double?](repeating: nil, count: n)
    for k in 0..<(n / period) {
      for (pos, s) in cell where pos >= 0 && pos < period {
        share[(at + k * period + pos) % n] = s
      }
    }
    var out = OrderedMap<MidiBinding>()
    for i in 0..<n {
      guard let s = share[i] else { continue }
      var b = peak
      b.velocity = clampVelocity(Int((Double(peak.velocity) * s).rounded()))
      out["t\(i)"] = b
    }
    return out
  }
}
