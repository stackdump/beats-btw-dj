// How loops come in and go out under the mixer: on a launch boundary (a beat, a bar, or a 2-,
// 4- or 8-bar phrase of the reference deck), with a countdown to it while a clip waits, and in
// scenes — saved sets of loops (and their levels and FX) that switch in together on one boundary.
//
// Main-thread state, like the rest of the loop bank's control (`LoopRecorder.swift`).

/// One clip of a scene, at the level (and with the FX) it had when the scene was saved.
public struct SceneClip: Sendable, Equatable {
  public var clipID: String
  public var gain: Double
  /// The clip's FX, set on the launch boundary. Nil: the scene leaves its FX alone (a clip saved
  /// with its FX off, and every scene from before scenes kept FX).
  public var fx: LoopFX?
  public init(clipID: String, gain: Double = 1, fx: LoopFX? = nil) {
    self.clipID = clipID
    self.gain = gain
    self.fx = fx
  }
}

/// A named set of loops: launching it brings exactly these clips in (at these levels) and takes
/// every other loop out, all on the next launch boundary. Scenes are named "Scene 1", "Scene 2"…
/// and renamed by hand; a name is the scene's identity (no two share one).
public struct LoopScene: Sendable, Equatable, Identifiable {
  public var name: String
  public var clips: [SceneClip]
  public var id: String { name }
  public init(name: String, clips: [SceneClip]) {
    self.name = name
    self.clips = clips
  }
}

extension DJEngine {
  /// The launch boundaries offered (beats): a beat, a bar, 2, 4 and 8 bars.
  public static let launchQuanta = [1, 4, 8, 16, 32]
  public static let defaultLoopQuantum = 4

  /// "beat", "bar", "2 bars"… for a launch boundary of `beats`.
  public static func quantumLabel(_ beats: Int) -> String {
    switch beats {
    case 1: "beat"
    case 4: "bar"
    case let b where b % 4 == 0: "\(b / 4) bars"
    default: "\(beats) beats"
    }
  }

  /// What loops start and stop on, in beats (any of `launchQuanta`; anything else is refused).
  /// Pending starts and stops keep the boundary they were given.
  public func setLoopQuantum(_ beats: Int) {
    guard Self.launchQuanta.contains(beats) else { return }
    loopQuantum = beats
  }

  /// Clip `id`'s own launch boundary in beats, if it has one (nil: it follows the row's).
  public func clipQuantum(_ id: String) -> Int? { clipQuanta[id] }

  /// What clip `id` starts and stops on, in beats: its own boundary, else the row's
  /// (`loopQuantum`). Scenes switch on the row's whatever their clips say (`launchScene`).
  public func quantum(for id: String?) -> Int { id.flatMap { clipQuanta[$0] } ?? loopQuantum }

  /// Give clip `id` a launch boundary of its own (any of `launchQuanta`; anything else is
  /// refused); nil: it follows the row's again. Pending starts and stops keep theirs.
  public func setClipQuantum(_ id: String, _ beats: Int?) {
    if let beats, !Self.launchQuanta.contains(beats) { return }
    clipQuanta[id] = beats
  }

  public static let defaultTapTakeBars = 2

  /// How many bars a quick tap of a controller's LOOP records (1…64; nil: none, a tap is a short
  /// hold). Anything else is refused.
  public func setTapTakeBars(_ bars: Int?) {
    if let bars, !(1...64).contains(bars) { return }
    tapTakeBars = bars
  }

  /// The row-wide settings, as the actions that set them: what a session recording has to say
  /// first when they are not the defaults (`SessionRecorder.start`), since a replay starts from
  /// a fresh engine.
  var loopSettings: [DeckAction] {
    [
      .loopQuantize(beats: loopQuantum), .loopFade(mode: loopFade.rawValue),
      .loopKeyLock(on: loopKeyLock), .tapBars(bars: tapTakeBars),
      .loopFollow(mode: loopFollow.rawValue),
    ] + (loopFxLink ? [.loopFxLink(on: true)] : [])
  }

  /// `loopSettings` of a fresh engine.
  static let defaultLoopSettings: [DeckAction] = [
    .loopQuantize(beats: defaultLoopQuantum), .loopFade(mode: LoopFade.declick.rawValue),
    .loopKeyLock(on: false), .tapBars(bars: defaultTapTakeBars),
    .loopFollow(mode: LoopFollow.louder.rawValue),
  ]

  /// The row-wide settings back to a fresh engine's (`defaultLoopSettings`, FX link off).
  func resetLoopSettings() {
    for a in Self.defaultLoopSettings { applyAction(a) }
    setLoopFxLink(false)
  }

  // MARK: countdown

  /// The deck frame a waiting clip switches at: comes in (`.starting`) or goes out
  /// (`.stopping`). Nil when it is not waiting.
  public func loopSwitchFrame(_ id: String) -> Int? {
    guard let v = loopVoices.firstIndex(where: { $0.clipID == id }) else { return nil }
    switch loopState(id) {
    case .starting: return loopVoices[v].startFrame
    case .stopping: return loopVoices[v].stopFrame
    default: return nil
    }
  }

  /// How long a waiting clip has to go, in beats of the clock it lines up with (the clip's own
  /// tempo with none), and how long it was given in all (the countdown's full turn).
  public func loopCountdown(_ id: String) -> (beats: Double, of: Double)? {
    guard let at = loopSwitchFrame(id), let c = clip(id),
      let v = loopVoices.firstIndex(where: { $0.clipID == id })
    else { return nil }
    let clock = loopClock(for: c)
    let perBeat = clock.framesPerBeat > 0 ? clock.framesPerBeat : 60 / c.bpm * sampleRate
    let now = loopChannel.renderedFrames
    let left = Double(max(0, at - now)) / perBeat
    let total = Double(max(0, at - (loopVoices[v].scheduledAt ?? now))) / perBeat
    return (left, max(total, left))
  }

  // MARK: scenes

  public func scene(_ name: String) -> LoopScene? { scenes.first { $0.name == name } }

  /// The name a new scene gets: "Scene n", the first n not taken.
  public var nextSceneName: String {
    var n = scenes.count + 1
    while scene("Scene \(n)") != nil { n += 1 }
    return "Scene \(n)"
  }

  /// Save the loops playing now (and those on their way in), in row order, with their levels and
  /// FX (those that have any on), as scene `name`: a new one on the end, or the one already called that, overwritten.
  @discardableResult
  public func saveScene(_ name: String) -> LoopScene? {
    guard !name.isEmpty else { return nil }
    let looping = Set(loopingClips)
    let s = LoopScene(
      name: name,
      clips: clips.filter { looping.contains($0.id) }.map {
        let fx = clipFx($0.id)
        return SceneClip(clipID: $0.id, gain: clipGain($0.id), fx: fx == LoopFX() ? nil : fx)
      })
    if let i = scenes.firstIndex(where: { $0.name == name }) {
      scenes[i] = s
    } else {
      scenes.append(s)
    }
    return s
  }

  /// Launch scene `name` (`launchScene(clips:)`). Returns the boundary it switches on.
  @discardableResult
  public func launchScene(_ name: String) -> Int? {
    scene(name).map { launchScene(clips: $0.clips) }
  }

  /// Bring exactly `clips` in at their levels (and FX, those that carry them) and take every
  /// other loop out, all at one frame: the next launch boundary (the row's, `loopQuantum`, not
  /// any clip's own) of the clock the first of them lines up with. A clip already in stays in
  /// (its level and FX change on the boundary); clips no longer on the row are left out.
  /// Returns the boundary.
  @discardableResult
  public func launchScene(clips wanted: [SceneClip]) -> Int {
    let present = wanted.filter { clip($0.clipID) != nil }
    let ids = Set(present.map(\.clipID))
    let lead = present.first.flatMap { clip($0.clipID) } ?? loopingClips.first.flatMap { clip($0) }
    let at = loopClock(for: lead).nextBoundary(
      after: loopChannel.renderedFrames + Self.loopLead, every: loopQuantum)
    for id in loopingClips where !ids.contains(id) { stopLoop(id, now: false, at: at) }
    for s in present {
      let sounding = loopState(s.clipID) == .on || loopState(s.clipID) == .stopping
      setClipGain(s.clipID, s.gain, at: sounding ? at : nil)
      if let fx = s.fx { setClipFx(s.clipID, fx, at: sounding ? at : nil) }
      startLoop(s.clipID, at: at)
    }
    return at
  }

  /// Rename scene `name` to `to` (refused if `to` is empty or taken).
  public func renameScene(_ name: String, to: String) {
    guard !to.isEmpty, scene(to) == nil, let i = scenes.firstIndex(where: { $0.name == name })
    else { return }
    scenes[i].name = to
  }

  public func deleteScene(_ name: String) { scenes.removeAll { $0.name == name } }

  /// Every scene gone (a reset, `DJEngine.reset(to:clip:)`).
  func clearScenes() { scenes = [] }

  /// Put saved scenes back (after any already there; a name already taken is skipped).
  public func restoreScenes(_ restored: [LoopScene]) {
    for s in restored where scene(s.name) == nil { scenes.append(s) }
  }

  /// A clip replaced on the row (cropped, a sequence rewritten): scenes use the new one.
  func replaceInScenes(_ id: String, with new: String) {
    for i in scenes.indices {
      for k in scenes[i].clips.indices where scenes[i].clips[k].clipID == id {
        scenes[i].clips[k].clipID = new
      }
    }
  }
}

extension [SceneClip] {
  /// `fx` only when the clip carries it: a scene without FX encodes as it always has.
  var json: JSONValue {
    .array(
      map {
        .object(
          JSONObject(
            [("clip", .string($0.clipID)), ("gain", .number($0.gain))]
              + ($0.fx.map { [("fx", $0.json)] } ?? [])))
      })
  }

  init(json v: JSONValue?) {
    self = (v?.array ?? []).compactMap { e in
      e["clip"]?.string.map {
        SceneClip(
          clipID: $0, gain: e["gain"]?.double ?? 1, fx: e["fx"].map { LoopFX(json: $0) })
      }
    }
  }
}

extension LoopScene {
  var json: JSONValue {
    .object(JSONObject([("name", .string(name)), ("clips", clips.json)]))
  }

  init?(json v: JSONValue) {
    guard let name = v["name"]?.string, !name.isEmpty else { return nil }
    self.init(name: name, clips: [SceneClip](json: v["clips"]))
  }
}
