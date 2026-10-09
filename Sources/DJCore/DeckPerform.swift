import Foundation

/// Playing a net deck: section launches, role mutes, slot picks, macros, stingers and
/// scale-locked keys. All of it works on the wave engine's net clock.
extension Deck {
  public struct SectionInfo: Equatable, Sendable {
    public var name: String
    public var startTick: Int
    public var steps: Int

    /// The sections of a project's structure, in order, with their start ticks.
    public static func sections(of project: Project) -> [SectionInfo] {
      var start = 0
      var out: [SectionInfo] = []
      for sec in project.structure {
        out.append(SectionInfo(name: sec.name, startTick: start, steps: sec.steps))
        start += sec.steps
      }
      return out
    }
  }

  /// The song's sections with their start ticks (empty for a loop or a sample deck). This is
  /// the project the deck has *loaded*; a project queued behind a playing one only takes over
  /// at the next bar. For the sections of the project that is sounding, read the layout of
  /// `wave.activeGeneration` (`MarkingLayout.sections`).
  public var sections: [SectionInfo] {
    guard mode == .net, let p = netProject else { return [] }
    return SectionInfo.sections(of: p)
  }

  /// The section the net clock is in, or nil.
  public var currentSectionIndex: Int? {
    let t = wave.tick
    return sections.lastIndex { $0.startTick <= t && t < $0.startTick + $0.steps }
  }

  /// Rebuild the net at the start of section `index` (silently replaying the control
  /// nets) and swap it in at the next bar. Composes nothing: same project, new position (the
  /// prepared project keeps the song's `trackSerial`, with a new `generation`).
  @MainActor @discardableResult
  public func jumpToSection(_ index: Int) async -> Bool {
    let secs = sections
    guard secs.indices.contains(index), let project = netProject else { return false }
    let sr = wave.sampleRate
    let start = secs[index].startTick
    let song = wave.latest?.trackSerial
    generation += 1
    let mine = generation
    let prepared = await Task.detached(priority: .userInitiated) {
      WaveRunner.prepare(project, sampleRate: sr, startTick: start, trackSerial: song)
    }.value
    guard mine == generation, mode == .net else { return false }
    wave.load(prepared)
    applyNetTempo()
    return true
  }

  /// Move the net to a tick (the swap lands on the next bar). Off the main thread by
  /// default; inline in `deterministic` (replay) mode.
  public func relocate(toTick tick: Int) {
    guard mode == .net, let project = netProject else { return }
    if deterministic {
      wave.load(
        WaveRunner.prepare(
          project, sampleRate: wave.sampleRate, startTick: max(0, tick),
          trackSerial: wave.latest?.trackSerial))
      applyNetTempo()
    } else {
      Task { @MainActor in await self.jumpToTick(tick) }
    }
  }

  /// Fire-and-forget section launch for controllers (callable from any thread).
  public func launchSection(_ index: Int) {
    let secs = sections
    guard secs.indices.contains(index) else { return }
    relocate(toTick: secs[index].startTick)
  }

  public func stepSection(_ delta: Int) {
    let secs = sections
    guard !secs.isEmpty else { return }
    let cur = currentSectionIndex ?? 0
    relocate(toTick: secs[min(secs.count - 1, max(0, cur + delta))].startTick)
  }

  /// Controller button: hand over to the pre-composed next track and keep playing.
  public func skipToNextTrack() {
    func go() {
      let was = playing
      if advanceToNext(), was || autoAdvance { setPlaying(true) }
    }
    if deterministic { go() } else { Task { @MainActor in go() } }
  }

  /// Jump the net to an exact tick (quantised to the next bar by the swap).
  @MainActor @discardableResult
  public func jumpToTick(_ tick: Int) async -> Bool {
    guard mode == .net, let project = netProject else { return false }
    let sr = wave.sampleRate
    let song = wave.latest?.trackSerial
    generation += 1
    let mine = generation
    let prepared = await Task.detached(priority: .userInitiated) {
      WaveRunner.prepare(project, sampleRate: sr, startTick: max(0, tick), trackSerial: song)
    }.value
    guard mine == generation, mode == .net else { return false }
    wave.load(prepared)
    applyNetTempo()
    return true
  }

  // MARK: roles

  static let roleOrder = ["kick", "snare", "hihat", "clap", "bass", "melody", "harmony", "arp"]

  /// The roles this deck's net has, in mixer order.
  public var roles: [String] {
    guard mode == .net, let g = wave.latest?.graph else { return [] }
    return Self.roleOrder.filter { g.roleTargets[strHash($0)] != nil }
  }

  public func isRoleOn(_ role: String) -> Bool { mode == .net && wave.isRoleAudible(role) }
  public func setRole(_ role: String, on: Bool) { if mode == .net { wave.setRoleMuted(role, !on) } }
  public func toggleRole(_ role: String) { setRole(role, on: !isRoleOn(role)) }

  /// Make slot `n` of a riff group (`bass-2`) the audible variant.
  public func activateSlot(role: String, slot: Int) {
    if mode == .net { wave.activateSlot("\(role)-\(slot)") }
  }

  // MARK: macros and stingers

  public func fire(_ macro: NetMacro, duration: Int? = nil) {
    guard mode == .net else { return }
    wave.fire(macro, ticks: macro.ticks(duration))
  }

  public func panic() { if mode == .net { wave.panic() } }

  /// Stinger `n` (0…3 → `hit1`…`hit4`): unmute its ring for `bars` bars.
  public func stinger(_ n: Int, bars: Int = 1) {
    guard mode == .net, (0..<4).contains(n) else { return }
    wave.fireStinger("hit\(n + 1)", ticks: bars * 16)
  }

  // MARK: keys

  /// Snap a MIDI note to the project's scale (nearest scale tone, ties go down).
  public func scaleLocked(_ note: Int) -> Int {
    guard let p = netProject, let root = p.rootNote else { return note }
    let intervals = scaleIntervals("\(p.scaleName)Scale")
    guard !intervals.isEmpty else { return note }
    var best = note
    var bestDist = Int.max
    for octave in -1...11 {
      for i in intervals {
        let candidate = (root % 12) + octave * 12 + i
        let d = abs(candidate - note)
        if d < bestDist || (d == bestDist && candidate < best) {
          best = candidate
          bestDist = d
        }
      }
    }
    return best
  }

  /// A key down on the live voice. Returns the note that actually sounds.
  @discardableResult
  public func keyDown(_ note: Int, velocity: Int = 100) -> Int {
    guard mode == .net else { return note }
    let q = scaleLocked(note)
    heldKeys[note] = q
    wave.noteOn(q, velocity: velocity)
    return q
  }

  public func keyUp(_ note: Int) {
    guard mode == .net else { return }
    wave.noteOff(heldKeys.removeValue(forKey: note) ?? scaleLocked(note))
  }
}
