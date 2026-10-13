import Foundation

/// dj's pass over a composed track before a deck plays it: the fixes for what makes beats'
/// generator sound unmusical (docs/musicality-notes.md).
///
/// `compose()` stays beats' byte for byte — shares, sessions and model CIDs keep meaning the
/// same track in both apps — and this runs after it, on `PreparedTrack.played`. It only
/// rewrites MIDI bindings (note, velocity, length) and initial markings, never places,
/// transitions or arcs, so the net views, section jumps and recorded sessions see the same
/// nets the composer built. A pure function of (project, spec): a replay plays the same notes.
public enum DJMusicality {
  public struct Fixes: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Tension variants (B / C sections) back in the track's key (`expandVariants` builds
    /// them on a root shifted by +2 / −3 semitones).
    public static let key = Fixes(rawValue: 1 << 0)

    /// Structure changes on the beat they were composed for (`buildAccumulatorNet` lands
    /// every event one tick later than the one before, and after the downbeat's notes).
    public static let timing = Fixes(rawValue: 1 << 1)

    public static let all: Fixes = [.key, .timing]
  }

  /// `project` as the deck should play it. `spec` is the spec it was composed from.
  public static func apply(_ project: Project, spec: TrackSpec, fixes: Fixes = .all) -> Project {
    guard !fixes.isEmpty, let genre = BeatsTables.shared.genres[spec.genre] else { return project }
    var p = project
    if fixes.contains(.key) { keepVariantsInKey(&p, genre: genre, spec: spec) }
    if fixes.contains(.timing) { fixStructureTiming(&p) }
    return p
  }

  // MARK: key

  /// The roles `expandVariants` builds melodic slot variants for.
  static let melodicRoles: Set<String> = ["bass", "melody", "arp"]

  /// With the genre's tension curve, a B / C slot of a melodic role was composed on
  /// `rootNote + registerShift` with the scale rebuilt there: every note of it is the home-key
  /// note moved by that shift. Move it back. The variant keeps its density and velocity
  /// (what makes it B or C), and now plays over the same chords as everything else.
  static func keepVariantsInKey(_ p: inout Project, genre: GenreDef, spec: TrackSpec) {
    guard spec.overrides["tension-curve"]?.bool ?? genre.tensionCurve else { return }
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role != "control", melodicRoles.contains(nb.riffGroup)
      else { continue }
      let shift = tensionForVariant(nb.riffVariant).registerShift
      guard shift != 0 else { continue }
      for t in nb.bindings.keys {
        guard var b = nb.bindings[t], !isDrumChannel(b.channel) else { continue }
        b.note = max(0, min(127, b.note - shift))
        nb.bindings[t] = b
      }
      p.nets[id] = nb
    }
  }

  // MARK: timing

  /// `buildAccumulatorNet` chains one stage per event: `p_delay_i` holds the gap to the
  /// previous event, drained one token per tick, then `t_ctrl_i` fires on the next tick and
  /// opens the next stage's gate. Two things go wrong:
  /// - every stage after the first starts the tick after the previous control, so each event
  ///   lands one tick later than the one before (the bass's fifth change is five sixteenths
  ///   off, the drums', with fewer events, less);
  /// - even the first lands on the downbeat's own tick, and control nets fire after the music
  ///   nets within a tick: the mute / slot change applies only after the downbeat's notes, so
  ///   every part that enters a section loses its first beat (the old slot plays it instead).
  /// A delay of `gap - 1` on every stage fires each change on the last sixteenth before its
  /// step, after that sixteenth's notes: the new section starts complete, on the bar.
  static func fixStructureTiming(_ p: inout Project) {
    for id in p.nets.keys {
      guard var nb = p.nets[id], nb.role == "control", nb.places["p_delay_0"] != nil,
        nb.places["p_gate_0"] != nil
      else { continue }
      var i = 0
      while var place = nb.places["p_delay_\(i)"] {
        if let gap = place.initial.first, gap >= 1 { place.initial = [gap - 1] }
        nb.places["p_delay_\(i)"] = place
        i += 1
      }
      p.nets[id] = nb
    }
  }
}
