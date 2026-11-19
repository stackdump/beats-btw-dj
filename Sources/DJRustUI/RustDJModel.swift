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

/// The vocoder's modulator when it is the Wheel tab's instrument (djmobile WHEEL_MODULATOR).
let wheelModulator = "Wheel"

/// The Vox page (djandroid VocoderUi): the engine's state, the pads in the modulating deck's key,
/// and which pads sound. On an iPad two hands hold two pads: their chords sound together.
struct VoxUI: Equatable {
  var state: VocoderState?
  var pads: ChordSet?
  /// The pads sounding, in the order they were pressed (held by fingers, or latched).
  var sounding: [Int] = []
  /// Latch: a tapped pad (or a chord of pads pressed together) keeps sounding until the next.
  var latch = false
  /// The sounds: one tap sets the synth and the vocoder's knobs.
  var presets: [VocoderPreset] = []
  /// The modulating deck's volume before "only the vocoder" pulled it down (nil: not pulled).
  var deckMutedFrom: Double?
  /// "Only the vocoder" with the wheel as the modulator: its strip is muted.
  var wheelMuted = false
  var onlyVocoder: Bool { deckMutedFrom != nil || wheelMuted }
}

/// The held insert effects on the Effects page (djandroid InsertFx.kt InsertUi): each target's
/// chain (filter, bitcrush, delay, reverb). `error`: the last thing the engine refused, shown in
/// place. The target is the Effects page's own (`RustDJModel.fxTarget`), shared with the pads.
struct InsertsUI: Equatable {
  static let targets = ["A", "B", "Wheel", "Master"]
  var chains: [String: InsertChainState] = [:]
  var error: String?
  var anyOn: Bool { chains.values.contains { $0.effects.contains(where: \.on) } }
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
  /// The effects page: the engine's categories and catalogue, and per deck what is on or
  /// waiting for its bar (djandroid FxUi; polled ~10 times a second with the mixer).
  var fxCategories: [FxCategory] = []
  var fxCatalogue: [FxInfo] = []
  var fxActive: [String: [FxActive]] = [:]
  /// The Effects page's target, shared by its pads and its inserts ("A", "B", "Wheel",
  /// "Master"); nil follows the lead deck until one is picked. Kept as `fx.target`.
  var fxTarget: String?
  /// The loop bank (Acid Bass 1–8, Floor & Sub 9) and whether a loop loads with drums.
  var td3Loops: [Td3Loop] = []
  var td3Drums = true
  var vox = VoxUI()
  /// The Perform page (Perform.swift): djhost::perform's moves, polled with the mixer.
  var perform = PerformUI()
  var inserts = InsertsUI()
  /// Output › HEOS speakers (HeosModel.swift).
  var heos = HeosUI()
  @ObservationIgnored var heosPolling = false
  /// Menu › Charts: count my plays toward the charts (nothing is sent in any build yet).
  var chartsOn: Bool {
    didSet {
      prefs.set(chartsOn, forKey: "charts_on")
      charts.on = chartsOn
    }
  }
  /// The plays the switch counts (ChartReporting.swift; nothing is sent in any build yet).
  @ObservationIgnored nonisolated let charts = ChartReporting()
  /// The hardware controllers connected now (the Mac's MIDI layer sets it; Settings shows it).
  public var controllers: [String] = []
  /// The folder the engine read .sf2 banks from at its start.
  public let soundFontDir: String
  /// The Wheel tab (WheelModel.swift); its meters, tempo and stats ~30 times a second.
  var wheel = WheelUI()
  var wheelState: WheelState?
  /// The magnets for the drawing, not observed (MagnetTracker.swift).
  @ObservationIgnored let wheelFeed = WheelFeed()
  /// No magnet moves and the last jump has eased out: the drawing's frame loop rests.
  var wheelStill = true
  /// A finger on the wheel's drawing: the pager and the page's scroll hold still under it.
  var wheelTouching = false
  /// `DJ_AUTOPLAY=wheel:ID`: the load it asked for is on its way.
  @ObservationIgnored var wheelAutoLoading = false
  /// Re-winds run here in order, never on the engine queue: a deck call never waits on one.
  @ObservationIgnored let wheelQueue = DispatchQueue(label: "djrust.wheel", qos: .userInitiated)
  @ObservationIgnored let knobsPending = Latest<WheelKnobs>()
  @ObservationIgnored let brightPending = Latest<Double>()
  @ObservationIgnored let rungPending = Latest<RungPick>()
  /// The Wheel's field log (WheelLog.swift): switch numbers, timings, the queue's depth.
  @ObservationIgnored nonisolated let wheelLog = WheelLogCounters()
  @ObservationIgnored private var insertsSaveTask: Task<Void, Never>?
  /// The pads under a finger now (a gesture's state, not shown).
  @ObservationIgnored private var fingers: Set<Int> = []
  /// A latched chord stopped by a tap on it: the lift of that tap starts nothing.
  @ObservationIgnored private var stopping = false
  /// The genre the pads were built for.
  @ObservationIgnored private var padsGenre: String?
  /// Settings › keep the screen awake while anything plays (djandroid's `keep_screen_on_playing`).
  var keepScreenOnWhilePlaying: Bool {
    didSet {
      prefs.set(keepScreenOnWhilePlaying, forKey: "keep_screen_on_playing")
      applyScreenFlag()
    }
  }

  @ObservationIgnored let clocks: [String: PlayClock] = Dictionary(
    uniqueKeysWithValues: deckNames.map { ($0, PlayClock()) })
  @ObservationIgnored nonisolated(unsafe) var player: Player?
  /// Every call into the engine runs in order on one queue, so a fast slider never lands out of
  /// order and the main thread never waits on the engine's lock.
  @ObservationIgnored let engineQueue = DispatchQueue(label: "djrust.engine", qos: .userInitiated)
  /// Thread-safe (UserDefaults): the wheel's queue reads its keys too.
  @ObservationIgnored nonisolated(unsafe) let prefs: UserDefaults
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  #if os(macOS)
    @ObservationIgnored private var awake: NSObjectProtocol?
  #endif
  /// The lock screen / Control Centre / media keys (MediaSession.swift), from the engine's start.
  @ObservationIgnored private var media: MediaSession?
  /// `DJ_AUTOPLAY` (a launch environment, for screenshots and smoke runs): "1" plays deck A as
  /// soon as its first track is loaded; "td3:N" loads loop group N on both decks instead;
  /// "vox:N" plays A and holds chord pad N (the vocoder comes on); "wheel[:ID[:A]]" loads wheel
  /// instrument ID (none or empty: the one restored) and plays it, with ":A" deck A too.
  @ObservationIgnored var autoplay = ProcessInfo.processInfo.environment["DJ_AUTOPLAY"]
  #if os(iOS)
    /// Interruptions, route changes, the charger (AudioSessionHost.swift).
    @ObservationIgnored private(set) var session: AudioSessionHost?
  #endif

  /// `soundFontDir`: .sf2 banks the engine loads at start (missing: synth voices only).
  public init(soundFontDir: String? = nil, defaults: UserDefaults = .standard) {
    prefs = defaults
    let bundle = Bundle.main.infoDictionary
    WheelLog.i(
      "app.start",
      ["version": bundle?["CFBundleShortVersionString"] as? String, "code": bundle?["CFBundleVersion"] as? String])
    keepScreenOnWhilePlaying = defaults.bool(forKey: "keep_screen_on_playing")
    chartsOn = defaults.bool(forKey: "charts_on")
    let dir = soundFontDir ?? RustEngine.defaultSoundFontDir
    self.soundFontDir = dir
    charts.on = chartsOn
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
    fxCategories = p.fxCategories()
    fxCatalogue = p.fxCatalogue()
    td3Loops = DJRust.td3Loops()
    td3Drums = prefs.object(forKey: "td3_drums") as? Bool ?? true
    // the vocoder's auto level and sound, as last left
    try? p.setVocoderAutoLevel(on: prefs.object(forKey: "vocoder_auto_level") as? Bool ?? true)
    try? p.vocoderPreset(id: prefs.string(forKey: "vocoder_preset") ?? "talking-drums")
    vox.presets = DJRust.vocoderPresets()
    startPerform(p)
    // the inserts' knobs as last left (the switches are not kept: a fresh start has every one off)
    if let json = prefs.string(forKey: "inserts.chains") { _ = try? p.insertsRestore(json: json, switches: false) }
    // the Effects page's target as last picked (before the Inserts tab folded into Effects, the
    // inserts kept their own as `inserts.target`: that one carries over once)
    fxTarget = (prefs.string(forKey: "fx.target") ?? prefs.string(forKey: "inserts.target"))
      .flatMap { InsertsUI.targets.contains($0) ? $0 : nil }
    refreshInserts()
    attachWheel(p)
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
    var crossfader: Double?
    var n = 0
    while !Task.isCancelled {
      var changed: [String: (DeckState, [Palette]?)] = [:]
      for deck in deckNames {
        guard let d = try? p.state(deck: deck) else { continue }
        clocks[deck]?.update(d, at: Date())
        let heard = ChartReporting.heard(deck, playing: d.playing, volume: d.volume, crossfader: crossfader)
        charts.observe(
          deck, genre: d.loaded ? d.genre : nil, seed: d.seed, structure: d.structure, title: d.title, heard: heard,
          nowMs: Int64(Date().timeIntervalSince1970 * 1000))
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
      if let mix { crossfader = mix.crossfader }
      let fx: [String: [FxActive]]? =
        n % 3 == 0
        ? Dictionary(uniqueKeysWithValues: InsertsUI.targets.map { d in (d, (try? p.fxState(target: d)) ?? []) }) : nil
      let audio = n % 30 == 0 ? p.audioStatus() : nil
      let voc = n % 3 == 0 ? try? p.vocoder() : nil
      let moves = n % 3 == 0 ? try? p.movesState() : nil
      n += 1
      if !changed.isEmpty || mix != nil || audio != nil || fx != nil || voc != nil || moves != nil {
        let update = changed
        await MainActor.run {
          for (deck, (s, pals)) in update {
            self.decks[deck]?.deck = s
            if let pals { self.decks[deck]?.palettes = pals }
          }
          if let mix, mix != self.mix { self.mix = mix }
          if let audio, audio != self.audio { self.audio = audio }
          if let fx, fx != self.fxActive { self.fxActive = fx }
          if let voc { self.updateVox(voc) }
          if let moves, moves != self.perform.state { self.perform.state = moves }
          if self.playing { self.pausedBySession = [] }
          if let a = self.autoplay, a == "wheel" || a.hasPrefix("wheel:") {
            self.wheelAutoplay(a)
          } else if let a = self.autoplay, self.decks["A"]?.deck?.loaded == true {
            self.autoplay = nil
            if a.hasPrefix("td3:"), let g = UInt32(a.dropFirst(4)) {
              self.loadTd3Pair(g)
            } else {
              self.togglePlay("A")
              if a.hasPrefix("vox:"), let i = Int(a.dropFirst(4)) { self.padDown(i) }
            }
          }
          self.media?.update()
          self.applyScreenFlag()
        }
      }
      try? await Task.sleep(for: .milliseconds(33))
    }
  }

  /// Run `f` on the engine queue; a refusal becomes the error dialog.
  func act(_ f: @escaping @Sendable (Player) throws -> Void) {
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

  /// The wheel is about to sound: as a deck's play.
  func willPlayWheel() { willPlay() }

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

  // MARK: tricks and macros (djandroid PlayerViewModel "tricks and macros")

  /// Engage an effect on a deck's next bar: for 1–4 bars, latched, or (a transition) held.
  func engage(_ deck: String, _ id: String, _ mode: FxMode) {
    act { try $0.engage(target: deck, id: id, mode: mode) }
  }

  /// A held pad lifted: off at once.
  func fxRelease(_ deck: String, _ id: String) { act { try $0.fxRelease(target: deck, id: id) } }

  /// A latched (or running) pad pressed again: off on the next bar.
  func fxUnlatch(_ deck: String, _ id: String) { act { try $0.fxUnlatch(target: deck, id: id) } }

  /// An Acid Bass trick on (held) or off, on this deck's Acid Bass loop.
  func fxAcid(_ deck: String, _ id: String, _ on: Bool) { act { try $0.fxAcid(deck: deck, id: id, on: on) } }

  /// The filter knob under a hand: answers at once, on no bar.
  func trickKnob(_ deck: String, _ v: Double) { act { try $0.trickKnob(target: deck, v: v) } }

  /// The Effects page's target: its pads and its inserts act there.
  func selectFxTarget(_ t: String) {
    fxTarget = t
    prefs.set(t, forKey: "fx.target")
  }

  /// PANIC on a target: end its macros, tricks and latches at once, and switch its four inserts
  /// off (their tails ring out). The other targets keep theirs.
  func fxPanic(_ target: String) {
    act { try $0.panic(deck: target) }
    for e in inserts.chains[target]?.effects ?? [] where e.on { setInsertOn(target, e.id, false) }
  }

  // MARK: the loop bank (Acid Bass)

  func setTd3Drums(_ on: Bool) {
    td3Drums = on
    prefs.set(on, forKey: "td3_drums")
  }

  /// Loop `id` on `deck`, playing, on the bar with the other deck.
  func loadTd3(_ deck: String, _ id: String) {
    let drums = td3Drums
    willPlay()
    act { try $0.loadTd3(deck: deck, id: id, drums: drums) }
  }

  /// A group's A on deck A and its B on deck B: the crossfader swaps the answer in.
  func loadTd3Pair(_ group: UInt32) {
    let drums = td3Drums
    willPlay()
    act { try $0.loadTd3Pair(group: group, drums: drums) }
  }

  // MARK: the vocoder (djandroid PlayerViewModel "the vocoder")

  /// A poll's vocoder state; the pads follow the key of the deck that shapes the synth (else the
  /// lead deck: the wheel has no genre to take chords from).
  private func updateVox(_ voc: VocoderState) {
    if voc != vox.state { vox.state = voc }
    refreshPads()
  }

  private func refreshPads() {
    let keyDeck = vox.state?.modulator.flatMap { deckNames.contains($0) ? $0 : nil } ?? leadDeck(mix?.crossfader)
    if let genre = decks[keyDeck]?.deck?.genre, genre != padsGenre {
      padsGenre = genre
      vox.pads = chordPads(genre: genre)
    }
  }

  /// The vocoder's switch: on or off with its routing as it is (on with nothing routed yet: the
  /// synth shaped by the lead deck). Off brings back what "only the vocoder" pulled out.
  func setVocoderOn(_ on: Bool) {
    if !on {
      if vox.onlyVocoder { setOnlyVocoder(false) }
      vox.sounding = []
    }
    let lead = leadDeck(mix?.crossfader)
    act { try $0.setVocoderOn(on: on, defaultModulator: lead) }
  }

  /// What the carrier and modulator pickers offer (the desktop Vocoder window's list), read on
  /// the engine queue when a picker opens.
  func vocoderSources() async -> [VocoderSource] {
    guard let p = player else { return [] }
    return await withCheckedContinuation { c in
      engineQueue.async { c.resume(returning: (try? p.vocoderSources()) ?? []) }
    }
  }

  /// One side of the vocoder ("carrier" or "modulator") to a source by its id. A new modulator
  /// first brings back what "only the vocoder" pulled out of the mix.
  func vocoderRoute(_ side: String, _ id: String) {
    if side == "modulator" && vox.onlyVocoder { setOnlyVocoder(false) }
    act { try $0.vocoderRoute(side: side, id: id) }
  }

  /// The desktop's ⇄: the carrier becomes the modulator and the modulator the carrier.
  func vocoderSwap() {
    if vox.onlyVocoder { setOnlyVocoder(false) }
    act { try $0.vocoderSwap() }
  }

  func setLatch(_ on: Bool) {
    vox.latch = on
    if !on { releaseChord() }
  }

  /// A finger on pad `i`. A new touch (no finger down) starts a new chord — or, latched, a tap
  /// on the one pad sounding stops it; a finger joining held ones adds its chord to theirs. With
  /// the vocoder off a pad turns it on, as routed (nothing routed yet: shaped by the lead deck).
  func padDown(_ i: Int) {
    if vox.pads == nil { refreshPads() }  // a press before the vocoder's first poll
    guard let pads = vox.pads?.pads, pads.indices.contains(i) else { return }
    if fingers.isEmpty {
      if vox.latch && vox.sounding == [i] {
        fingers.insert(i)
        stopping = true
        releaseChord()
        return
      }
      stopping = false
      vox.sounding = []
    }
    fingers.insert(i)
    if stopping { return }
    if !vox.sounding.contains(i) { vox.sounding.append(i) }
    sendChord(pads)
  }

  /// A finger off pad `i`: unlatched, its chord stops (the others held play on).
  func padUp(_ i: Int) {
    fingers.remove(i)
    if stopping {
      if fingers.isEmpty { stopping = false }
      return
    }
    guard !vox.latch else { return }
    vox.sounding.removeAll { $0 == i }
    if vox.sounding.isEmpty { releaseChord() } else if let pads = vox.pads?.pads { sendChord(pads) }
  }

  /// The pads sounding as one set of notes (lowest first; the synth has 8 voices).
  private func sendChord(_ pads: [ChordPad]) {
    var seen = Set<UInt8>()
    let notes = vox.sounding.filter { pads.indices.contains($0) }.flatMap { [UInt8](pads[$0].notes) }
      .filter { seen.insert($0).inserted }.sorted()
    let turnOn = vox.state?.on == true ? nil : leadDeck(mix?.crossfader)
    if let turnOn { vox.state?.on = true }
    act { p in
      if let turnOn { try p.setVocoderOn(on: true, defaultModulator: turnOn) }
      try p.vocoderNotes(notes: Data(notes))
    }
  }

  private func releaseChord() {
    vox.sounding = []
    act { try $0.vocoderNotes(notes: Data()) }
  }

  /// One of the vocoder's sounds; remembered for the next start.
  func vocoderPreset(_ id: String) {
    vox.state?.preset = id
    vox.state?.edited = false
    prefs.set(id, forKey: "vocoder_preset")
    act { try $0.vocoderPreset(id: id) }
  }

  func setVocoderAutoLevel(_ on: Bool) {
    vox.state?.autoLevel = on
    prefs.set(on, forKey: "vocoder_auto_level")
    act { try $0.setVocoderAutoLevel(on: on) }
  }

  /// Only the vocoder: the modulating deck's volume down, or the wheel's strip muted (either
  /// still shapes the synth: the vocoder taps its source before the fader), or back.
  func setOnlyVocoder(_ on: Bool) {
    guard let deck = vox.state?.modulator else { return }
    if deck == wheelModulator {
      guard on != vox.wheelMuted else { return }
      vox.wheelMuted = on
      act { try $0.wheelInMix(on: !on) }
      return
    }
    if on {
      guard vox.deckMutedFrom == nil, let vol = decks[deck]?.deck?.volume else { return }
      vox.deckMutedFrom = vol
      setVolume(deck, 0)
    } else {
      guard let back = vox.deckMutedFrom else { return }
      vox.deckMutedFrom = nil
      setVolume(deck, back)
    }
  }

  func vocoderSet(_ name: String, _ value: Double) {
    if var s = vox.state {
      s.knobs = s.knobs.map { k in
        var k = k
        if k.name == name { k.value = value }
        return k
      }
      s.edited = s.edited || name != "volume"
      vox.state = s
    }
    act { _ = try $0.vocoderSet(name: name, value: value) }
  }

  // MARK: insert effects (djandroid InsertFx.kt)

  /// Read every chain (the Effects page's poll, twice a second while it shows, and after each change):
  /// the tempos the delays follow, and anything changed elsewhere.
  func refreshInserts() {
    guard let p = player else { return }
    engineQueue.async {
      guard let list = try? p.insertStates() else { return }
      let m = Dictionary(list.map { ($0.target, $0) }, uniquingKeysWith: { a, _ in a })
      Task { @MainActor in if m != self.inserts.chains { self.inserts.chains = m } }
    }
  }

  /// An inserts call: a refusal shows on the page (not the dialog), then the chains are read
  /// again and the knobs kept.
  private func insertCall(_ f: @escaping @Sendable (Player) throws -> Void) {
    guard let p = player else { return }
    engineQueue.async {
      var err: String?
      do { try f(p) } catch { err = "\(error)" }
      let e = err
      Task { @MainActor in
        self.inserts.error = e
        self.refreshInserts()
        self.saveInserts()
      }
    }
  }

  private func editInsert(_ target: String, _ f: (inout InsertEffect) -> Void) {
    guard var c = inserts.chains[target] else { return }
    c.effects = c.effects.map { e in
      var e = e
      f(&e)
      return e
    }
    inserts.chains[target] = c
  }

  /// ALL OFF: every held effect on every target off (the tails ring out); the knobs stay.
  func insertsAllOff() {
    for t in inserts.chains.keys { editInsert(t) { $0.on = false } }
    insertCall { try $0.insertsOff() }
  }

  func setInsertOn(_ target: String, _ effect: String, _ on: Bool) {
    editInsert(target) { if $0.id == effect { $0.on = on } }
    insertCall { try $0.insertOn(target: target, effect: effect, on: on) }
  }

  /// A knob: the screen moves at once, the engine's reading ("LP 1.2 kHz") replaces the label.
  func setInsertKnob(_ target: String, _ knob: String, _ value: Double) {
    editInsert(target) { e in
      e.knobs = e.knobs.map { k in
        var k = k
        if k.id == knob { k.value = value }
        return k
      }
    }
    guard let p = player else { return }
    engineQueue.async {
      guard let shown = try? p.insertParam(target: target, param: knob, value: value) else { return }
      Task { @MainActor in
        self.editInsert(target) { e in
          e.knobs = e.knobs.map { k in
            var k = k
            if k.id == knob { k.display = shown }
            return k
          }
        }
        self.saveInserts()
      }
    }
  }

  /// Kept a moment after the last move, not on every slider step.
  private func saveInserts() {
    insertsSaveTask?.cancel()
    insertsSaveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let p = self.player else { return }
      self.engineQueue.async {
        guard let json = try? p.insertsSave() else { return }
        Task { @MainActor in self.prefs.set(json, forKey: "inserts.chains") }
      }
    }
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
