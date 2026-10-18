import Foundation

// The row as a library: a clip taken off it can be put back where it was, renamed, given a
// colour, traced back to the track it came from, and written out as a WAV. Main-thread state,
// like the rest of the row; every change a performer makes is a `DeckAction`.

/// A clip taken off the row, with the place it had there.
public struct RemovedClip: Sendable, Equatable {
  public let clip: LoopClip
  /// Its index on the row when it was taken off.
  public let index: Int
  /// How it sounded then (mute, solo, key lock, launch boundary, fade, tempo follow), so putting
  /// it back undoes the removal whole.
  public let sound: ClipSound

  init(clip: LoopClip, index: Int, sound: ClipSound = ClipSound()) {
    self.clip = clip
    self.index = index
    self.sound = sound
  }
}

/// A clip's own sound settings under the mixer (LoopSound.swift); its level is kept apart, in
/// `clipGains`, and survives a removal anyway.
public struct ClipSound: Sendable, Equatable {
  public var muted = false
  public var soloed = false
  /// Its own key lock; nil follows the row's.
  public var keyLock: Bool?
  /// Its own launch boundary (beats) and fade; nil follows the row's.
  public var quantum: Int?
  public var fade: LoopFade?
  /// Whose tempo it follows; nil follows the row's.
  public var follow: LoopFollow?
  public init(
    muted: Bool = false, soloed: Bool = false, keyLock: Bool? = nil, quantum: Int? = nil,
    fade: LoopFade? = nil, follow: LoopFollow? = nil
  ) {
    self.muted = muted
    self.soloed = soloed
    self.keyLock = keyLock
    self.quantum = quantum
    self.fade = fade
    self.follow = follow
  }
}

/// What a clip was taken from, ready to load again: the deck's source as LOOP went down, the
/// audio for a sample (nil for a net, which is composed again), and the section it was in.
public struct ClipOrigin: Sendable, Equatable {
  public let source: DeckSourceDescriptor
  public let buffer: SampleBuffer?
  public let section: Int?

  public static func == (a: Self, b: Self) -> Bool {
    a.source == b.source && a.section == b.section && (a.buffer == nil) == (b.buffer == nil)
  }
}

extension LoopClip {
  /// The provenance of the take this clip is made from: a crop's original (all the way back),
  /// a sequence's first step.
  var takeProvenance: JSONValue? {
    var p = provenance
    while let op = p?["op"]?.string {
      switch op {
      case "crop": p = p?["parent"]
      case "sequence": p = p?["steps"]?.array?.first?["provenance"]
      default: return p
      }
    }
    return p
  }

  /// The deck's source as LOOP went down (`LoopProvenance.capture`), if it was recorded.
  public var originSource: DeckSourceDescriptor? {
    takeProvenance?["source"].flatMap(DeckSourceDescriptor.init(json:))
  }

  /// The section the deck was playing then (net decks).
  public var originSection: Int? { takeProvenance?["section"]?["index"]?.int }

  /// The genre of the net it came from, for search ("techno"); nil for a sample.
  public var originGenre: String? {
    takeProvenance?["source"]?["share"]?["genre"]?.string
  }

  /// The title of what the deck was playing.
  public var originTitle: String? { takeProvenance?["title"]?.string }

  /// The deck's tempo as LOOP went down (after its tempo fader), if it was recorded.
  public var originBPM: Double? { takeProvenance?["tempo"]?["bpm"]?.double }

  /// The net deck's roles that were off as LOOP went down (switched off, disabled or under a
  /// muted stem).
  public var originRolesOff: [String] {
    takeProvenance?["rolesOff"]?.array?.compactMap(\.string) ?? []
  }

  /// The macros (net and master) running as LOOP went down.
  public var originMacros: [String] {
    takeProvenance?["macros"]?.array?.compactMap(\.string) ?? []
  }

  /// The clip's audio as a 32-bit float stereo WAV (what the library keeps, and an export).
  public func wavData() -> Data {
    let b = buffer
    let audio = RenderedAudio(
      sampleRate: b.sampleRate, left: Array(UnsafeBufferPointer(start: b.left, count: b.length)),
      right: Array(UnsafeBufferPointer(start: b.right, count: b.length)))
    return WAV.encode(audio, float32: true)
  }

  /// A file name for an export or a drag: its title, without characters Finder minds.
  public var fileName: String {
    let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines)
    let base = title.components(separatedBy: bad).joined(separator: "-")
      .trimmingCharacters(in: .whitespaces)
    return (base.isEmpty ? "loop" : base) + ".wav"
  }
}

extension DJEngine {
  /// Keep `clip` as taken off the row at `index` (newest first, once each), so `restoreClip`
  /// can put it back. The library calls it for clips removed in an earlier launch; the
  /// audio joins `sampleLibrary`.
  public func rememberRemovedClip(_ clip: LoopClip, at index: Int) {
    rememberRemovedClip(clip, at: index, sound: ClipSound())
  }

  func rememberRemovedClip(_ clip: LoopClip, at index: Int, sound: ClipSound) {
    removedClips.removeAll { $0.clip.id == clip.id }
    removedClips.insert(RemovedClip(clip: clip, index: index, sound: sound), at: 0)
    registerClipAudio(clip)
  }

  /// Put a removed clip back on the row: at `at`, or where it was (clamped to the row's end).
  /// Its level carries on as it was, and so do its mute, solo, key lock, launch boundary, fade
  /// and tempo follow. Returns false if it is not a removed clip.
  @discardableResult
  public func restoreClip(_ id: String, at: Int? = nil) -> Bool {
    guard let k = removedClips.firstIndex(where: { $0.clip.id == id }) else { return false }
    let r = removedClips.remove(at: k)
    guard clip(id) == nil else { return true }
    sampleLibrary[id] = r.clip.buffer
    clips.insert(r.clip, at: min(max(0, at ?? r.index), clips.count))
    loopCount = max(loopCount, clips.count)
    if r.sound.muted { clipMutes.insert(id) }
    if let k = r.sound.keyLock { clipKeyLocks[id] = k }
    if let q = r.sound.quantum { clipQuanta[id] = q }
    if let f = r.sound.fade { clipFades[id] = f }
    if let f = r.sound.follow { clipFollows[id] = f }
    if r.sound.soloed {
      clipSolos.insert(id)
      pushClipLevels()  // the others go quiet again
    }
    return true
  }

  /// Forget a removed clip (it is deleted for good from the library): it can no longer be
  /// restored.
  public func forgetRemovedClip(_ id: String) {
    removedClips.removeAll { $0.clip.id == id }
  }

  /// Rename clip `id` (on the row or removed). Blank names are ignored.
  public func renameClip(_ id: String, _ title: String) {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    editClip(id) { $0.title = t }
  }

  /// Give clip `id` a colour from `LoopClip.palette` (nil, or a name not in it, clears it).
  public func setClipColor(_ id: String, _ color: String?) {
    let c = color.flatMap { LoopClip.palette.contains($0) ? $0 : nil }
    editClip(id) { $0.color = c }
  }

  func editClip(_ id: String, _ change: (inout LoopClip) -> Void) {
    if let i = clips.firstIndex(where: { $0.id == id }) { change(&clips[i]) }
    if let k = removedClips.firstIndex(where: { $0.clip.id == id }) {
      var c = removedClips[k].clip
      change(&c)
      removedClips[k] = RemovedClip(
        clip: c, index: removedClips[k].index, sound: removedClips[k].sound)
    }
  }

  /// What clip `id` came from, if it can be loaded again: a net always (it is composed again),
  /// a sample only while its audio is in `sampleLibrary` (or it is the demo loop).
  public func clipOrigin(_ id: String) -> ClipOrigin? {
    guard let c = clip(id) ?? removedClips.first(where: { $0.clip.id == id })?.clip,
      let source = c.originSource
    else { return nil }
    switch source {
    case .net, .rawNets:
      return ClipOrigin(source: source, buffer: nil, section: c.originSection)
    case .sample(let sid, _, _):
      if sid == DeckSourceDescriptor.demoID {
        return ClipOrigin(source: source, buffer: nil, section: nil)
      }
      guard let b = sampleLibrary[sid] else { return nil }
      return ClipOrigin(source: source, buffer: b, section: nil)
    case .none: return nil
    }
  }
}
