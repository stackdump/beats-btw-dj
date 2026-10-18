// How the loops under the mixer sound: mute and solo per clip, the fade a loop comes in and goes
// out with (the row's, or a clip's own), and key lock (a loop played at another tempo than its own keeps its pitch).
//
// Mute and solo are gains: a muted clip's voice (or, while any clip is soloed, every voice that
// is not) goes to level 0 and keeps playing, so it comes back in phase. The bank ramps every level
// change over ~5 ms and every start / stop over the fade (`LoopBank`), on the audio thread.
//
// Key lock is done offline. The bank's voices are varispeed turntables: a clip at 1.05× its tempo
// plays 5 % sharp. A locked clip whose tempo is more than `keyLockTolerance` off its own gets a
// time-stretched copy at that tempo (`TimeStretch.wsola`), rendered off the main thread, and the
// voice swaps to it in phase at the next block (`TurntableCommand.swap`), its pitch fader at 0.
// Until the copy is ready it plays varispeed; when the tempo drifts on by more than the tolerance
// (and holds there for `stretchDebounce`), it is rendered again.

/// How a loop under the mixer comes in and goes out.
public enum LoopFade: String, CaseIterable, Sendable {
  /// At once (a click, if it lands mid-waveform).
  case off
  /// 10 ms: no click, still on the downbeat.
  case declick = "10ms"
  case beat
  case bar

  public var label: String {
    switch self {
    case .off: "off"
    case .declick: "10 ms"
    case .beat: "1 beat"
    case .bar: "1 bar"
    }
  }
}

/// A weak reference to the engine that can cross to a background task and back.
private struct EngineRef: @unchecked Sendable {
  weak var engine: DJEngine?
}

extension DJEngine {
  /// Key lock re-renders when the tempo is this far (as a ratio) from the audio's: 0.5 %.
  static let keyLockTolerance = 0.005
  /// …and has held there for this long (seconds), so a tempo fader being moved renders once.
  static let stretchDebounce = 0.25

  // MARK: mute and solo

  public func isClipMuted(_ id: String) -> Bool { clipMutes.contains(id) }
  public func isClipSoloed(_ id: String) -> Bool { clipSolos.contains(id) }

  /// Mute (`on`) a clip under the mixer: it plays on, silent, and comes back in phase.
  public func setClipMute(_ id: String, _ on: Bool) {
    if on { clipMutes.insert(id) } else { clipMutes.remove(id) }
    pushClipLevels()
  }

  /// Solo a clip: while any clip is soloed, only soloed ones are heard under the mixer.
  public func setClipSolo(_ id: String, _ on: Bool) {
    if on { clipSolos.insert(id) } else { clipSolos.remove(id) }
    pushClipLevels()
  }

  /// What a clip's voice plays at: its level, or 0 when muted or soloed out.
  public func audibleClipGain(_ id: String) -> Double { audible(id, at: clipGain(id)) }

  /// Level `gain` for clip `id` as its voice plays it: 0 when muted or soloed out.
  func audible(_ id: String, at gain: Double) -> Double {
    if clipMutes.contains(id) { return 0 }
    if !clipSolos.isEmpty && !clipSolos.contains(id) { return 0 }
    return gain
  }

  /// Every voice's level, again (a mute or solo changes others' too). The bank ramps to it.
  /// A voice whose level is waiting for a scene's boundary (`LoopVoice.gainUntil`) keeps
  /// waiting: the level it has until then, and the scene's from then, both with the new mute
  /// and solo (a plain level change on its own would cancel the wait).
  func pushClipLevels() {
    guard let bank = loopChannel.bank else { return }
    let now = loopChannel.renderedFrames
    for v in loopVoices.indices {
      guard let id = loopVoices[v].clipID else { continue }
      if let wait = loopVoices[v].gainUntil, wait.frame > now {
        bank.send(.gain(voice: v, Float(audible(id, at: wait.gain))))
        bank.send(.gainAt(voice: v, Float(audibleClipGain(id)), frame: wait.frame))
      } else {
        loopVoices[v].gainUntil = nil
        bank.send(.gain(voice: v, Float(audibleClipGain(id))))
      }
    }
  }

  // MARK: fades

  /// How loops come in and go out from now on (clips with a fade of their own keep it).
  public func setLoopFade(_ fade: LoopFade) { loopFade = fade }

  /// Clip `id`'s own fade, if it has one (nil: it follows the row's, `loopFade`).
  public func clipFade(_ id: String) -> LoopFade? { clipFades[id] }

  /// The fade clip `id` comes in and goes out with: its own, else the row's.
  public func loopFade(for id: String?) -> LoopFade { id.flatMap { clipFades[$0] } ?? loopFade }

  /// Give clip `id` a fade of its own; nil: it follows the row's again. A start or stop already
  /// waiting keeps the fade it was given.
  public func setClipFade(_ id: String, _ fade: LoopFade?) { clipFades[id] = fade }

  /// The fade in frames for clip `id` (its own fade, else the row's) playing at `bpm`; `short`:
  /// a start or stop that is not on a downbeat (a fresh take, a clip moved to a deck), which only
  /// de-clicks.
  func loopFadeFrames(for id: String?, bpm: Double, short: Bool = false) -> Int {
    loopFadeFrames(loopFade(for: id), bpm: bpm, short: short)
  }

  /// The row's fade in frames for a loop playing at `bpm` (`loopFadeFrames(for:bpm:short:)`).
  func loopFadeFrames(bpm: Double, short: Bool = false) -> Int {
    loopFadeFrames(loopFade, bpm: bpm, short: short)
  }

  private func loopFadeFrames(_ fade: LoopFade, bpm: Double, short: Bool) -> Int {
    let declick = Int(sampleRate * 0.01)
    let beat = bpm > 0 ? Int(60 / bpm * sampleRate) : declick
    let frames: Int
    switch fade {
    case .off: return 0
    case .declick: frames = declick
    case .beat: frames = beat
    case .bar: frames = 4 * beat
    }
    return short ? min(frames, declick) : frames
  }

  // MARK: key lock

  /// Does clip `id` keep its pitch at another tempo? Its own setting, else the row's.
  public func isKeyLocked(_ id: String) -> Bool { clipKeyLocks[id] ?? loopKeyLock }

  public func setClipKeyLock(_ id: String, _ on: Bool) {
    clipKeyLocks[id] = on
    serviceLoops()
  }

  /// The row's key lock, for clips not set one way or the other themselves.
  public func setLoopKeyLock(_ on: Bool) {
    loopKeyLock = on
    serviceLoops()
  }

  /// Is clip `id` playing a time-stretched copy under the mixer (key lock at work)?
  public func isClipStretched(_ id: String) -> Bool {
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id }), let c = clip(id) else {
      return false
    }
    return loopVoices[v].bufferBPM != c.bpm
  }

  /// Is a stretched copy of clip `id` being rendered?
  public func isClipStretching(_ id: String) -> Bool {
    loopVoices.contains { $0.clipID == id && $0.stretching != nil }
  }

  /// The audio a clip starts with at `bpm`: a stretched copy already made for about that tempo
  /// when it is key-locked, else its own. With the tempo that audio plays at.
  func loopAudio(_ clip: LoopClip, at bpm: Double) -> (buffer: SampleBuffer, bpm: Double) {
    if isKeyLocked(clip.id), abs(bpm / clip.bpm - 1) > Self.keyLockTolerance,
      let c = stretchCache[clip.id], abs(bpm / c.bpm - 1) <= Self.keyLockTolerance
    {
      return (c.buffer, c.bpm)
    }
    return (clip.buffer, clip.bpm)
  }

  /// Key lock for voice `v` (from `serviceLoops`, its target tempo up to date): swap back to the
  /// clip's own audio when it is not wanted, else to a stretched copy at the target tempo (a
  /// cached one, or one rendered once the tempo has held for `stretchDebounce`).
  func serviceKeyLock(_ v: Int, _ clip: LoopClip, now: Int) {
    let voice = loopVoices[v]
    let tol = Self.keyLockTolerance
    let stretch = isKeyLocked(clip.id) && abs(voice.targetBPM / clip.bpm - 1) > tol
    guard stretch else {
      loopVoices[v].stretchWant = nil
      if voice.bufferBPM != clip.bpm { swapVoice(v, to: clip.buffer, bpm: clip.bpm) }
      return
    }
    guard abs(voice.targetBPM / voice.bufferBPM - 1) > tol else {
      loopVoices[v].stretchWant = nil
      return
    }
    guard voice.stretching == nil else { return }  // one at a time: the next pass sees any drift
    if let c = stretchCache[clip.id], abs(voice.targetBPM / c.bpm - 1) <= tol {
      return swapVoice(v, to: c.buffer, bpm: c.bpm)
    }
    if let want = voice.stretchWant, abs(want.bpm / voice.targetBPM - 1) < 0.001 {
      if Double(now - want.since) >= Self.stretchDebounce * sampleRate {
        renderStretch(v, clip, bpm: voice.targetBPM)
      }
    } else {
      loopVoices[v].stretchWant = (voice.targetBPM, now)
    }
  }

  /// Render clip's audio stretched to `bpm`, off the main thread (inline when deterministic, as
  /// a replay must be), then swap it into voice `v` if that voice still wants it.
  private func renderStretch(_ v: Int, _ clip: LoopClip, bpm: Double) {
    stretchToken += 1
    let token = stretchToken
    loopVoices[v].stretching = token
    loopVoices[v].stretchWant = nil
    let ratio = bpm / clip.bpm
    let source = clip.buffer
    let id = clip.id
    if deterministic {
      return finishStretch(token, id, TimeStretch.stretch(source, ratio: ratio))
    }
    let ref = EngineRef(engine: self)
    Task.detached(priority: .userInitiated) {
      let out = TimeStretch.stretch(source, ratio: ratio)
      await MainActor.run { ref.engine?.finishStretch(token, id, out) }
    }
  }

  private func finishStretch(_ token: Int, _ id: String, _ buffer: SampleBuffer) {
    guard let c = clip(id) else { return }
    // the copy holds the clip's beats: its tempo follows from its length
    let bpm = c.bpm * Double(c.buffer.length) / Double(buffer.length)
    stretchCache[id] = (bpm, buffer)
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id && $0.stretching == token })
    else { return }
    loopVoices[v].stretching = nil
    guard loopVoices[v].stopFrame == nil, isKeyLocked(id),
      abs(loopVoices[v].targetBPM / c.bpm - 1) > Self.keyLockTolerance
    else { return }
    swapVoice(v, to: buffer, bpm: bpm)
  }

  /// Voice `v` plays `buffer` (the same beats, at `bpm`) from the next block, in phase.
  private func swapVoice(_ v: Int, to buffer: SampleBuffer, bpm: Double) {
    guard let bank = loopChannel.bank else { return }
    let ratio = loopVoices[v].targetBPM / bpm
    bank.voices[v].swap(buffer, pitch: ratio - 1)
    loopVoices[v].bufferBPM = bpm
    loopVoices[v].bufferLength = Double(buffer.length)
    loopVoices[v].ratio = ratio
  }

  // MARK: bookkeeping

  /// A clip left the row: forget how it sounded.
  func forgetClipSound(_ id: String) {
    clipMutes.remove(id)
    clipKeyLocks[id] = nil
    clipQuanta[id] = nil
    clipFades[id] = nil
    clipFollows[id] = nil
    stretchCache[id] = nil
    if clipSolos.remove(id) != nil { pushClipLevels() }
  }

  /// `new` takes `old`'s place on the row (a crop, an edited sequence): it sounds the same way.
  func carryClipSound(from old: String, to new: String) {
    if clipMutes.remove(old) != nil { clipMutes.insert(new) }
    if clipSolos.remove(old) != nil { clipSolos.insert(new) }
    if let k = clipKeyLocks.removeValue(forKey: old) { clipKeyLocks[new] = k }
    if let q = clipQuanta.removeValue(forKey: old) { clipQuanta[new] = q }
    if let f = clipFades.removeValue(forKey: old) { clipFades[new] = f }
    if let f = clipFollows.removeValue(forKey: old) { clipFollows[new] = f }
    stretchCache[old] = nil
  }
}
