import Foundation

/// Playing a net deck: section launches, role mutes, slot picks, macros, stingers and
/// scale-locked keys. All of it works on the wave engine's net clock.
extension Deck {
  public struct SectionInfo: Equatable, Sendable {
    public var name: String
    public var startTick: Int
    public var steps: Int
    /// How many phrases the section is cut into: the longest phrase list of any role (1 when
    /// no role has one). canvas.js `renderTimeline`: `Math.max(...phraseLists.map(p => p.length))`.
    public var phraseCount = 1
    /// The phrase letters of the section's first role ("A", "B", "A", "C"), as the timeline
    /// prints them; empty when the section has no phrase data.
    public var phrasePattern: [String] = []

    /// The sections of a project's structure, in order, with their start ticks.
    public static func sections(of project: Project) -> [SectionInfo] {
      var start = 0
      var out: [SectionInfo] = []
      for sec in project.structure {
        let lists = sec.phrases.values
        out.append(
          SectionInfo(
            name: sec.name, startTick: start, steps: sec.steps,
            phraseCount: lists.map(\.count).max() ?? 1, phrasePattern: lists.first ?? []))
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
    let bank = wave.samplers
    let seed = voicingSeed
    let filter = roleFilter
    let start = secs[index].startTick
    let song = wave.latest?.trackSerial
    let opts = sameSongOptions(.extended(samplers: bank, seed: seed, roleFilter: filter))
    generation += 1
    let mine = generation
    let prepared = await Task.detached(priority: .userInitiated) {
      WaveRunner.prepare(project, sampleRate: sr, opts: opts, startTick: start, trackSerial: song)
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
          project, sampleRate: wave.sampleRate, opts: sameSongOptions(waveOptions),
          startTick: max(0, tick), trackSerial: wave.latest?.trackSerial))
      applyNetTempo()
    } else {
      Task { @MainActor in await self.jumpToTick(tick) }
    }
  }

  /// `opts` for another start of the song this deck plays: it keeps the playing project's
  /// loudness gain, energy curve, duck depth, room, echo and part trims instead of measuring
  /// them again.
  func sameSongOptions(_ opts: WaveOptions) -> WaveOptions {
    var o = opts
    if let g = wave.latest?.gain { o.trackGain = g }
    if let e = wave.latest?.energy { o.trackEnergy = e }
    if let d = wave.latest?.duckDepth { o.duckDepth = d }
    if let s = wave.latest?.space { o.space = s }
    if let e = wave.latest?.echo { o.echo = e }
    if let b = wave.latest?.balance { o.trackBalance = b }
    return o
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
    let bank = wave.samplers
    let seed = voicingSeed
    let filter = roleFilter
    let song = wave.latest?.trackSerial
    let opts = sameSongOptions(.extended(samplers: bank, seed: seed, roleFilter: filter))
    generation += 1
    let mine = generation
    let prepared = await Task.detached(priority: .userInitiated) {
      WaveRunner.prepare(
        project, sampleRate: sr, opts: opts, startTick: max(0, tick), trackSerial: song)
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
  public func toggleRole(_ role: String) {
    guard !disabledRoles.contains(role) else { return }  // a disabled role stays off
    setRole(role, on: !isRoleOn(role))
  }

  /// Disable a role (`on`) — or enable it again. A disabled role is left out of every net
  /// this deck compiles from now on (new generations, the queued next track, section jumps:
  /// it is in `roleFilter`), and muted at once in the one playing; `service()` keeps it muted
  /// if a section of the current song brings it back before the next compile. Enabling lets
  /// it play again now.
  public func setRoleDisabled(_ role: String, _ disabled: Bool) {
    if disabled {
      disabledRoles.insert(role)
      setRole(role, on: false)
    } else {
      disabledRoles.remove(role)
      setRole(role, on: true)
    }
    var f = roleFilter ?? RoleFilter()
    if disabled { f.mute.insert(role) } else { f.mute.remove(role) }
    roleFilter = f.isEmpty ? nil : f
  }

  /// Keep disabled roles muted in the song playing (a section may unmute them).
  func enforceDisabledRoles() {
    guard mode == .net, !disabledRoles.isEmpty else { return }
    for r in disabledRoles where isRoleOn(r) { setRole(r, on: false) }
  }

  /// A controller's STEMS buttons on a net deck: each mutes a group of roles. "music" is
  /// everything but the drums; "mic" is the lead, the nearest a net has to a vocal.
  static let stems = ["music": ["bass", "melody", "harmony", "arp"], "mic": ["melody"]]

  /// The roles of `stem` this deck's net has.
  func stemRoles(_ stem: String) -> [String] {
    let group = Self.stems[stem] ?? []
    return roles.filter { group.contains($0) }
  }

  /// Is the STEMS group `stem` muted (its button pressed, not pressed again)?
  public func isStemMuted(_ stem: String) -> Bool { mode == .net && stemsMuted[stem] != nil }

  /// STEMS button: mute the group, or bring back what it silenced. Song sections mute and unmute
  /// roles too, so "silent now" is not "muted by the button": the group remembers which roles
  /// were playing when it muted them and brings back only those (and none another muted
  /// group still holds).
  public func toggleStem(_ stem: String) {
    guard mode == .net else { return }
    if let playing = stemsMuted.removeValue(forKey: stem) {
      let held = Set(stemsMuted.values.joined())
      for r in playing where !held.contains(r) { setRole(r, on: true) }
    } else {
      let rs = stemRoles(stem)
      stemsMuted[stem] = rs.filter { r in
        isRoleOn(r) || stemsMuted.values.contains { $0.contains(r) }
      }
      for r in rs { setRole(r, on: false) }
    }
  }

  /// Make slot `n` of a riff group (`bass-2`) the audible variant.
  public func activateSlot(role: String, slot: Int) {
    if mode == .net { wave.activateSlot("\(role)-\(slot)") }
  }

  // MARK: macros and stingers

  public func fire(_ macro: NetMacro, duration: Int? = nil) {
    guard mode == .net else { return }
    wave.fire(macro, ticks: macro.ticks(duration))
  }

  /// A master-chain macro (FX, pitch, feel) for `duration` bars (nil: its default; 0: permanent).
  /// On the loop channel ("L") it goes to the loops' master bus (LoopMasterFx.swift).
  public func fire(_ macro: MasterMacro, duration: Int? = nil) {
    if bank != nil {
      onMasterMacro?(macro, duration)
      return
    }
    guard mode == .net else { return }
    wave.fire(macro, bars: duration)
    onMasterMacro?(macro, duration)
  }

  /// Fire a catalog macro by its beats id (`drop`, `sweep-lp`, `feel-build`...), whichever kind
  /// it is. False for an id neither catalogue has.
  @discardableResult
  public func fireMacro(id: String, duration: Int? = nil) -> Bool {
    if let m = NetMacro(id: id) {
      fire(m, duration: duration)
    } else if let m = MasterMacro(id: id) {
      fire(m, duration: duration)
    } else {
      return false
    }
    return true
  }

  /// Is a catalog id one this app plays (`fireMacro(id:)` would fire it)?
  public static func isMacro(id: String) -> Bool {
    NetMacro(id: id) != nil || MasterMacro(id: id) != nil
  }

  public func panic() {
    if let bank {
      bank.master.panic()
      return
    }
    guard mode == .net else { return }
    wave.panic()
    onMasterMacro?(nil, nil)
  }

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
