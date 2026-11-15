import DJRust
import Foundation
import Observation

#if os(iOS)
  import UIKit
#endif

// The port of djandroid's PlayerViewModel (app/src/main/java/se/vevr/djandroid/PlayerViewModel.kt)
// over the same UniFFI `Player`: the same polling, the same preferences, the same calls. The
// engine owns the audio (cpal → CoreAudio); this side only reads its state and pokes it.

/// A bar is 16 ticks (sixteenths) in every beats structure.
let ticksPerBar: Int64 = 16

/// The decks, in mixer order.
public let deckNames = ["A", "B"]

/// What the next Compose will ask for.
struct Draft: Equatable {
  var genre: String
  var seed: Int64
  var structure: String
  var title: String { trackTitle(genre: genre, seed: seed) }
}

/// Auto-next every N bars (the desktop's: seed + 1 on the same song settings, on the bar line).
struct AutoNext: Equatable {
  var on = false
  var bars = 16
  /// djhost `bar_next::PRESETS`; any 1…1024 is allowed.
  static let presets = [4, 8, 16, 32, 64]
}

/// The playhead between polls: the engine's position and tempo at a moment, so a frame can
/// extrapolate where the deck is now. Not observed: a moving playhead never re-renders a page,
/// only the ring's Canvas (inside a TimelineView) reads it.
final class PlayClock: @unchecked Sendable {
  struct Snap {
    var position: Double = 0
    /// Ticks (16ths) per second at the live tempo; 0 while stopped.
    var rate: Double = 0
    var totalTicks: Int64 = 0
    var level: Float = 0
    var at: Date = .distantPast
    func position(at t: Date) -> Double { position + rate * max(0, t.timeIntervalSince(at)) }
  }
  private let lock = NSLock()
  private var _snap = Snap()
  var snap: Snap { lock.withLock { _snap } }
  func update(_ d: DeckState, at t: Date) {
    let s = Snap(
      position: d.position, rate: d.playing ? d.tempo / 60 * 4 : 0, totalTicks: d.totalTicks,
      level: d.level, at: t)
    lock.withLock { _snap = s }
  }
}

/// One deck's screen.
struct DeckUI: Equatable {
  var deck: DeckState?
  var palettes: [Palette] = []
  var draft: Draft?
  var autoNext = AutoNext()
  /// At a song's end, play its next version (the next generated seed).
  var autoAdvance = true
  /// The locked sound (a palette id); nil: not locked.
  var soundLock: String?
  /// The locked tempo (BPM); nil: not locked.
  var tempoLock: Double?
  /// The locked key ("MinorScale:9") and its label ("A minor").
  var keyLock: String?
  var keyLabel: String?
  /// The locked feel ("3:0.12") and its label ("house groove").
  var feelLock: String?
  var feelLabel: String?
  /// Surprise me keeps the genre and only rolls the seed.
  var genreLock = false
}

/// The deck the crossfader favours: the one the lock screen follows.
func leadDeck(_ crossfader: Double?) -> String { (crossfader ?? 0) > 0.5 ? "B" : "A" }

@MainActor @Observable
public final class RustDJModel {
  public internal(set) var starting = true
  public var error: String?
  public internal(set) var info: EngineInfo?
  var decks: [String: DeckUI] = Dictionary(uniqueKeysWithValues: deckNames.map { ($0, DeckUI()) })
  var mix: MixState?
  /// The engine's output stream: live, or lost and being reopened (polled ~once a second).
  var audio: AudioStatus?
  /// The decks the media session's last pause (a headset, the lock screen, an interruption, a
  /// pulled headphone) stopped: its play starts them again.
  var pausedBySession: [String] = []
  var genres: [String] = []
  var structures: [String] = []
  /// Settings › keep the screen awake while anything plays (djandroid's `keep_screen_on_playing`).
  var keepScreenOnWhilePlaying: Bool {
    didSet {
      prefs.set(keepScreenOnWhilePlaying, forKey: "keep_screen_on_playing")
      applyScreenFlag()
    }
  }

  @ObservationIgnored let clocks: [String: PlayClock] = Dictionary(
    uniqueKeysWithValues: deckNames.map { ($0, PlayClock()) })
  @ObservationIgnored nonisolated(unsafe) private var player: Player?
  /// Every call into the engine runs in order on one queue, so a fast slider never lands out of
  /// order and the main thread never waits on the engine's lock.
  @ObservationIgnored private let engineQueue = DispatchQueue(label: "djrust.engine", qos: .userInitiated)
  @ObservationIgnored private let prefs: UserDefaults
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  #if os(macOS)
    @ObservationIgnored private var awake: NSObjectProtocol?
  #endif
  /// The lock screen / Control Centre / media keys (MediaSession.swift), from the engine's start.
  @ObservationIgnored private var media: MediaSession?
  /// `DJ_AUTOPLAY=1` (a launch environment, for screenshots and smoke runs): deck A plays as
  /// soon as its first track is loaded.
  @ObservationIgnored private var autoplay = ProcessInfo.processInfo.environment["DJ_AUTOPLAY"] == "1"
  #if os(iOS)
    /// Interruptions, route changes, the charger (AudioSessionHost.swift).
    @ObservationIgnored private(set) var session: AudioSessionHost?
  #endif

  /// `soundFontDir`: .sf2 banks the engine loads at start (missing: synth voices only).
  public init(soundFontDir: String? = nil, defaults: UserDefaults = .standard) {
    prefs = defaults
    keepScreenOnWhilePlaying = defaults.bool(forKey: "keep_screen_on_playing")
    let dir = soundFontDir ?? RustEngine.defaultSoundFontDir
    Task.detached(priority: .userInitiated) { [weak self] in await self?.start(soundFontDir: dir) }
  }

  /// Deck A keeps the one-deck app's preference keys; B has its own (as djandroid).
  private func key(_ deck: String, _ k: String) -> String { deck == "A" ? k : "\(deck).\(k)" }

  private nonisolated func start(soundFontDir: String) async {
    do {
      #if os(iOS)
        // cpal opens a RemoteIO unit: the session must be a playback one first
        try AudioSessionHost.prepare()
      #endif
      try? FileManager.default.createDirectory(atPath: soundFontDir, withIntermediateDirectories: true)
      let p = try Player(soundfontDir: soundFontDir)
      let g = DJRust.genres()
      let s = DJRust.structures()
      await MainActor.run { self.attach(p, genres: g, structures: s) }
      await poll(p)
    } catch {
      await MainActor.run {
        self.starting = false
        self.error = "\(error)"
      }
    }
  }

  private func attach(_ p: Player, genres g: [String], structures s: [String]) {
    player = p
    genres = g
    structures = s
    for deck in deckNames {
      let auto = AutoNext(
        on: prefs.bool(forKey: key(deck, "auto_next_on")),
        bars: min(1024, max(1, prefs.object(forKey: key(deck, "auto_next_bars")) as? Int ?? 16)))
      let advance = prefs.object(forKey: key(deck, "auto_advance")) as? Bool ?? true
      let sound = prefs.string(forKey: key(deck, "sound_lock"))
      let tempo = prefs.string(forKey: key(deck, "tempo_lock")).flatMap(Double.init)
      let keyL = prefs.string(forKey: key(deck, "key_lock"))
      let feelL = prefs.string(forKey: key(deck, "feel_lock"))
      try? p.setAutoNext(deck: deck, on: auto.on, bars: UInt32(auto.bars))
      try? p.setAutoAdvance(deck: deck, on: advance)
      try? p.setSoundLock(deck: deck, palette: sound)  // before the first track is composed
      try? p.setTempoLock(deck: deck, bpm: tempo)
      try? p.setKeyLock(deck: deck, key: keyL)
      try? p.setFeelLock(deck: deck, feel: feelL)
      let draft = Draft(
        genre: deck == "A" && g.contains("synthwave") ? "synthwave" : (g.randomElement() ?? "house"),
        seed: Int64.random(in: 1..<10_000),
        structure: deck == "A" ? "standard" : "loop")
      decks[deck] = DeckUI(
        draft: draft, autoNext: auto, autoAdvance: advance, soundLock: sound, tempoLock: tempo,
        keyLock: keyL, keyLabel: keyL.map { p.keyLabel(key: $0) }, feelLock: feelL,
        feelLabel: feelL.map { p.feelLabel(feel: $0) },
        genreLock: prefs.bool(forKey: key(deck, "genre_lock")))
    }
    try? p.setAutoLevel(on: prefs.object(forKey: "auto_level") as? Bool ?? true)
    info = p.info()
    #if os(iOS)
      session = AudioSessionHost(model: self)
      session?.engineRate = info.map { Double($0.sampleRate) }
    #endif
    media = MediaSession(model: self)
    starting = false
    // A plays from the first press; B has a track ready to mix in
    for deck in deckNames {
      if let d = decks[deck]?.draft { act { _ = try $0.compose(deck: deck, genre: d.genre, seed: d.seed, structure: d.structure) } }
    }
  }

  /// The decks ~30 times a second, the mixer ~10. The screen gets a deck with its fast parts
  /// (playhead, level) held still: the ring draws those per frame from the clock, so a page
  /// re-renders on a bar, a section or a control change, not 30 times a second.
  private nonisolated func poll(_ p: Player) async {
    var lastSlow: [String: DeckState] = [:]
    var lastKey: [String: String] = [:]
    var n = 0
    while !Task.isCancelled {
      var changed: [String: (DeckState, [Palette]?)] = [:]
      for deck in deckNames {
        guard let d = try? p.state(deck: deck) else { continue }
        clocks[deck]?.update(d, at: Date())
        var slow = d
        slow.tick = d.tick - ((d.tick % ticksPerBar) + ticksPerBar) % ticksPerBar
        slow.position = 0
        slow.level = 0
        if slow == lastSlow[deck] { continue }
        lastSlow[deck] = slow
        // the palette list only changes with the track or the palette
        let k = "\(d.genre ?? ""):\(d.seed ?? 0):\(d.structure ?? ""):\(d.palette)"
        var pals: [Palette]?
        if k != lastKey[deck] {
          lastKey[deck] = k
          pals = ReleaseCatalogue.filter(p.palettes(deck: deck))
        }
        changed[deck] = (slow, pals)
      }
      let mix = n % 3 == 0 ? try? p.mix() : nil
      let audio = n % 30 == 0 ? p.audioStatus() : nil
      n += 1
      if !changed.isEmpty || mix != nil || audio != nil {
        let update = changed
        await MainActor.run {
          for (deck, (s, pals)) in update {
            self.decks[deck]?.deck = s
            if let pals { self.decks[deck]?.palettes = pals }
          }
          if let mix, mix != self.mix { self.mix = mix }
          if let audio, audio != self.audio { self.audio = audio }
          if self.playing { self.pausedBySession = [] }
          if self.autoplay, self.decks["A"]?.deck?.loaded == true {
            self.autoplay = false
            self.togglePlay("A")
          }
          self.media?.update()
          self.applyScreenFlag()
        }
      }
      try? await Task.sleep(for: .milliseconds(33))
    }
  }

  /// Run `f` on the engine queue; a refusal becomes the error dialog.
  private func act(_ f: @escaping @Sendable (Player) throws -> Void) {
    guard let p = player else { return }
    engineQueue.async {
      do { try f(p) } catch {
        let msg = "\(error)"
        Task { @MainActor in self.error = msg }
      }
    }
  }

  // MARK: a deck

  func togglePlay(_ deck: String) {
    let on = !(decks[deck]?.deck?.playing ?? false)
    if on { willPlay() }
    act { try $0.setPlaying(deck: deck, on: on) }
  }

  /// A deck is about to play: a session an interruption left inactive is taken back first.
  private func willPlay() {
    #if os(iOS)
      session?.willPlay()
    #endif
  }

  /// Stop every deck that plays (djandroid DeckHost.pauseAll): the media session's pause, an
  /// interruption another app won, a pulled headphone. They are kept for the session's play.
  func pauseAll() {
    act { p in
      let stopped = deckNames.filter { d in
        guard (try? p.state(deck: d))?.playing == true else { return false }
        return (try? p.setPlaying(deck: d, on: false)) != nil
      }
      guard !stopped.isEmpty else { return }
      Task { @MainActor in self.pausedBySession = stopped }
    }
  }

  /// The media session's play: the decks its pause stopped, else `lead`.
  func resumeFromSession(lead: String) {
    let decks = pausedBySession.isEmpty ? [lead] : pausedBySession
    pausedBySession = []
    willPlay()
    act { p in for d in decks { try p.setPlaying(deck: d, on: true) } }
  }

  /// On a locked deck the tempo lock follows the fader (the engine moves it; this keeps it).
  func setPitch(_ deck: String, _ v: Double) {
    decks[deck]?.deck?.pitch = v
    act { p in
      try p.setPitch(deck: deck, pitch: v)
      self.keepTempoLock(deck, p)
    }
  }

  func setPitchRange(_ deck: String, _ r: Double) {
    act { p in
      try p.setPitchRange(deck: deck, range: r)
      self.keepTempoLock(deck, p)
    }
  }

  func setVolume(_ deck: String, _ v: Double) {
    decks[deck]?.deck?.volume = v
    act { try $0.setVolume(deck: deck, volume: v) }
  }

  /// Lock the deck's tempo to the BPM it plays at now, or unlock it. Nothing loaded: no lock.
  func setTempoLock(_ deck: String, _ on: Bool) {
    var bpm: Double?
    if on {
      guard let d = decks[deck]?.deck, d.loaded else { return }
      bpm = d.baseTempo * (1 + d.pitch * d.pitchRange)
    }
    let lock = bpm
    act { p in
      try p.setTempoLock(deck: deck, bpm: lock)
      self.keepTempoLock(deck, p)
    }
  }

  /// The engine's tempo lock for `deck`, saved (and shown) when it moved.
  private nonisolated func keepTempoLock(_ deck: String, _ p: Player) {
    let now = p.tempoLock(deck: deck)
    Task { @MainActor in
      guard now != self.decks[deck]?.tempoLock else { return }
      self.decks[deck]?.tempoLock = now
      self.prefs.set(now.map { String($0) }, forKey: self.key(deck, "tempo_lock"))
    }
  }

  func setKeyLock(_ deck: String, _ on: Bool) {
    act { p in
      var k: String?
      if on { guard let x = p.deckKey(deck: deck) else { return }; k = x }
      try p.setKeyLock(deck: deck, key: k)
      let label = k.map { p.keyLabel(key: $0) }
      Task { @MainActor in
        self.decks[deck]?.keyLock = k
        self.decks[deck]?.keyLabel = label
        self.prefs.set(k, forKey: self.key(deck, "key_lock"))
      }
    }
  }

  func setFeelLock(_ deck: String, _ on: Bool) {
    act { p in
      var f: String?
      if on { guard let x = p.deckFeel(deck: deck) else { return }; f = x }
      try p.setFeelLock(deck: deck, feel: f)
      let label = f.map { p.feelLabel(feel: $0) }
      Task { @MainActor in
        self.decks[deck]?.feelLock = f
        self.decks[deck]?.feelLabel = label
        self.prefs.set(f, forKey: self.key(deck, "feel_lock"))
      }
    }
  }

  func setGenreLock(_ deck: String, _ on: Bool) {
    decks[deck]?.genreLock = on
    prefs.set(on, forKey: key(deck, "genre_lock"))
  }

  /// A palette picked on a locked deck becomes the locked one (the engine does the same).
  func setPalette(_ deck: String, _ id: String) {
    guard ReleaseCatalogue.offers(id) else { return }
    if decks[deck]?.soundLock != nil { saveSoundLock(deck, id) }
    act { try $0.setPalette(deck: deck, palette: id) }
  }

  func setSoundLock(_ deck: String, _ on: Bool) {
    let id = on ? (decks[deck]?.palettes.first(where: \.selected)?.id ?? "studio") : nil
    saveSoundLock(deck, id)
    act { try $0.setSoundLock(deck: deck, palette: id) }
  }

  private func saveSoundLock(_ deck: String, _ id: String?) {
    decks[deck]?.soundLock = id
    prefs.set(id, forKey: key(deck, "sound_lock"))
  }

  func setAutoNext(_ deck: String, _ f: (inout AutoNext) -> Void) {
    guard var a = decks[deck]?.autoNext else { return }
    f(&a)
    a.bars = min(1024, max(1, a.bars))
    decks[deck]?.autoNext = a
    prefs.set(a.on, forKey: key(deck, "auto_next_on"))
    prefs.set(a.bars, forKey: key(deck, "auto_next_bars"))
    let (on, bars) = (a.on, UInt32(a.bars))
    act { try $0.setAutoNext(deck: deck, on: on, bars: bars) }
  }

  func setAutoAdvance(_ deck: String, _ on: Bool) {
    decks[deck]?.autoAdvance = on
    prefs.set(on, forKey: key(deck, "auto_advance"))
    act { try $0.setAutoAdvance(deck: deck, on: on) }
  }

  /// ⏭: the next version now.
  func next(_ deck: String) { act { _ = try $0.nextTrack(deck: deck) } }

  /// ⏮: the song's top in its first bars, else the track before.
  func previous(_ deck: String) {
    let d = decks[deck]?.deck
    let restart = (d.map { $0.tick >= 2 * ticksPerBar } ?? false) || !(d?.hasPrevious ?? false)
    act { p in if restart { try p.restart(deck: deck) } else { _ = try p.previousTrack(deck: deck) } }
  }

  func editDraft(_ deck: String, _ f: (inout Draft) -> Void) {
    guard var d = decks[deck]?.draft else { return }
    f(&d)
    decks[deck]?.draft = d
  }

  func rollSeed(_ deck: String) { editDraft(deck) { $0.seed = Int64.random(in: 1..<10_000) } }

  func compose(_ deck: String) {
    guard let d = decks[deck]?.draft else { return }
    act { _ = try $0.compose(deck: deck, genre: d.genre, seed: d.seed, structure: d.structure) }
  }

  /// A whole new random track: genre (unless locked) and seed.
  func surprise(_ deck: String) {
    guard !genres.isEmpty else { return }
    let keep = decks[deck]?.genreLock ?? false
    let g = genres
    editDraft(deck) { d in
      if !keep { d.genre = g.randomElement()! }
      d.seed = Int64.random(in: 1..<10_000)
    }
    compose(deck)
  }

  // MARK: roles

  /// Tap: pause a role or let it play (a locked-out one stays off).
  func setRole(_ deck: String, _ role: String, _ on: Bool) {
    act { try $0.setRole(deck: deck, role: role, on: on) }
  }

  /// Long-press: lock a role out of this deck (and the tracks it loads), or let it back in.
  func setRoleDisabled(_ deck: String, _ role: String, _ disabled: Bool) {
    act { try $0.setRoleDisabled(deck: deck, role: role, disabled: disabled) }
  }

  // MARK: the mixer

  func setCrossfader(_ v: Double) {
    mix?.crossfader = v
    act { try $0.setCrossfader(v: v) }
  }

  /// Match `deck`'s tempo and beat to the other deck's.
  func sync(_ deck: String) {
    act { p in
      try p.sync(deck: deck)
      self.keepTempoLock(deck, p)
    }
  }

  func setAutoLevel(_ on: Bool) {
    mix?.autoLevel = on
    prefs.set(on, forKey: "auto_level")
    act { try $0.setAutoLevel(on: on) }
  }

  // MARK: keep the screen on

  /// Something sounds: a deck playing.
  var playing: Bool { decks.values.contains { $0.deck?.playing == true } }

  private var screenHeld = false

  /// On the charger the screen stays on while the app is in front, so the iPad works as a deck
  /// display (djandroid MainActivity.keepAwake); on battery, only with the Settings switch and
  /// while a deck plays. The idle timer only applies in front, so leaving the app ends it too.
  var screenOnCharging: Bool {
    #if os(iOS)
      session?.charging ?? false
    #else
      false
    #endif
  }

  func applyScreenFlag() {
    let on = screenOnCharging || (keepScreenOnWhilePlaying && playing)
    guard on != screenHeld else { return }
    screenHeld = on
    #if os(iOS)
      UIApplication.shared.isIdleTimerDisabled = on
    #elseif os(macOS)
      if on {
        awake = ProcessInfo.processInfo.beginActivity(
          options: [.idleDisplaySleepDisabled, .userInitiated], reason: "djrust is playing")
      } else if let a = awake {
        ProcessInfo.processInfo.endActivity(a)
        awake = nil
      }
    #endif
  }

  public func shutdown() {
    media?.detach()
    #if os(iOS)
      session?.detach()
    #endif
    pollTask?.cancel()
    player?.shutdown()
  }
}

/// What a public build offers in the Sound chooser (djandroid ReleaseCatalogue.kt): the palettes
/// the engine marks local-only are left out unless `DJ_LOCAL_ONLY_PALETTES=1`.
enum ReleaseCatalogue {
  static let withheld: Set<String> = ["minecraft", "retro"]
  static var showsLocalOnly: Bool { ProcessInfo.processInfo.environment["DJ_LOCAL_ONLY_PALETTES"] == "1" }
  static func offers(_ id: String) -> Bool { showsLocalOnly || !withheld.contains(id) }
  static func filter(_ ps: [Palette]) -> [Palette] { showsLocalOnly ? ps : ps.filter { offers($0.id) } }
}
