import AppKit
import DJCore
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot of one deck for SwiftUI (Deck itself is not observable).
struct DeckState: Equatable {
  var title = "—"
  var playing = false
  var platterSeconds = 0.0
  var positionSeconds = 0.0
  var duration = 0.0
  var rate = 0.0
  var volume = 0.8
  var filter = 0.5
  var pitch = 0.0
  var nudge = 0.0
  var touching = false
  var cues: Set<Int> = []
  // live-net decks
  var isNet = false
  var bpm: Double?
  var beatInBar = 0
  var beatPhase = 0.0
  var sections: [Deck.SectionInfo] = []
  var currentSection: Int?
  /// Net decks: the bar the song is in (1-based) and how many it has.
  var bar = 0
  var bars = 0
  var roles: [String] = []
  var rolesOn: Set<String> = []
  var nextReady = false
  var nextComposing = false
  /// A mix-out tail plays (`Deck.isMixingOut`) / a mix-in's rest is to come or playing.
  var mixingOut = false
  var mixingIn = false
  /// The share CID of the net on the deck (what a favorite of it is named by); nil for samples.
  var sourceCID: String?
  /// Each role's instrument and what it could play instead (`Deck.roleVoices`).
  var voices: [RoleVoice] = []
  /// What each of those channels plays (`Deck.channelVoice`), by channel: the sound panel's
  /// starting point.
  var channelVoices: [Int: ChannelVoice] = [:]
  /// The channels' voice settings this session (the sound panel), by channel.
  var voiceSettings: [Int: VoiceSetting] = [:]
  /// The drum kit the net's drums play (`Deck.kit`), nil = beats' synth kit.
  var kit: String?
  /// The sound palette the track plays from (`Deck.palette`), nil = the default.
  var palette: String?
  /// Each palette role, what it plays and what it could (`Deck.roleSounds`).
  var roleSounds: [RoleSoundRow] = []
  var quantize = "off"
  var scrubbing = false
  var pfl = false
  var overview: WaveformOverview?
  var overlay: WaveformOverlay?
  var snapshot: NetSnapshot?
  var timeline: SectionTimeline?
  /// The ring's arc layer: dimmed while playing, turned by the Auto-DJ swing (SPEC 22).
  var ringArcs = RingArcs()
  /// Running macros and the chase over the roles they hold muted (SPEC 26).
  var macroPulse = MacroPulseState()
  /// The master-chain macros (FX, pitch, feel) in effect.
  var masterRunning: Set<MasterMacro> = []
  /// What Hit 1–4 fire (`Deck.stingers`), as their buttons' help says it.
  var stingers: [String] = []
  /// The LOOP-record clip the deck is playing, if it is playing one.
  var clipID: String?
  /// Roles disabled on the deck (they stay off through new tracks).
  var disabledRoles: Set<String> = []
  /// Auto-next: when the song ends, the next version plays (`Deck.autoAdvance`).
  var autoAdvance = false
  var reverb = ReverbState()
  /// The deck's walk (`Deck.wander`): on, pace, locks, its log.
  var wander = WanderState()
  /// Bars to the walk's next move (or, paused, until it resumes); nil while off.
  var wanderCountdown: Int?
  /// Why a walk that is on stands still ("every move is locked"), if it does.
  var wanderIdle: String?
}

/// A channel's reverb knobs, for SwiftUI.
struct ReverbState: Equatable {
  var wet = 0.0
  var size = 0.5
  var tone = 0.5
  var isOn: Bool { wet >= 0.005 }
  var decaySeconds: Double { 0.25 * pow(32, size) }
  func near(_ o: ReverbState) -> Bool {
    abs(wet - o.wet) < 0.01 && abs(size - o.size) < 0.01 && abs(tone - o.tone) < 0.01
      || (!isOn && !o.isOn)
  }
}

extension ReverbState {
  init(_ r: DeckReverb) { self.init(wet: r.wet, size: r.size, tone: r.tone) }
}

@MainActor @Observable
public final class AppModel {
  public var status = "starting…"
  var devices: [ControllerHub.Device] = []
  var lastMessage = ""
  var decks: [String: DeckState] = ["A": .init(), "B": .init()]
  /// LOOP record: the row of clips under the decks, the loop channel, and takes in progress.
  var clips: [ClipState] = []
  var loopChannel = LoopChannelState()
  var recording: [String: RecordingState] = [:]
  /// Loops picked to join into a sequence.
  var selectedClips: Set<String> = []
  /// Loops taken off the row, newest first: this launch's and the library's `removed/`.
  var removedLoops: [RemovedLoop] = []
  /// The last loop taken off the row, while its "Undo" shows (`LoopRemoval.undoSeconds`).
  var lastRemoval: LoopRemoval?
  /// What the Loops row shows (its header's chips, search and tempo filter).
  var loopFilter = LoopFilter()
  /// The first playing deck's tempo (`decksPlayingTempo`), for the row's tempo filter.
  private(set) var playingTempo: Double?
  /// The library's `removed/` as last read (after each save).
  @ObservationIgnored var diskRemoved: [RemovedLoop] = []
  /// Bumped by every change to `diskRemoved` made on the main thread (`deleteForever`): a list
  /// read on `saveQueue` before it is stale and is dropped (`publishRemoved`).
  @ObservationIgnored var diskRemovedEpoch = 0
  /// Per clip, whether its source can be loaded again; dropped when `sampleLibrary` changes.
  @ObservationIgnored var originCache: [String: Bool] = [:]
  @ObservationIgnored var originCacheSamples = -1
  /// What loops start and stop on, in beats (the row's "Launch on"). Saved in the app's defaults
  /// as `loopQuantize`.
  var loopQuantum = DJEngine.defaultLoopQuantum
  static let loopQuantizeKey = "loopQuantize"
  /// Whose tempo the loops follow (the row's "Tempo"), and the deck that is now; saved as
  /// `loopFollow`.
  var loopFollow = LoopFollow.louder
  var followingDeck: String?
  static let loopFollowKey = "loopFollow"
  /// The saved scenes, as chips.
  var scenes: [SceneState] = []
  var crossfader = 0.5
  /// The two-deck autopilot as the mixer's foot shows it (AutoMix.swift), refreshed by `poll`.
  var autoMix = AutoMixDisplay()
  /// Auto-mix's length and phrases, remembered across launches (on is not: an autopilot never
  /// starts itself).
  static let autoMixBarsKey = "autoMix.bars"
  static let autoMixEveryKey = "autoMix.every"
  var master = 0.8
  var headphoneMix = 0.0
  var headphoneLevel = 0.7
  var inpulseOutput: AudioOutputDevice?
  var inpulseRouted = false
  /// Finds the Inpulse's audio device; tests swap it so they never route (or restart) the real one.
  @ObservationIgnored var findInpulse: () -> AudioOutputDevice? = { AudioDevices.inpulse() }
  var padLights: [String: [PadLight]] = [:]
  /// Every attached controller's LEDs by profile name, for the device map (SPEC 25).
  var deviceLights: [String: DeviceLights] = [:]
  var padPort: String?
  var showPads = false
  var showMap = false
  /// The Controllers panel: every device drawn with its bindings.
  var showControllers = false
  /// The Soundboard panel (SoundboardView.swift): every loop as one big pad. Saved in the app's
  /// defaults as `showSoundboard` (`setShowSoundboard`); closed until opened.
  var showSoundboard = false
  static let showSoundboardKey = "showSoundboard"
  /// What the Soundboard shows (its Row / Stock / Crate switch). Saved in the app's defaults as
  /// `soundboardPage`.
  var soundboardPage = SoundboardPage.row
  static let soundboardPageKey = "soundboardPage"
  /// The Stock page's category strip ("" = all) and search.
  var stockPadCategory = ""
  var stockPadQuery = ""
  /// Stock loops being decoded for the row from their pads (shown as loading).
  var stockPadsLoading: Set<String> = []
  /// Clips being rendered again with other instruments (`retuneClip`; their pads say
  /// "retuning…").
  var retuningClips: Set<String> = []
  /// The crate the Crate page shows (`setSoundboardCrate`), saved in the app's defaults as
  /// `soundboardCrate`; nil (or a crate since deleted) shows the first crate.
  var soundboardCrate: String?
  static let soundboardCrateKey = "soundboardCrate"
  /// The Loops row's "Loops master FX" strip (LoopMasterFxStrip): folded open or not.
  var showLoopMasterFx = false
  /// The FX unit panel (FxUnitViews.swift), under the decks. Saved in the app's defaults as
  /// `showFxUnit`; closed until opened.
  var showFxUnit = false
  static let showFxUnitKey = "showFxUnit"
  /// Each target's FX unit as of the last poll (A, B, L).
  var fxUnits: [String: FxUnitState] = [:]
  /// The target the FX unit panel aims at; nil follows the focus (`DJEngine.focus`).
  var fxTarget: String?
  /// `DJEngine.focus` as of the last poll.
  var fxFocus = "A"
  /// What the XY pad's vertical axis moves (its horizontal is the filter).
  var fxY = FxParam.crush
  /// Reset and kill wait for the next beat.
  var fxOnBeat = false
  /// Dragged knobs, recorded at most 30 times a second (`FxUnitCoalescer`).
  @ObservationIgnored var fxCoalescer = FxUnitCoalescer()
  /// Keep the display from idling to sleep while the app is open (bottom bar "Awake"). Saved
  /// in the app's defaults as `keepScreenAwake`; off until turned on.
  private(set) var keepScreenAwake = false
  @ObservationIgnored let screenWakeLock = ScreenWakeLock()
  @ObservationIgnored var defaults = UserDefaults.standard
  static let keepScreenAwakeKey = "keepScreenAwake"
  /// How many bars a quick tap of LOOP records (1, 2, 4 or 8; 2 until changed). Saved in the
  /// app's defaults as `loopTapBars`; sent with each press, and given to the engine for the
  /// controllers' LOOP buttons (`DJEngine.tapTakeBars`, through `perform(.tapBars)`).
  private(set) var tapBars = 2
  static let tapBarsKey = "loopTapBars"
  static let tapBarChoices = [1, 2, 4, 8]
  /// Sample loads auto-levelled to the app's reference (`Deck.autoGain`, LevelMatch.swift), per
  /// deck: the Load panel's "Auto level" chip. The last choice is saved as `autoGain` in the
  /// app's defaults and every deck starts with it (through `perform`, so a journal has it).
  private(set) var autoGain: [String: Bool] = [:]
  static let autoGainKey = "autoGain"
  // Scopes (SPEC modes 1…6): the panel under the decks, and what it shows.
  var showScopes = false
  var scopeKind: ScopeKind = .live
  var scopeSource: ScopeSource = .master
  var scopeMeasured = false
  /// What the panel's height rule (scope.js `viewHeight`) works from: the usable height of the
  /// screen the window is on (not the window, which grows with the panel); 800 until known.
  var scopeWindowHeight = 800.0
  /// Hands out the scope feeds; made once the engine exists (`start()`).
  private(set) var scopeHub: ScopeHub?
  /// The Stage window's model (SPEC modes 7…21); made with the hub.
  public private(set) var stageModel: StageModel?
  /// Open / close the Stage window from the control socket (`view`'s `stage.open`): set by the
  /// main window from its `openWindow` / `dismissWindow`; nil without a window (tests).
  @ObservationIgnored var openStageWindow: (() -> Void)?
  @ObservationIgnored var closeStageWindow: (() -> Void)?
  var walk: ControlWalk?
  /// Starred tracks and samples, newest first (`FavoritesStore`).
  var favorites: [Favorite] = []
  /// Saved ways to play each instrument (`VoiceVariationStore`), by instrument.
  var variations: [String: [VoiceVariation]] = [:]
  @ObservationIgnored let variationStore: VoiceVariationStore
  /// The tag the Favorites panels show (nil: all).
  var favoriteTag: String?
  /// Buttons the user locked (right-click ▸ Disable), by `DJActionKind.lockKey`; mirrored to
  /// the engine so the controllers' buttons for the same actions are locked too. Saved in the
  /// app's defaults (`lockedButtons`).
  var lockedButtons: Set<String> = []
  static let lockedButtonsKey = "lockedButtons"
  static func disabledRolesKey(_ deck: String) -> String { "disabledRoles.\(deck)" }
  /// A deck's wander locks and pace, remembered across launches (wander itself starts off).
  static func wanderLocksKey(_ deck: String) -> String { "wanderLocks.\(deck)" }
  static func wanderPaceKey(_ deck: String) -> String { "wanderPace.\(deck)" }
  @ObservationIgnored let favoritesStore: FavoritesStore
  /// The journal (JournalModel.swift): the run's event log, the notes it holds, its latest lines.
  var notes: [TrackNote] = []
  var journalEntries: [JournalEntry] = []
  /// Per deck, the key its track's notes are under (`NoteTarget.key`), refreshed by `poll`.
  var deckNoteKeys: [String: String] = [:]
  @ObservationIgnored let notesStore: NotesStore
  @ObservationIgnored var journal: Journal?
  @ObservationIgnored let journalDir: URL?
  @ObservationIgnored var journalSeen = -1
  /// The Apple Loops on this Mac (`StockLoopLibrary`), loaded the first time the Load panel asks.
  var stockLoops: [StockLoop] = []
  var stockLoopsLoading = false
  @ObservationIgnored let loopLibrary: StockLoopLibrary
  /// Where LOOP-record clips are kept between launches: the app's own (`LoopLibrary()`) for the
  /// real engine; for an injected one only if the test passes one.
  @ObservationIgnored var takeStore: LoopLibrary?
  /// The row as last saved (ids, names and colours in order), so a poll saves only when it
  /// changed.
  @ObservationIgnored private var savedRow: [String] = []
  /// The scenes as last saved, likewise.
  @ObservationIgnored private var savedScenes: [LoopScene] = []
  /// Saves (and the library's other writes) run off the main thread, one at a time.
  @ObservationIgnored let saveQueue = DispatchQueue(label: "dj-vevr-se.loops.save")
  /// Per deck, the source its `sourceCID` was hashed from, so a poll doesn't re-hash.
  @ObservationIgnored private var sourceCIDs: [String: (DeckSourceDescriptor, String)] = [:]
  var walkReportPath: String?
  var lastControl: (device: String, group: String, index: Int, at: Date)?

  private var dj: DJEngine?
  private var hub: ControllerHub?
  private var refresh: Timer?
  private var injectedRouter: ControllerRouter?
  @ObservationIgnored var controlServer: ControlServer?
  /// Minecraft gameplay events already taken, and each deck's last stinger bar
  /// (`minecraftEvents`, MinecraftEvents.swift).
  @ObservationIgnored var minecraftFeed = MinecraftEventFeed()
  /// The audition playing now (held so it isn't freed mid-sound).
  @ObservationIgnored var auditionSound: NSSound?
  /// Samplers for auditions, apart from the decks' (a sampler renders on one thread only).
  @ObservationIgnored lazy var auditionBank = SamplerBank(sampleRate: dj?.sampleRate ?? 48_000)

  /// The engine and router the UI drives (nil until `start`).
  var engine: DJEngine? { dj }
  var router: ControllerRouter? { hub?.router ?? injectedRouter }

  /// Is the Shift key down? The on-screen APC shows its SHIFT layer (the loop page) meanwhile.
  /// Tests inject their own.
  @ObservationIgnored var shiftKeyHeld: () -> Bool = { NSEvent.modifierFlags.contains(.shift) }
  /// Seconds on a steadily increasing clock: the time base of display animations (the ring
  /// swing). Tests inject their own.
  @ObservationIgnored var uptime: () -> Double = { ProcessInfo.processInfo.systemUptime }
  /// Per net deck, the Auto-DJ swing of its ring.
  @ObservationIgnored private var ringSpins: [String: RingSpin] = [:]
  /// Per net deck, the macro chase over its role toggles, and when it was last advanced.
  @ObservationIgnored private var chaseBoards: [String: MacroChaseBoard] = [:]
  @ObservationIgnored private var chaseClock: [String: Double] = [:]
  /// How often the rings' snapshot is rebuilt at the current visual level (SPEC mode 27).
  @ObservationIgnored private var ringGate = RingRenderGate()

  /// `engine`: drive this engine instead of building the real one (tests, previews). No
  /// controllers are opened and nothing is polled until `poll()` is called. `perf`: the visual
  /// quality monitor for an injected engine (a test's own clock); the default is a plain one.
  /// `favorites`: where starred tracks are kept (tests pass a temporary file).
  public init(
    engine: DJEngine? = nil, perf: PerfMonitor? = nil, favorites: FavoritesStore = FavoritesStore(),
    loops: StockLoopLibrary = StockLoopLibrary(), takes: LoopLibrary? = nil,
    voices: VoiceVariationStore = VoiceVariationStore(), notes: NotesStore = NotesStore(),
    journal: URL? = nil
  ) {
    notesStore = notes
    journalDir = journal
    self.notes = notes.list()
    variationStore = voices
    variations = voices.all()
    injected = engine
    injectedPerf = perf
    favoritesStore = favorites
    loopLibrary = loops
    takeStore = takes
    self.favorites = favorites.list()
  }
  private let injected: DJEngine?
  private let injectedPerf: PerfMonitor?

  public func start() {
    guard dj == nil else { return }
    let savedTap = defaults.integer(forKey: Self.tapBarsKey)
    if Self.tapBarChoices.contains(savedTap) { tapBars = savedTap }
    if let p = defaults.string(forKey: Self.soundboardPageKey).flatMap(SoundboardPage.init) {
      soundboardPage = p
    }
    soundboardCrate = defaults.string(forKey: Self.soundboardCrateKey)
    showSoundboard = defaults.bool(forKey: Self.showSoundboardKey)
    showFxUnit = defaults.bool(forKey: Self.showFxUnitKey)
    if let injected {
      dj = injected
      scopeHub = ScopeHub(engine: injected, perf: injectedPerf ?? PerfMonitor())
      stageModel = scopeHub.map { StageModel(hub: $0) }
      injectedRouter = ControllerRouter(engine: injected)
      status = "\(Int(injected.sampleRate)) Hz"
      restoreLocks(injected)
      restoreLoops(injected)
      if injected.tapTakeBars != tapBars { injected.perform(.tapBars(bars: tapBars)) }
      applyAutoGainPreference(injected)
      if let journalDir { openJournal(injected, in: journalDir) }
      poll()
      return
    }
    setKeepScreenAwake(defaults.bool(forKey: Self.keepScreenAwakeKey))
    do {
      let dj = try DJEngine()
      applyAutoGainPreference(dj)
      for d in dj.decks.values { d.loadDemo() }
      restoreLocks(dj)
      if takeStore == nil { takeStore = LoopLibrary() }
      restoreLoops(dj)
      if dj.tapTakeBars != tapBars { dj.perform(.tapBars(bars: tapBars)) }
      if let q = defaults.object(forKey: Self.loopQuantizeKey) as? Int { dj.setLoopQuantum(q) }
      loopQuantum = dj.loopQuantum
      if let f = defaults.string(forKey: Self.loopFollowKey).flatMap(LoopFollow.init) {
        dj.setLoopFollow(f)
      }
      loopFollow = dj.loopFollow
      dj.master = master
      openJournal(dj, in: journalDir ?? Journal.defaultDirectory)
      try dj.start()
      let hub = ControllerHub(engine: dj)
      // warm the stock loop index (a first scan takes seconds) so the Load panel opens ready
      Task { await loadStockLoops() }
      hub.onMessage = { [weak self] m, d in
        self?.lastMessage = "\(m.port): " + (d.isEmpty ? "(unbound)" : d)
      }
      hub.onControl = { [weak self] port, group, index in
        let dev = hub.router.profileName(for: port) ?? port
        self?.lastControl = (dev, group, index, Date())
        self?.walkFeed(device: dev, group: group, index: index)
      }
      try hub.start()
      self.dj = dj
      self.hub = hub
      startControlServer()
      // The adaptive visual level (SPEC mode 27): a 60 Hz heartbeat on the main run loop while a
      // deck plays, and the quality choice remembered between runs.
      scopeHub = ScopeHub(
        engine: dj, perf: PerfMonitor(store: .userDefaults(), heartbeatInterval: 1.0 / 60))
      stageModel = scopeHub.map { StageModel(hub: $0) }
      status = "\(Int(dj.sampleRate)) Hz"
      let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
        MainActor.assumeIsolated { [weak self] in self?.poll() }
      }
      RunLoop.main.add(t, forMode: .common)
      refresh = t
    } catch {
      status = "audio/MIDI error: \(error)"
    }
  }

  /// Start the guided check of a connected device's controls (a `SurfaceProfile` name).
  public func startWalk(device: String) {
    guard let p = SurfaceProfile.all.first(where: { $0.name == device }) else { return }
    walkReportPath = nil
    walk = ControlWalk(device: device, rows: p.deviceMap())
  }

  public func stopWalk() {
    walk = nil
    walkReportPath = nil
  }

  public func walkSkip() {
    walk?.skip()
    finishWalkIfDone()
  }

  public func walkBack() {
    walk?.back()
    walkReportPath = nil
  }

  /// A control fired (device = profile name). Public so tests can drive the walk.
  public func walkFeed(device: String, group: String, index: Int) {
    guard walk?.device == device else { return }
    walk?.feed(group: group, index: index)
    finishWalkIfDone()
  }

  private func finishWalkIfDone() {
    guard let w = walk, w.isDone, walkReportPath == nil else { return }
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DJApp", isDirectory: true)
    let file = dir.appendingPathComponent(
      "walk-\(w.device.replacingOccurrences(of: " ", with: "-")).txt")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
      try w.report.write(to: file, atomically: true, encoding: .utf8)
      walkReportPath = file.path
    } catch { walkReportPath = "(could not write: \(error))" }
  }

  public func stop() {
    dj?.stop()  // silence first: the rest can take a moment
    closeJournal()
    controlServer?.stop()
    scopeHub?.perf.stop()
    hub?.stop()
  }

  /// Refresh the display state from the engine (30 Hz in the app).
  public func poll() {
    guard let dj else { return }
    let now = uptime()
    let router = hub?.router ?? injectedRouter
    // The perf monitor measures while something plays; the rings are rebuilt less often at the
    // reduced levels (backend/index.js `onStateSync`).
    scopeHub?.perf.setRunning(dj.decks.values.contains { $0.playing })
    let ringsDue = ringGate.due(now: now, level: scopeHub?.vizLevel ?? 0)
    devices = hub?.devices ?? []
    crossfader = dj.crossfader
    let am = AutoMixDisplay(dj)
    if am != autoMix { autoMix = am }
    master = dj.master
    headphoneMix = dj.headphoneMix
    headphoneLevel = dj.headphoneLevel
    inpulseOutput = findInpulse()
    // with Shift down the mirror shows the loop page a shift-click reaches
    let shiftLayer: Bool? = showPads && shiftKeyHeld() ? true : nil
    if let apc = router?.lights(profileName: SurfaceProfile.apcMiniMK2.name, shift: shiftLayer) {
      padPort = apc.port
      padLights = apc.groups
    } else {
      padPort = nil
      padLights = [:]
    }
    var mirrored: [String: DeviceLights] = [:]
    for p in SurfaceProfile.all where p.leds != nil {
      if let l = router?.deviceLights(profileName: p.name) { mirrored[p.name] = l }
    }
    if mirrored != deviceLights { deviceLights = mirrored }
    for (name, d) in dj.decks {
      let adapter = router?.jogAdapters.first { $0.deck == name }
      let previous = decks[name]
      // A held back poll keeps the last snapshot, unless there is none to keep or the deck has
      // another track.
      let refreshRings = ringsDue || previous?.snapshot == nil || previous?.title != d.title
      var state = DeckState(
        title: d.title, playing: d.playing, platterSeconds: d.platterSeconds,
        positionSeconds: d.positionSeconds,
        duration: d.loaded?.duration ?? 0, rate: d.turntable.currentRate, volume: d.volume,
        filter: d.filter,
        pitch: d.pitch, nudge: adapter?.nudge ?? 0, touching: adapter?.touching ?? false,
        cues: Set(d.hotCues.keys), isNet: d.mode == .net, bpm: d.effectiveBPM,
        beatInBar: d.beatState?.beatInBar ?? 0, beatPhase: d.beatState?.beatPhase ?? 0,
        sections: d.sections, currentSection: d.currentSectionIndex, roles: d.roles,
        rolesOn: Set(d.roles.filter { d.isRoleOn($0) }), nextReady: d.nextReady != nil,
        nextComposing: d.nextComposing != nil,
        quantize: d.quantize == .off ? "off" : (d.quantize == .beat ? "beat" : "bar"),
        scrubbing: d.wave.isScrubbing, pfl: d.pfl, overview: d.waveform,
        overlay: d.waveformOverlay, snapshot: refreshRings ? d.netSnapshot : previous?.snapshot,
        timeline: d.sectionTimeline)
      state.sourceCID = sourceCID(name, d)
      if let previous, previous.sourceCID == state.sourceCID, previous.title == state.title {
        state.voices = previous.voices
        state.channelVoices = previous.channelVoices
        state.roleSounds = previous.roleSounds
      } else {
        state.voices = d.roleVoices
        for v in state.voices { state.channelVoices[v.channel] = d.channelVoice(v.channel) }
        state.roleSounds = d.roleSounds
      }
      state.voiceSettings = d.mode == .net ? d.wave.voiceSettings : [:]
      state.kit = d.kit
      state.palette = d.palette
      state.mixingOut = d.isMixingOut
      state.mixingIn = d.isMixingIn
      if d.mode == .net {
        var spin = ringSpins[name] ?? RingSpin()
        spin.observe(advances: d.advances, at: now)
        ringSpins[name] = spin
        let arcs = spin.arcs(playing: d.playing, at: now)
        state.ringArcs = refreshRings ? arcs : (previous?.ringArcs ?? arcs)
        var board = chaseBoards[name] ?? MacroChaseBoard()
        board.update(d.macroActivity, dt: now - (chaseClock[name] ?? now))
        chaseBoards[name] = board
        chaseClock[name] = now
        state.macroPulse = board.state
        state.stingers = d.stingers.map(\.help)
        state.duration = Double(d.sections.map(\.steps).reduce(0, +)) * 15 / max(d.netBaseBPM, 1)
        state.positionSeconds = Double(d.wave.tick) * 15 / max(d.effectiveBPM ?? 120, 1)
        state.platterSeconds = state.positionSeconds
        state.bars = d.sections.map(\.steps).reduce(0, +) / 16
        state.bar = d.wave.tick / 16 + 1
      }
      state.masterRunning = Set(d.activeMasterMacros)  // a sample deck's bus too
      state.clipID = d.clipID
      state.disabledRoles = d.disabledRoles
      state.autoAdvance = d.autoAdvance
      state.reverb = ReverbState(d.reverb)
      state.wander = d.wander
      state.wanderCountdown = d.wanderCountdown
      state.wanderIdle = d.wanderIdleReason(lockedActions: dj.lockedActions)
      decks[name] = state
    }
    let tempo = decksPlayingTempo
    if tempo != playingTempo { playingTempo = tempo }
    pollFxUnit(dj, now: now)
    pollLoops(dj)
    pollJournal(dj)
  }

  /// A clip's provenance as lines and JSON, worked out once per clip (it never changes).
  @ObservationIgnored private var provenanceCache: [String: (lines: [String], json: String?)] = [:]
  private func described(_ c: LoopClip) -> (lines: [String], json: String?) {
    if let d = provenanceCache[c.id] { return d }
    let d = (ClipState.describe(c.provenance), c.provenance?.canonicalJS)
    provenanceCache[c.id] = d
    return d
  }

  private func restoreLoops(_ dj: DJEngine) {
    guard let store = takeStore else { return }
    dj.restoreClips(store.load(sampleRate: dj.sampleRate))
    dj.restoreScenes(store.loadScenes())
    savedRow = Self.rowSignature(dj.clips)
    savedScenes = dj.scenes
    diskRemoved = store.removed()
  }

  /// What the library keeps of the row, to tell when it needs saving.
  private static func rowSignature(_ clips: [LoopClip]) -> [String] {
    clips.map { "\($0.id)|\($0.title)|\($0.color ?? "")|\($0.fx.json.canonicalJS)" }
  }

  func pollLoops(_ dj: DJEngine) {
    let signature = Self.rowSignature(dj.clips)
    if signature != savedRow || dj.scenes != savedScenes, let store = takeStore {
      savedRow = signature
      savedScenes = dj.scenes
      let row = dj.clips
      let scenes = dj.scenes
      let epoch = diskRemovedEpoch
      saveQueue.async {
        do { try store.save(row, scenes: scenes) } catch { print("loop library: \(error)") }
        self.publishRemoved(store.removed(), epoch: epoch)
      }
    }
    pollRemoved(dj)
    if dj.loopQuantum != loopQuantum {
      loopQuantum = dj.loopQuantum
      defaults.set(loopQuantum, forKey: Self.loopQuantizeKey)
    }
    if dj.loopFollow != loopFollow {
      loopFollow = dj.loopFollow
      defaults.set(loopFollow.rawValue, forKey: Self.loopFollowKey)
    }
    let following = dj.loopFollow == .louder ? dj.dominantDeck : nil
    if following != followingDeck { followingDeck = following }
    let sceneRow = SceneState.row(dj)
    if sceneRow != scenes { scenes = sceneRow }
    let l = dj.loopChannel
    let strip = LoopChannelState(
      looping: dj.loopingClips.count, volume: l.volume, mute: l.mute, reverb: ReverbState(l.reverb),
      fade: dj.loopFade, keyLock: dj.loopKeyLock,
      masterRunning: Set(dj.loopMaster?.activeMasterMacros ?? []), fxLink: dj.loopFxLink)
    if strip != loopChannel { loopChannel = strip }
    // the deck holding a clip: the one playing it, else one holding it paused
    let holders = dj.decks.values.filter { $0.clipID != nil }.sorted { $0.playing && !$1.playing }
    let row = dj.clips.map { c in
      ClipState(
        id: c.id, title: c.title, source: c.source, bars: c.bars, beats: c.beats,
        lengthLabel: c.lengthLabel, bpm: c.bpm,
        overview: c.waveform, loop: dj.loopState(c.id), gain: dj.clipGain(c.id),
        muted: dj.isClipMuted(c.id), soloed: dj.isClipSoloed(c.id), keyLock: dj.isKeyLocked(c.id),
        stretched: dj.isClipStretched(c.id), stretching: dj.isClipStretching(c.id),
        playhead: dj.loopPlayhead(c.id), countdown: dj.loopCountdown(c.id).map(LoopCountdown.init),
        onDeck: holders.first { $0.clipID == c.id }?.name,
        steps: c.steps?.map { s in
          StepState(
            clipID: s.clipID,
            name: dj.clip(s.clipID).map {
              $0.title.split(separator: " ").suffix(2).joined(separator: " ")
            }
              ?? "missing", repeats: s.repeats)
        }, provenance: described(c).lines, provenanceJSON: described(c).json,
        color: c.color, genre: c.originGenre, originTitle: c.originTitle,
        canLoadOrigin: canLoadOrigin(c.id, dj), fx: c.fx, quantum: dj.clipQuantum(c.id),
        fade: dj.clipFade(c.id), follow: dj.clipFollow(c.id))
    }
    let present = Set(row.map(\.id))
    if !selectedClips.isSubset(of: present) { selectedClips.formIntersection(present) }
    if row != clips { clips = row }
    var takes: [String: RecordingState] = [:]
    for n in dj.recordableDecks {
      if let p = dj.loopTakeProgress(n) {
        takes[n] = RecordingState(bars: p.bars, released: p.released)
      }
    }
    if takes != recording { recording = takes }
  }

  // Actions from the UI. Hardware goes through the hub's router; UI inputs go through
  // `DJEngine.perform`. Both are recorded when a session is being recorded.
  func togglePlay(_ deck: String) {
    guard let d = dj?[deck] else { return }
    dj?.perform(.play(deck: deck, on: !d.playing))
  }
  func hotCue(_ deck: String, _ slot: Int) { dj?.perform(.hotCue(deck: deck, slot: slot)) }
  func clearCue(_ deck: String, _ slot: Int) { dj?.perform(.clearCue(deck: deck, slot: slot)) }
  func setVolume(_ deck: String, _ v: Double) {
    dj?.perform(.param(deck: deck, name: "volume", value: v))
  }
  func setFilter(_ deck: String, _ v: Double) {
    dj?.perform(.param(deck: deck, name: "filter", value: v))
  }
  func setPitch(_ deck: String, _ v: Double) {
    dj?.perform(.param(deck: deck, name: "pitch", value: v))
  }
  func setCrossfader(_ v: Double) { dj?.perform(.crossfader(v)) }
  // LOOP record and the row under the decks
  /// The press carries the tap length (a quick release records exactly that many bars).
  func loopRecord(_ deck: String, on: Bool) {
    dj?.perform(.loopRecord(deck: deck, on: on, bars: on ? tapBars : nil))
    if let dj { pollLoops(dj) }
  }
  /// The ⟲ buttons: the last `bars` bars `deck` played, as a clip looping on the row.
  func grabBars(_ deck: String, bars: Int) {
    dj?.perform(.grabBars(deck: deck, bars: bars))
    if let dj { pollLoops(dj) }
  }
  private func applyAutoGainPreference(_ dj: DJEngine) {
    let on = defaults.object(forKey: Self.autoGainKey) as? Bool ?? true
    for name in dj.decks.keys.sorted() {
      if dj[name]?.autoGain != on {
        dj.perform(.param(deck: name, name: "autoGain", value: on ? 1 : 0))
      }
      autoGain[name] = on
    }
  }

  /// The Load panel's "Auto level" chip: this deck's sample loads at the reference loudness, or
  /// as recorded. Remembered as the default for every deck.
  func setAutoGain(_ deck: String, _ on: Bool) {
    dj?.perform(.param(deck: deck, name: "autoGain", value: on ? 1 : 0))
    autoGain[deck] = on
    defaults.set(on, forKey: Self.autoGainKey)
  }

  func setTapBars(_ n: Int) {
    guard Self.tapBarChoices.contains(n) else { return }
    tapBars = n
    // through `perform`: a controller's LOOP tap is recorded as MIDI, so a session needs the
    // length it was made with
    dj?.perform(.tapBars(bars: n))
    defaults.set(n, forKey: Self.tapBarsKey)
  }
  /// The tap-length chip's click: the next of 1, 2, 4, 8 (round to 1).
  func stepTapBars() {
    let c = Self.tapBarChoices
    setTapBars(c[((c.firstIndex(of: tapBars) ?? 0) + 1) % c.count])
  }
  func playClip(_ id: String, on deck: String) {
    guard dj?.clip(id) != nil else { return }
    dj?.perform(.clip(deck: deck, id: id))
  }
  /// Drag a tile onto another: it goes just before that one.
  func moveClip(_ id: String, before: String?) {
    dj?.perform(.clipMove(id: id, before: before))
    if let dj { pollLoops(dj) }
  }
  /// Wait for pending library writes (tests).
  func flushLoopLibrary() {
    saveQueue.sync {}
    diskRemoved = takeStore?.removed() ?? []
    if let dj { pollLoops(dj) }
  }
  /// A tile's ▶/■: in on the next downbeat, or out on it.
  func toggleLoop(_ id: String) {
    guard let dj else { return }
    let on = dj.loopState(id)
    dj.perform(.clipLoop(id: id, on: on == .off || on == .stopping))
  }
  func setClipGain(_ id: String, _ v: Double) { dj?.perform(.clipGain(id: id, value: v)) }
  // how the loops sound (LoopSound.swift)
  func setClipMute(_ id: String, _ on: Bool) { soundAction(.clipMute(id: id, on: on)) }
  func setClipSolo(_ id: String, _ on: Bool) { soundAction(.clipSolo(id: id, on: on)) }
  func setClipKeyLock(_ id: String, _ on: Bool) { soundAction(.clipKeyLock(id: id, on: on)) }
  func setClipFx(_ id: String, _ fx: LoopFX) { soundAction(.clipFx(id: id, fx: fx)) }
  func setLoopKeyLock(_ on: Bool) { soundAction(.loopKeyLock(on: on)) }
  func setLoopFade(_ f: LoopFade) { soundAction(.loopFade(mode: f.rawValue)) }
  /// Clip `id`'s own launch boundary, fade and tempo follow; nil: it follows the row's again.
  func setClipQuantum(_ id: String, _ beats: Int?) {
    soundAction(.clipQuantize(id: id, beats: beats))
  }
  func setClipFade(_ id: String, _ f: LoopFade?) {
    soundAction(.clipFade(id: id, mode: f?.rawValue))
  }
  func setClipFollow(_ id: String, _ mode: LoopFollow?) {
    soundAction(.clipFollow(id: id, mode: mode?.rawValue))
  }
  func setLoopFxLink(_ on: Bool) { soundAction(.loopFxLink(on: on)) }
  private func soundAction(_ a: DeckAction) {
    guard let dj else { return }
    dj.perform(a)
    pollLoops(dj)
  }
  func toggleSelected(_ id: String) {
    if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) }
  }
  /// The selected loops, in row order, joined into a sequence at the end of the row.
  func joinSelected() {
    guard let dj, !selectedClips.isEmpty else { return }
    let steps = dj.clips.filter { selectedClips.contains($0.id) }.map {
      SequenceStep(clipID: $0.id)
    }
    dj.perform(.clipSequence(steps: steps, replacing: nil))
    selectedClips = []
    pollLoops(dj)
  }
  /// Rewrite a sequence's steps (its chips, or a clip dropped on it).
  func editSequence(_ id: String, _ steps: [SequenceStep]) {
    dj?.perform(.clipSequence(steps: steps, replacing: id))
    if let dj { pollLoops(dj) }
  }
  /// Keep beats `from..<to` of a clip (its tile's edges, dragged).
  func cropClip(_ id: String, from: Int, to: Int) {
    dj?.perform(.clipCrop(id: id, from: from, to: to))
    if let dj { pollLoops(dj) }
  }
  func stopAllLoops() {
    guard let dj else { return }
    for id in dj.loopingClips { dj.perform(.clipLoop(id: id, on: false)) }
  }
  /// The row's "Tempo": loops follow the louder deck, or each its own.
  func setLoopFollow(_ mode: LoopFollow) {
    dj?.perform(.loopFollow(mode: mode.rawValue))
    if let dj { pollLoops(dj) }
  }
  /// The row's "Launch on": what loops (and scenes) start and stop on, in beats.
  func setLoopQuantum(_ beats: Int) {
    dj?.perform(.loopQuantize(beats: beats))
    if let dj { pollLoops(dj) }
  }
  /// "Save scene": the loops playing now, as the next "Scene n" (or over scene `name`).
  func saveScene(_ name: String? = nil) {
    guard let dj else { return }
    dj.perform(.sceneSave(name: name ?? dj.nextSceneName))
    pollLoops(dj)
  }
  /// A scene's chip: its loops in, the others out, on the next launch boundary.
  func launchScene(_ name: String) {
    dj?.perform(.sceneLaunch(name: name, clips: nil))
    if let dj { pollLoops(dj) }
  }
  func renameScene(_ name: String, to: String) {
    let to = to.trimmingCharacters(in: .whitespaces)
    dj?.perform(.sceneRename(name: name, to: to))
    if let dj { pollLoops(dj) }
  }
  func deleteScene(_ name: String) {
    dj?.perform(.sceneDelete(name: name))
    if let dj { pollLoops(dj) }
  }
  /// One reverb knob of a channel ("A", "B", "L"): reverbWet | reverbSize | reverbTone.
  func setReverb(_ deck: String, _ knob: String, _ v: Double) {
    dj?.perform(.param(deck: deck, name: knob, value: v))
  }
  func setReverb(_ deck: String, _ r: ReverbState) {
    setReverb(deck, "reverbSize", r.size)
    setReverb(deck, "reverbTone", r.tone)
    setReverb(deck, "reverbWet", r.wet)
  }
  func setLoopMute(_ on: Bool) { dj?.perform(.param(deck: "L", name: "mute", value: on ? 1 : 0)) }
  func setMaster(_ v: Double) { dj?.perform(.master(v)) }
  // Cue/headphone state doesn't change the master mix a session renders: not recorded.
  func setKeepScreenAwake(_ on: Bool) {
    keepScreenAwake = on
    screenWakeLock.set(on)
    defaults.set(on, forKey: Self.keepScreenAwakeKey)
  }
  /// Show the APC grid on screen; with no hardware attached, a virtual APC takes its place.
  func setShowPads(_ on: Bool) {
    showPads = on
    if on,
      (hub?.router ?? injectedRouter)?.lights(profileName: SurfaceProfile.apcMiniMK2.name) == nil
    {
      (hub?.router ?? injectedRouter)?.attach(port: "APC mini mk2 Control (on screen)")
    }
  }
  /// `shift`: with the APC's SHIFT held around the press (shift-click: the loop page).
  func pressPad(_ group: String, _ index: Int, shift: Bool = false) {
    guard let port = padPort else { return }
    (hub?.router ?? injectedRouter)?.press(port: port, group: group, index: index, shift: shift)
  }

  func setPFL(_ deck: String, _ on: Bool) { dj?[deck]?.pfl = on }
  func setHeadphoneMix(_ v: Double) {
    dj?.owners["headphoneMix"] = "ui"
    dj?.headphoneMix = v
  }
  func setHeadphoneLevel(_ v: Double) {
    dj?.owners["headphoneLevel"] = "ui"
    dj?.headphoneLevel = v
  }

  /// Master → the Inpulse's outputs 1/2, headphone cue → 3/4. Restarts the engine; if the
  /// device refuses, the stereo path comes back.
  func toggleInpulseOutput() {
    Task { @MainActor in await routeInpulseOutput(!inpulseRouted) }
  }

  /// Route to the Inpulse (on) or back to stereo (off); a no-op when already there.
  func routeInpulseOutput(_ on: Bool) async {
    guard let dj, on != inpulseRouted else { return }
    // In a main-actor Task (as the toggle always did): `dj` crosses into the nonisolated
    // `enableCueOutput` from the Task's region, which strict concurrency accepts.
    await Task { @MainActor in
      dj.stop()
      do {
        if inpulseRouted {
          try dj.disableCueRouting()
          inpulseRouted = false
        } else if let dev = findInpulse() {
          try await dj.enableCueOutput(device: dev)
          inpulseRouted = true
        }
        try dj.start()
        status = inpulseRouted ? "Inpulse out: master 1/2, cue 3/4" : "\(Int(dj.sampleRate)) Hz"
      } catch {
        status = "cue output: \(error)"
        try? dj.disableCueRouting()
        inpulseRouted = false
        try? dj.start()
      }
    }.value
  }

  func loadDemo(_ deck: String) {
    dj?.perform(
      .load(
        deck: deck, source: .sample(id: DeckSourceDescriptor.demoID, title: "demo loop", grid: nil))
    )
  }

  // Live nets
  func generate(_ deck: String, _ spec: TrackSpec) {
    Task { @MainActor in await composeAndLoad(deck, spec) }
  }
  /// Compose off the main thread, then load; returns once the deck has the track.
  func composeAndLoad(_ deck: String, _ spec: TrackSpec) async {
    status = "composing \(spec.genre)…"
    await prepareAndLoad(deck, .net(spec))
  }
  /// Build a net source (composed or raw-`nets`) off the main thread, then load it through
  /// `perform`, so it is recorded. False (and the status says why) if it has no project.
  @discardableResult
  func prepareAndLoad(_ deck: String, _ source: DeckSourceDescriptor) async -> Bool {
    guard let dj else { return false }
    let sr = dj.sampleRate
    let bank = dj[deck]?.wave.samplers
    let filter = dj[deck]?.roleFilter
    let track = await Task.detached(priority: .userInitiated) {
      PreparedTrack(
        source: source, sampleRate: sr, opts: .extended(samplers: bank, roleFilter: filter))
    }.value
    guard let track else {
      status = "nothing to play in that source"
      return false
    }
    dj.perform(.load(deck: deck, source: source), prepared: track)
    status = "\(Int(dj.sampleRate)) Hz"
    return true
  }
  /// A beats share (link or envelope JSON) onto a deck; a bad one says why in the status line.
  func loadShare(_ deck: String, _ text: String) {
    do {
      let source = try DeckSourceDescriptor.share(text)
      status = "loading share…"
      Task { @MainActor in await prepareAndLoad(deck, source) }
    } catch {
      status = "share: \(error)"
    }
  }
  // Favorites
  private func sourceCID(_ name: String, _ d: Deck) -> String? {
    if d.mode == .sample { return d.sourceFile.map { Favorite.fileCID($0.path) } }
    guard let source = d.netSource else { return nil }
    if let (s, cid) = sourceCIDs[name], s == source { return cid }
    guard let cid = source.favoriteCID else { return nil }
    sourceCIDs[name] = (source, cid)
    return cid
  }
  func isFavorite(_ deck: String) -> Bool {
    guard let cid = decks[deck]?.sourceCID else { return false }
    return favorites.contains { $0.cid == cid }
  }
  /// Star what the deck plays: its net, or the sample's file (a sample with no file — a clip,
  /// the demo loop — can't be one). Returns the favorite, nil if none.
  @discardableResult
  func addFavorite(_ deck: String) -> Favorite? {
    guard let d = dj?[deck] else { return nil }
    let f: Favorite
    if let source = d.netSource {
      f = Favorite(title: d.title, source: source)
    } else if d.mode == .sample, let file = d.sourceFile {
      f = Favorite(
        title: d.title, source: .sample(id: "", title: d.title, grid: d.beatGrid), file: file.path)
    } else {
      return nil
    }
    do {
      favorites = try favoritesStore.add(f)
      journal?.record(.favoriteAdd(f))
      return f
    } catch {
      status = "favorites: \(error)"
      return nil
    }
  }
  func removeFavorite(cid: String) {
    do {
      favorites = try favoritesStore.remove(cid: cid)
      journal?.record(.favoriteRemove(cid: cid))
    } catch {
      status = "favorites: \(error)"
    }
  }
  func toggleFavorite(_ deck: String) {
    poll()
    if isFavorite(deck), let cid = decks[deck]?.sourceCID {
      removeFavorite(cid: cid)
    } else {
      addFavorite(deck)
    }
  }
  /// Load a favorite onto a deck, through `perform` like any other load: a net is prepared off
  /// the main thread, a sample decoded from its file (with the grid it was starred with).
  /// Returns the load's task (its value: did it load), for callers that wait on it.
  @discardableResult
  func loadFavorite(_ deck: String, _ f: Favorite) -> Task<Bool, Never> {
    status = "loading \(f.title)…"
    return Task { @MainActor in await loadFavoriteNow(deck, f) }
  }

  @discardableResult
  func loadFavoriteNow(_ deck: String, _ f: Favorite) async -> Bool {
    guard let file = f.file, f.isSample else { return await prepareAndLoad(deck, f.source) }
    guard let dj else { return false }
    let url = URL(fileURLWithPath: file)
    let sr = dj.sampleRate
    let level = dj[deck]?.autoGain ?? false
    do {
      // measured here too, off the main thread, when the deck will level it (cached on the
      // buffer: the load then reads it for free)
      let buffer = try await Task.detached(priority: .userInitiated) {
        let b = try Deck.decode(url, sampleRate: sr)
        if level { _ = b.level }
        return b
      }.value
      var grid: BeatGrid?
      if case .sample(_, _, let g) = f.source { grid = g }
      dj.perform(
        .load(deck: deck, source: .sample(id: "", title: f.title, grid: grid)), buffer: buffer)
      dj[deck]?.sourceFile = url
      status = "\(Int(dj.sampleRate)) Hz"
      return true
    } catch {
      status = "\(f.title): \(error)"
      return false
    }
  }

  // Crates: your own lists of loops, built on favorites + tags (a crate is a tag; a loop in it
  // is a starred sample carrying that tag), so one store holds every pick. Empty crates are
  // kept by name in the app's defaults until something is dropped in.

  static let cratesKey = "crates"

  /// Every crate: the ones made here (in the order made), then any other tag in use.
  var crates: [String] {
    let made = defaults.stringArray(forKey: Self.cratesKey) ?? []
    return made + favorites.allTags.filter { !made.contains($0) }
  }

  func newCrate(_ name: String) {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { return }
    var made = defaults.stringArray(forKey: Self.cratesKey) ?? []
    if !made.contains(n) {
      made.append(n)
      journal?.record(.crateAdd(name: n))
    }
    defaults.set(made, forKey: Self.cratesKey)
    favorites = favoritesStore.list()  // observed: the crate bar redraws
  }

  /// Put a stock loop (by path) in a crate: star it as a sample (with its own tempo as its
  /// grid) if it isn't yet, and tag it.
  func addToCrate(_ path: String, _ crate: String) {
    newCrate(crate)
    let cid = Favorite.fileCID(path)
    if !favorites.contains(where: { $0.cid == cid }) {
      guard let loop = stockLoops.first(where: { $0.path == path }) else { return }
      let f = Favorite(
        title: loop.name,
        source: .sample(
          id: "", title: loop.name, grid: BeatGrid(bpm: loop.bpm, offset: 0, confidence: 1)),
        file: path)
      do {
        favorites = try favoritesStore.add(f)
        journal?.record(.favoriteAdd(f))
      } catch {
        status = "favorites: \(error)"
        return
      }
    }
    addFavoriteToCrate(cid, crate)
  }

  /// Put a favorite (by cid) in a crate, made if new. False if no favorite has that cid.
  @discardableResult
  func addFavoriteToCrate(_ cid: String, _ crate: String) -> Bool {
    guard let f = favorites.first(where: { $0.cid == cid }) else { return false }
    newCrate(crate)
    let n = crate.trimmingCharacters(in: .whitespacesAndNewlines)
    if !n.isEmpty, !f.tags.contains(n) { setFavoriteTags(cid, f.tags + [n]) }
    return true
  }

  /// Take a favorite out of a crate (it stays starred).
  func removeFromCrate(_ cid: String, _ crate: String) {
    let tags = favorites.first { $0.cid == cid }?.tags ?? []
    setFavoriteTags(cid, tags.filter { $0 != crate })
  }

  /// Delete a crate: its tag comes off every favorite (they stay starred).
  func deleteCrate(_ crate: String) {
    for f in favorites where f.tags.contains(crate) { removeFromCrate(f.cid, crate) }
    journal?.record(.crateDelete(name: crate))
    defaults.set(
      (defaults.stringArray(forKey: Self.cratesKey) ?? []).filter { $0 != crate },
      forKey: Self.cratesKey)
    favorites = favoritesStore.list()
  }

  /// A favorite's tags, replaced (the editor's add / remove).
  func setFavoriteTags(_ cid: String, _ tags: [String]) {
    do {
      favorites = try favoritesStore.setTags(cid: cid, tags)
      journal?.record(.favoriteTags(cid: cid, tags: tags))
    } catch {
      status = "favorites: \(error)"
    }
  }

  /// Read the stock loop index (or scan, the first time: a few seconds) off the main thread.
  func loadStockLoops() async {
    guard stockLoops.isEmpty, !stockLoopsLoading else { return }
    stockLoopsLoading = true
    let library = loopLibrary
    stockLoops = await Task.detached(priority: .userInitiated) { library.load() }.value
    StingerContent.setStock(stockLoops)  // a Hit may launch one (local-only)
    stockLoopsLoading = false
  }

  /// Put a stock loop on a deck: decoded off the main thread, loaded through `perform` with the
  /// loop's own tempo as its beat grid (so no analysis runs, and sync works at once).
  @discardableResult
  func loadStockLoop(_ deck: String, _ loop: StockLoop) async -> Bool {
    guard let dj else { return false }
    let sr = dj.sampleRate
    let level = dj[deck]?.autoGain ?? false
    status = "loading \(loop.name)…"
    do {
      let buffer = try await Task.detached(priority: .userInitiated) {
        let b = try Deck.decode(loop.url, sampleRate: sr)
        if level { _ = b.level }  // off the main thread, as loadFavoriteNow
        return b
      }.value
      let grid = BeatGrid(bpm: loop.bpm, offset: 0, confidence: 1)
      dj.perform(
        .load(deck: deck, source: .sample(id: "", title: loop.name, grid: grid)), buffer: buffer)
      dj[deck]?.sourceFile = loop.url
      status = "\(Int(dj.sampleRate)) Hz"
      return true
    } catch {
      status = "\(loop.name): \(error)"
      return false
    }
  }

  /// Put a stock loop on the loop row as a clip, looping under the mixer from the next launch
  /// boundary (`DJEngine.importClip`): decoded off the main thread, recorded as a `clipImport`
  /// with `LoopProvenance.stock` (so the set is never published), and its file noted in the
  /// journal so a replay finds the audio. The same loop twice is one clip. Returns its id.
  @discardableResult
  func addStockLoopToRow(_ loop: StockLoop) async -> String? {
    guard let dj else { return nil }
    let sr = dj.sampleRate
    status = "loading \(loop.name)…"
    do {
      let buffer = try await Task.detached(priority: .userInitiated) {
        try Deck.decode(loop.url, sampleRate: sr)
      }.value
      let id = buffer.contentID
      _ = dj.journal?.record(.sampleFile(id: id, path: loop.path))
      dj.perform(
        .clipImport(
          id: "", title: loop.name, bpm: 0, beats: loop.beats,
          provenance: LoopProvenance.stock(loop, id: id)), buffer: buffer)
      guard dj.clip(id) != nil else {
        status = "\(loop.name): could not go on the row"
        return nil
      }
      status = "\(loop.name) on the row"
      return id
    } catch {
      status = "\(loop.name): \(error)"
      return nil
    }
  }

  /// The tempo a deck's stock loops are sorted by: the other deck's, when it has one.
  func loopTempo(for deck: String) -> Double? {
    let other = deck == "A" ? "B" : "A"
    return decks[other]?.bpm ?? decks[deck]?.bpm
  }

  /// Load the net playing on `from` onto `to` (instrument changes included), from its start.
  @discardableResult
  func copyDeck(from: String, to: String) async -> Bool {
    guard let source = dj?[from]?.netSource else {
      status = "deck \(from) has no net track to copy"
      return false
    }
    return await prepareAndLoad(to, source)
  }
  /// Play `instrument` on the deck's nets on `channel`: the track reloads with the share's
  /// `tracks` override (from its start, at the next bar if playing), so it records, can be
  /// starred and shares like any other change.
  @discardableResult
  func setInstrument(_ deck: String, channel: Int, _ instrument: String) async -> Bool {
    guard let source = dj?[deck]?.netSource?.withInstrument(instrument, channel: channel) else {
      status = "deck \(deck) has no net track"
      return false
    }
    return await prepareAndLoad(deck, source)
  }

  // The sound panel (long press on an instrument): live voice tweaks, session-only, and the
  // saved variations.

  /// Shape a channel's voice, live (recorded; Reset is an empty tweak).
  func setVoiceTweak(_ deck: String, channel: Int, _ tweak: VoiceTweak) {
    dj?.perform(.voiceTweak(deck: deck, channel: channel, params: tweak))
    refreshVoices(deck)
  }

  /// The panel's state without a whole poll (a slider sends many tweaks).
  func refreshVoices(_ deck: String) {
    guard let d = dj?[deck], d.mode == .net else { return }
    decks[deck]?.voiceSettings = d.wave.voiceSettings
  }

  /// A sampled channel plays its synth voice (`on`) or the sample again.
  func setSynthVoice(_ deck: String, channel: Int, _ on: Bool) {
    dj?.perform(.voiceSynth(deck: deck, channel: channel, on: on))
    refreshVoices(deck)
  }

  /// Play `variation` of `instrument` on a channel: picks the instrument first if the channel
  /// plays another (a reload, as any pick), then its tweak and synth switch, as the panel would.
  @discardableResult
  func applyVariation(
    _ deck: String, channel: Int, instrument: String, _ variation: VoiceVariation
  ) async -> Bool {
    guard let d = dj?[deck] else { return false }
    if d.channelVoice(channel)?.instrument != instrument {
      guard await setInstrument(deck, channel: channel, instrument) else { return false }
    }
    if d.usesSynthVoice(channel) != variation.useSynth {
      dj?.perform(.voiceSynth(deck: deck, channel: channel, on: variation.useSynth))
    }
    setVoiceTweak(deck, channel: channel, variation.params)
    return true
  }

  /// The variation of `instrument` a channel's settings are now, if they are one.
  func currentVariation(_ instrument: String, _ setting: VoiceSetting?) -> VoiceVariation? {
    guard let setting, !setting.isDefault, setting.instrument == instrument else { return nil }
    return variations[instrument]?.first {
      $0.params == setting.tweak && $0.useSynth == setting.useSynth
    }
  }

  /// Keep a channel's settings as a named variation of its instrument.
  func saveVariation(_ instrument: String, name: String, _ setting: VoiceSetting) {
    let v = VoiceVariation(name: name, params: setting.tweak, useSynth: setting.useSynth)
    do {
      variations[instrument] = try variationStore.save(v, for: instrument)
      journal?.record(.variationSave(instrument: instrument, variation: v))
    } catch {
      status = "voices: \(error)"
    }
  }
  func renameVariation(_ instrument: String, _ name: String, to new: String) {
    do {
      variations[instrument] = try variationStore.rename(name, to: new, for: instrument)
      journal?.record(.variationRename(instrument: instrument, name: name, to: new))
    } catch {
      status = "voices: \(error)"
    }
  }
  func deleteVariation(_ instrument: String, _ name: String) {
    do {
      let left = try variationStore.delete(name, for: instrument)
      variations[instrument] = left.isEmpty ? nil : left
      journal?.record(.variationDelete(instrument: instrument, name: name))
    } catch {
      status = "voices: \(error)"
    }
  }

  func queueNext(_ deck: String, _ spec: TrackSpec) {
    dj?.perform(.queueNext(deck: deck, spec: spec))
  }
  func setAutoAdvance(_ deck: String, _ on: Bool) { dj?.perform(.autoAdvance(deck: deck, on: on)) }
  func launchSection(_ deck: String, _ i: Int) { dj?.perform(.section(deck: deck, index: i)) }
  func toggleRole(_ deck: String, _ role: String) {
    guard let d = dj?[deck], !d.disabledRoles.contains(role) else { return }
    dj?.perform(.role(deck: deck, role: role, on: !d.isRoleOn(role)))
  }

  /// Disable a role on a deck through every new track (right-click on its button), or enable it.
  func setRoleDisabled(_ deck: String, _ role: String, _ disabled: Bool) {
    dj?.perform(.roleDisable(deck: deck, role: role, on: disabled))
    defaults.set(dj?[deck]?.disabledRoles.sorted() ?? [], forKey: Self.disabledRolesKey(deck))
    poll()
  }

  func isLocked(_ key: String) -> Bool { lockedButtons.contains(key) }

  /// Lock a button (and the controller buttons bound to the same action), or unlock it.
  func setLocked(_ key: String, _ locked: Bool) {
    if locked { lockedButtons.insert(key) } else { lockedButtons.remove(key) }
    dj?.perform(.lock(key: key, on: locked))  // recorded: it changes what the controllers do
    dj?.lockedActions = lockedButtons
    defaults.set(lockedButtons.sorted(), forKey: Self.lockedButtonsKey)
  }

  /// Bring back the locks, disabled roles and wander settings (its locks and pace) of the last
  /// run.
  private func restoreLocks(_ dj: DJEngine) {
    lockedButtons = Set(defaults.stringArray(forKey: Self.lockedButtonsKey) ?? [])
    dj.lockedActions = lockedButtons
    for (name, d) in dj.decks {
      for r in defaults.stringArray(forKey: Self.disabledRolesKey(name)) ?? [] {
        d.setRoleDisabled(r, true)
      }
      for l in defaults.stringArray(forKey: Self.wanderLocksKey(name)) ?? [] {
        d.setWanderLock(l, true)
      }
      let pace = defaults.integer(forKey: Self.wanderPaceKey(name))
      if pace > 0 { d.setWanderPace(pace) }
    }
    // auto-mix's settings (never on: it waits for the AUTO button)
    let bars = defaults.integer(forKey: Self.autoMixBarsKey)
    let every = defaults.object(forKey: Self.autoMixEveryKey) as? Int ?? 0
    if bars > 0 || every > 0 {
      dj.setAutoMix(on: false, bars: bars > 0 ? bars : AutoMixSettings.defaultBars, every: every)
    }
  }

  // MARK: auto-mix

  /// Auto-mix on or off with its settings (the AUTO button, its length and phrase choices);
  /// the length and phrases are remembered.
  func setAutoMix(on: Bool, bars: Int, every: Int) {
    guard let dj else { return }
    dj.perform(.autoMix(on: on, bars: bars, every: every))
    defaults.set(dj.autoMix.settings.bars, forKey: Self.autoMixBarsKey)
    defaults.set(dj.autoMix.settings.every, forKey: Self.autoMixEveryKey)
    poll()
  }

  func toggleAutoMix() {
    let s = dj?.autoMix.settings ?? AutoMixSettings()
    setAutoMix(on: !s.on, bars: s.bars, every: s.every)
  }

  func setAutoMixBars(_ bars: Int) {
    let s = dj?.autoMix.settings ?? AutoMixSettings()
    setAutoMix(on: s.on, bars: bars, every: s.every)
  }

  func setAutoMixEvery(_ every: Int) {
    let s = dj?.autoMix.settings ?? AutoMixSettings()
    setAutoMix(on: s.on, bars: s.bars, every: every)
  }

  /// Hand off at the next phrase boundary at least 4 bars away.
  func autoMixNow() {
    dj?.perform(.autoMixNow)
    poll()
  }

  // MARK: wander

  /// The deck's walk on or off (the Wander button; the Inpulse's browser push).
  func setWander(_ deck: String, _ on: Bool) {
    dj?.perform(.wander(deck: deck, on: on))
    poll()
  }

  /// Bars per wander move (4, 8, 16, 32), remembered for the deck.
  func setWanderPace(_ deck: String, _ bars: Int) {
    dj?.perform(.wanderPace(deck: deck, bars: bars))
    defaults.set(dj?[deck]?.wander.pace ?? bars, forKey: Self.wanderPaceKey(deck))
    poll()
  }

  /// Lock a dimension of the walk (or keep a part), or free it; remembered for the deck. The
  /// tempo and key locks hold what plays at the moment they are set.
  func setWanderLock(_ deck: String, _ dimension: String, _ on: Bool) {
    dj?.perform(.wanderLock(deck: deck, dimension: dimension, on: on))
    defaults.set(dj?[deck]?.wander.locks.sorted() ?? [], forKey: Self.wanderLocksKey(deck))
    poll()
  }

  /// ★ on a move of the walk: star the track it led to (or played on); again, unstar it.
  @discardableResult
  func keepWanderMove(_ move: WanderMove) -> Favorite? {
    guard let spec = move.spec else { return nil }
    if let cid = DeckSourceDescriptor.net(spec).favoriteCID, isFavoriteSpec(spec) {
      removeFavorite(cid: cid)
      return nil
    }
    let name = BeatsTables.shared.genres[spec.genre]?.name ?? spec.genre
    do {
      let f = Favorite(title: generateTrackName(genre: name, seed: spec.seed), source: .net(spec))
      favorites = try favoritesStore.add(f)
      journal?.record(.favoriteAdd(f))
      return f
    } catch {
      status = "favorites: \(error)"
      return nil
    }
  }

  func isFavoriteSpec(_ spec: TrackSpec?) -> Bool {
    guard let cid = spec.flatMap({ DeckSourceDescriptor.net($0).favoriteCID }) else { return false }
    return favorites.contains { $0.cid == cid }
  }
  func fire(_ deck: String, _ macro: NetMacro) { dj?.perform(.macro(deck: deck, id: macro.id)) }
  func fire(_ deck: String, _ macro: MasterMacro) { dj?.perform(.macro(deck: deck, id: macro.id)) }
  func panic(_ deck: String) { dj?.perform(.panic(deck: deck)) }
  func stinger(_ deck: String, _ n: Int) { dj?.perform(.stinger(deck: deck, n: n)) }
  func mixOut(_ deck: String) {
    dj?.perform(.mixOut(deck: deck, bars: MixOutTail.defaultBars))
  }
  func mixIn(_ deck: String) {
    dj?.perform(.mixIn(deck: deck, bars: DeckAction.defaultMixInBars))
  }
  func skipToNext(_ deck: String) { dj?.perform(.nextTrack(deck: deck)) }
  func sync(_ deck: String) { dj?.perform(.sync(deck: deck, align: "bar")) }
  func cycleQuantize(_ deck: String) {
    guard let d = dj?[deck] else { return }
    let next = d.quantize == .off ? "beat" : (d.quantize == .beat ? "bar" : "off")
    dj?.perform(.quantize(deck: deck, mode: next))
  }

  @discardableResult
  func load(_ deck: String, url: URL) -> Bool {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    do {
      let buffer = try Deck.decode(url, sampleRate: dj?.sampleRate ?? 48_000)
      dj?.perform(
        .load(
          deck: deck,
          source: .sample(
            id: "", title: url.deletingPathExtension().lastPathComponent, grid: nil)),
        buffer: buffer)
      dj?[deck]?.sourceFile = url
      return true
    } catch {
      status = "\(error)"
      return false
    }
  }

  // Session recording
  var isRecording = false
  var lastSession: String?
  /// Where a publish to cdn.stackdump.com is. The bar under the decks shows it.
  var publishState: PublishState = .idle
  private var recorder: SessionRecorder?
  /// The set the Export / Publish buttons act on (settable for tests).
  var lastSessionValue: Session?

  enum PublishState: Equatable {
    case idle
    case working(String)
    /// `live` is whether the public URL answered before the poll gave up: the mirror runs in
    /// the background and can take a while for a long WAV.
    case published(url: String, live: Bool, reloaded: Bool)
    case failed(String)

    var isWorking: Bool { if case .working = self { true } else { false } }
  }

  struct PublishOptions: Equatable {
    var title: String?
    var draft = false
    var includeAudio = true
    /// Publish a set that plays local-only sounds (the Minecraft bank) anyway.
    var allowLocalOnly = false
  }

  func toggleRecording() {
    guard let dj else { return }
    if let r = recorder {
      let session = r.finish()
      recorder = nil
      isRecording = false
      do {
        let saved = try SessionStore().save(session)
        journal?.record(.mark("session.saved \(saved.cid)"))
        lastSession = saved.cid
        lastSessionValue = session
        status = String(
          format: "saved %.0f s set %@…", session.duration, String(saved.cid.prefix(14)))
      } catch {
        status = "could not save session: \(error)"
      }
    } else {
      do {
        recorder = try SessionRecorder.start(on: dj)
        journal?.record(.mark("session.start"))
        isRecording = true
        status = "recording"
      } catch {
        status = "can't record yet: \(error)"
      }
    }
  }

  /// Publish the last recorded set to cdn.stackdump.com. Asks first, with a title and a draft
  /// switch: this one is public (a draft is hidden from the feed and search but still
  /// reachable by its CID). No credentials are involved: it stages over the existing ssh key.
  func publishLastSession() {
    guard let session = lastSessionValue, dj != nil, !publishState.isWorking else { return }
    // stock loops on the row: refused outright, nothing to ask
    let imported = session.importedClips
    guard imported.isEmpty else {
      let why = "\(PublishError.importedClips(imported))"
      publishState = .failed(why)
      status = why
      return
    }
    let alert = NSAlert()
    alert.messageText = "Publish this set to cdn.stackdump.com?"
    alert.informativeText =
      "Uploads the session and a WAV render, content-addressed as \(session.cid). "
      + "It becomes public at cdn.stackdump.com/ipfs/\(session.cid)/."
    let title = NSTextField(string: "Live set \(session.cid.prefix(10))")
    title.frame = NSRect(x: 0, y: 28, width: 300, height: 24)
    let draft = NSButton(
      checkboxWithTitle: "Draft (hidden from the CDN feed and search)", target: nil, action: nil)
    draft.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
    box.addSubview(title)
    box.addSubview(draft)
    // a set that plays sounds built from this Mac's game assets is refused unless ticked
    let local = session.localOnlySounds
    let allow = NSButton(
      checkboxWithTitle: "Publish anyway (plays this Mac's Minecraft sounds)", target: nil,
      action: nil)
    if !local.isEmpty {
      box.frame.size.height = 84
      title.frame.origin.y = 56
      draft.frame.origin.y = 28
      allow.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
      box.addSubview(allow)
      alert.informativeText +=
        "\n\nThis set plays sounds built from your own Minecraft install, for this Mac only: "
        + "it is not published unless you tick the box."
    }
    alert.accessoryView = box
    alert.addButton(withTitle: "Publish")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let options = PublishOptions(
      title: name.isEmpty ? nil : name, draft: draft.state == .on,
      allowLocalOnly: !local.isEmpty && allow.state == .on)
    Task { @MainActor in await publish(options: options) }
  }

  /// The publish itself: render the WAV, stage on the CDN master (valoper) over ssh as the
  /// render farm does, reload the index, start the mirror push, then poll until the public URL
  /// answers. Everything blocking runs off the main actor; `publishState` narrates it.
  func publish(
    options: PublishOptions = PublishOptions(),
    transport: CDNTransport = SSHTransport(),
    probe: PublicProbe = PublicProbe(),
    mirror: Bool = true
  ) async {
    guard let session = lastSessionValue, let dj else { return }
    guard !publishState.isWorking else { return }
    let library = dj.sampleLibrary
    let stamp = ISO8601DateFormatter().string(from: Date())
    publishState = .working(options.includeAudio ? "rendering the set…" : "preparing…")
    status = "publishing…"
    let report: @Sendable (String) -> Void = { text in
      Task { @MainActor in self.publishState = .working(text) }
    }
    let outcome: Result<PublishState, Error> = await Task.detached {
      do {
        var wav: [UInt8]?
        if options.includeAudio {
          let audio = try SessionPlayer(session: session, samples: { library[$0] }).render()
          wav = [UInt8](try WAV.encode(audio, float32: false))
        }
        let bundle = try SessionBundle(
          session: session, title: options.title, audioWAV: wav, renderedAt: stamp,
          draft: options.draft, allowLocalOnly: options.allowLocalOnly)
        let r = try publishSession(bundle, via: transport, mirror: mirror) { step in
          switch step {
          case .staging(let file, let i, let n): report("uploading \(file) (\(i)/\(n))…")
          case .reloading: report("reloading the CDN index…")
          case .mirroring: report("starting the mirror push to pflow.dev…")
          case .done: break
          }
        }
        guard mirror else {
          return .success(.published(url: r.url, live: false, reloaded: r.reloaded))
        }
        let live = probe.wait(for: bundle) { n in report("waiting for the mirror… (\(n))") }
        return .success(.published(url: r.url, live: live, reloaded: r.reloaded))
      } catch {
        return .failure(error)
      }
    }.value
    switch outcome {
    case .success(let state):
      publishState = state
      if case .published(let url, let live, let reloaded) = state {
        status =
          "published " + (reloaded ? "" : "(index reload failed) ")
          + (live ? "" : "(mirror still syncing) ") + url
      }
    case .failure(let error):
      publishState = .failed("\(error)")
      status = "publish failed: \(error)"
    }
  }

  func copyPublishedURL() {
    guard case .published(let url, _, _) = publishState else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
  }

  /// Re-render the last recorded set to a WAV (off the main thread).
  func exportLastSession() {
    guard let session = lastSessionValue, let dj else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.wav]
    panel.nameFieldStringValue = "set-\(session.cid.prefix(10)).wav"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let library = dj.sampleLibrary
    status = "rendering…"
    Task.detached {
      do {
        try SessionStore.exportWAV(session, to: url, samples: { library[$0] })
        await MainActor.run { self.status = "exported \(url.lastPathComponent)" }
      } catch {
        await MainActor.run { self.status = "export failed: \(error)" }
      }
    }
  }
}

public struct ContentView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    VStack(spacing: 0) {
      // The decks and the panels under them scroll when the window is too short for them; the
      // bottom bar stays put. Without the scroll view the content's height was the window's
      // minimum, so decks + Scopes (up to 640 pt) could ask for more than the screen has and the
      // window ran off its bottom edge. When everything fits it is laid out plainly: no scroller,
      // and `ImageRenderer` (the layout tests) cannot draw an NSScrollView-backed ScrollView.
      // Both choices — scroll or not, wide decks or stacked — come from sizes already known (the
      // space here, the content's last height), not from `ViewThatFits`, which lays out every
      // candidate in full on every update: at 30 polls a second that took most of the main thread.
      GeometryReader { geo in
        let wide = geo.size.width >= Self.wideWidth
        let mixer = Self.mixerWidth(window: geo.size.width, wide: wide)
        if panelsHeight > geo.size.height + 1 {
          ScrollView(.vertical) { measured(panels(wide: wide, mixer: mixer)) }
        } else {
          measured(panels(wide: wide, mixer: mixer))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
      }
      Divider()
      bottomBar.padding()
    }
    .background {
      if model.showScopes { ScreenHeightReader { model.scopeWindowHeight = $0 } }
    }
    // the rings and the small animations pace themselves by the hub's visual level
    .environment(\.scopeHub, model.scopeHub)
    // arrow keys step through whatever list of choices the mouse is over
    .onAppear {
      HoverKeys.shared.install()
      model.openStageWindow = { [openWindow] in openWindow(id: StageWindow.id) }
      model.closeStageWindow = { [dismissWindow] in dismissWindow(id: StageWindow.id) }
    }
    // what auto mode did to the visuals (SPEC mode 27): a toast over the window's foot for its
    // 8 s, as monitor.js' is (bottom centre), so it takes no room from the header or the bottom
    // bar, which are full at the window's minimum width
    .overlay(alignment: .bottom) {
      if let scopes = model.scopeHub {
        VizNoticeView(perf: scopes.perf).padding(.bottom, 64)
      }
    }
  }

  /// The three cards share one height (the tallest's), so their edges line up as one row.
  private func deckRow(wide: Bool, mixer: CGFloat) -> some View {
    HStack(alignment: .top, spacing: DJStyle.l) {
      DeckView(name: "A", model: model, tint: DJStyle.deckA, wide: wide)
        .frame(maxHeight: .infinity, alignment: .top).djCard(tint: DJStyle.deckA)
      MixerView(model: model)
        .frame(width: mixer).frame(maxHeight: .infinity, alignment: .top).djCard()
      DeckView(name: "B", model: model, tint: DJStyle.deckB, wide: wide)
        .frame(maxHeight: .infinity, alignment: .top).djCard(tint: DJStyle.deckB)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The panels' height when last laid out, which decides whether they scroll.
  @State private var panelsHeight: CGFloat = 0

  /// The narrowest window that takes the wide deck row: both decks at their core plus the
  /// narrowest sections column, the mixer, the gaps, the cards' padding and the window's.
  static let wideWidth: CGFloat = {
    let deck = 260 + DJStyle.l + 260 + 2 * DJStyle.cardPadding
    let mixer = 160 + 2 * DJStyle.cardPadding
    return 2 * deck + mixer + 2 * DJStyle.l + 2 * 16
  }()

  /// The narrowest window that takes the stacked deck row (a deck at its 260 pt floor each).
  static let stackedWidth: CGFloat = {
    let deck = 260 + 2 * DJStyle.cardPadding
    return 2 * deck + (160 + 2 * DJStyle.cardPadding) + 2 * DJStyle.l + 2 * 16
  }()

  /// The mixer's width: 160 pt at the narrowest, up to 220 as the window widens (15% of the
  /// width past the layout's floor). Computed here rather than left to a flexible frame: an
  /// `HStack` hands a flexible child its maximum before the decks have claimed their minimum, so
  /// a mixer allowed to 220 pushed the row past a 1400 pt window.
  static func mixerWidth(window: CGFloat, wide: Bool) -> CGFloat {
    let slack = max(0, window - (wide ? wideWidth : stackedWidth))
    return min(220, 160 + (slack * 0.15).rounded(.down))
  }

  private func measured(_ content: some View) -> some View {
    content.padding()
      .frame(maxWidth: .infinity, alignment: .top)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        panelsHeight = $0
      }
  }

  private func panels(wide: Bool, mixer: CGFloat) -> some View {
    VStack(spacing: 16) {
      // a wide window gives each deck a second column for its sections; a narrow one stacks them
      deckRow(wide: wide, mixer: mixer)
      // the FX unit: one panel for A, B and the loops, under the deck row in both layouts
      if model.showFxUnit { FxUnitPanel(model: model).djCard(tint: model.fxTint) }
      if model.showSoundboard { SoundboardView(model: model).djCard(tint: LoopRowView.tint) }
      // the row appears with the first take (and stays while there are clips)
      if !model.clips.isEmpty || !model.recording.isEmpty {
        LoopRowView(model: model).djCard(tint: LoopRowView.tint)
      }
      // The map (or the control walk) and the pad grid share a row: the map takes whatever the
      // pads leave, so a wide window no longer stacks a 300 pt square under a 240 pt strip with
      // the right half of both empty.
      if showsLowerRow {
        HStack(alignment: .top, spacing: DJStyle.xl) {
          if let w = model.walk {
            WalkPanel(
              walk: w, reportPath: model.walkReportPath, skip: { model.walkSkip() },
              back: { model.walkBack() }, stop: { model.stopWalk() }
            )
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
          } else if model.showControllers {
            ControllersView(model: model)
              .frame(maxWidth: .infinity)
          } else if model.showMap {
            DeviceMapView(
              maps: SurfaceProfile.all.map { ($0.name, $0.deviceMap()) },
              highlight: model.lastControl.flatMap {
                Date().timeIntervalSince($0.at) < 1.5 ? ($0.device, $0.group, $0.index) : nil
              },
              lights: model.deviceLights
            )
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
          }
          if model.showPads, let pads = model.padLights["pads"] {
            PadGridView(
              pads: pads, tracks: model.padLights["track"] ?? [],
              scenes: model.padLights["scene"] ?? []
            ) { model.pressPad($0, $1, shift: NSEvent.modifierFlags.contains(.shift)) }
            .frame(width: 300, height: 300)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      if model.showScopes, let scopes = model.scopeHub {
        ScopePanelView(
          hub: scopes,
          kind: Binding(get: { model.scopeKind }, set: { model.scopeKind = $0 }),
          source: Binding(get: { model.scopeSource }, set: { model.scopeSource = $0 }),
          measured: Binding(get: { model.scopeMeasured }, set: { model.scopeMeasured = $0 }),
          windowHeight: model.scopeWindowHeight)
      }
    }
  }

  private var showsLowerRow: Bool {
    model.walk != nil || model.showControllers || model.showMap
      || (model.showPads && model.padLights["pads"] != nil)
  }

  private var bottomBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Controllers").font(.caption.bold())
        if model.devices.isEmpty {
          Text("none — plug in an Inpulse 200 MK3, APC mini mk2 or MPK Mini").font(.caption)
        }
        ForEach(model.devices, id: \.port) { d in
          Text("● \(d.profile)").font(.caption).foregroundStyle(.green)
        }
      }
      Spacer()
      HStack {
        Toggle(
          "Controllers",
          isOn: Binding(get: { model.showControllers }, set: { model.showControllers = $0 })
        )
        .toggleStyle(.button)
        .help("Every controller drawn as it looks, each control labelled with what it does")
        Toggle("Map", isOn: Binding(get: { model.showMap }, set: { model.showMap = $0 }))
          .toggleStyle(.button)
        Toggle(
          SoundboardView.title,
          isOn: Binding(get: { model.showSoundboard }, set: { model.setShowSoundboard($0) })
        )
        .toggleStyle(.button).help(SoundboardView.help)
        Toggle(
          model.fxUnits.values.contains { $0.settings.isActive } ? "FX unit ●" : "FX unit",
          isOn: Binding(get: { model.showFxUnit }, set: { model.setShowFxUnit($0) })
        )
        .toggleStyle(.button).help(FxUnitPanel.help)
        // one button per attached controller: walk through its controls
        ForEach(model.devices, id: \.port) { d in
          Button("Check \(d.profile)") { model.startWalk(device: d.profile) }
            .help("Walk through every control on the \(d.profile)")
        }
        Toggle("Pads", isOn: Binding(get: { model.showPads }, set: { model.setShowPads($0) }))
          .toggleStyle(.button)
        Toggle(
          "Awake",
          isOn: Binding(get: { model.keepScreenAwake }, set: { model.setKeepScreenAwake($0) })
        )
        .toggleStyle(.button).help("Keep the screen from going to sleep while DJApp is open")
        Toggle("Scopes", isOn: Binding(get: { model.showScopes }, set: { model.showScopes = $0 }))
          .toggleStyle(.button)
        // The Stage (SPEC modes 7…21) is not a ScopeKind: it has a window of its own.
        Button(StageWindow.title) { openWindow(id: StageWindow.id) }
          .disabled(!StageWindow.canOpen(model))
        Toggle(
          model.isRecording ? "● REC" : "Record",
          isOn: Binding(get: { model.isRecording }, set: { _ in model.toggleRecording() })
        )
        .toggleStyle(.button).tint(.red)
        Button("Export WAV…") { model.exportLastSession() }
          .disabled(model.lastSession == nil || model.isRecording)
        Button("Publish…") { model.publishLastSession() }
          .disabled(
            model.lastSession == nil || model.isRecording || model.publishState.isWorking)
      }
      VStack(alignment: .trailing, spacing: 2) {
        PublishStatusLine(model: model)
        Text(model.status).font(.caption)
        if let cid = model.lastSession {
          Text(cid).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(
            .enabled)
        }
        Text(model.lastMessage).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(
          1)
        Text("build \(BuildInfo.current.id)").font(.caption2.monospaced()).foregroundStyle(
          .tertiary
        ).textSelection(.enabled).help(BuildInfo.current.dateString.map { "built \($0)" } ?? "")
      }
    }
  }
}

/// The publish progress / result under the bottom bar: a spinner and the step while it runs,
/// then the public URL as a link with a Copy button, or the error.
struct PublishStatusLine: View {
  let model: AppModel

  var body: some View {
    switch model.publishState {
    case .idle:
      EmptyView()
    case .working(let text):
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(text).font(.caption)
      }
    case .published(let url, let live, let reloaded):
      HStack(spacing: 6) {
        if let link = URL(string: url) { Link(url, destination: link).font(.caption) }
        Button("Copy") { model.copyPublishedURL() }.controlSize(.small)
        if !live {
          Text("mirror syncing — the link works once it lands").font(.caption2).foregroundStyle(
            .secondary)
        } else if !reloaded {
          Text("live (index reload failed)").font(.caption2).foregroundStyle(.secondary)
        }
      }
    case .failed(let message):
      Text("publish failed: \(message)").font(.caption).foregroundStyle(.red).lineLimit(3)
        .textSelection(.enabled)
    }
  }
}

struct DeckView: View {
  let name: String
  let model: AppModel
  let tint: Color
  /// Two columns: the deck's core beside the mixer, its sections on the outer side (deck A's
  /// left, deck B's right). Otherwise the sections sit under the core.
  var wide = false
  @State private var importing = false

  var state: DeckState { model.decks[name] ?? .init() }

  /// What the sections column asks for in a wide window (it grows to `maxWidth` when there is
  /// room): `ContentView` picks the wide layout when both decks fit at this width.
  static let sectionsWidth: (ideal: CGFloat, max: CGFloat) = (300, 460)

  /// The deck's core (platter, readouts, rings, channel strip) is as wide as the window gives it,
  /// within these bounds: the floor is the old fixed width, so the narrowest layouts are
  /// unchanged. The cap is where its sliders and ring grid stop gaining anything; the ring grid
  /// adds a column per ~62 pt (`NetRingsView`) as the core widens.
  static let coreWidth: (min: CGFloat, max: CGFloat) = (260, 400)
  /// A stacked deck (a window narrower than `ContentView.wideWidth`) stops widening here.
  static let stackedMaxWidth: CGFloat = 520

  var body: some View {
    Group {
      if wide {
        HStack(alignment: .top, spacing: DJStyle.l) {
          if name == "A" { sectionsColumn }
          core.frame(maxHeight: .infinity, alignment: .top)
            .frame(minWidth: Self.coreWidth.min, maxWidth: Self.coreWidth.max)
          if name != "A" { sectionsColumn }
        }
      } else {
        VStack(spacing: DJStyle.s) {
          core
          sections
        }
        // stacked: the deck takes what the window leaves (the core and its sections together)
        .frame(minWidth: Self.coreWidth.min, maxWidth: Self.stackedMaxWidth)
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
      if case .success(let url) = result { model.load(name, url: url) }
    }
  }

  private var sections: some View {
    DeckSections(name: name, state: state, model: model, tint: tint) { importing = true }
  }

  private var sectionsColumn: some View {
    sections
      .frame(
        minWidth: 260, idealWidth: Self.sectionsWidth.ideal, maxWidth: Self.sectionsWidth.max,
        alignment: .topLeading)
  }

  /// Platter, readouts, transport, the song and its rings, and the channel strip.
  private var core: some View {
    VStack(spacing: DJStyle.m) {
      header
      PlatterView(
        seconds: state.platterSeconds, touching: state.touching, tint: tint,
        beatInBar: state.bpm == nil ? nil : state.beatInBar
      )
      .frame(width: 150, height: 150)
      readout
      transport
      if !state.isNet {
        WaveformStrip(overview: state.overview, overlay: state.overlay, tint: tint)
          .frame(height: 46)
      }
      if let clip = state.clipID {
        Button("↩ back to Loops") { model.playClip(clip, on: "L") }
          .controlSize(.small).help("Move this clip back onto the loop channel")
      }
      if state.isNet {
        VStack(spacing: DJStyle.s) {
          SectionLabel("Song")
          SectionTimelineView(timeline: state.timeline) { model.launchSection(name, $0) }
            .frame(height: 26)
          if let scopes = model.scopeHub {
            TimelineDotsView(
              feed: scopes.feed(.deck(name)), hub: scopes, active: state.playing || state.scrubbing)
          }
          NetRingsView(snapshot: state.snapshot, tint: tint, arcs: state.ringArcs)
        }
      }
      // the channel strip sits at the card's foot: both decks' faders and the crossfader in a row
      Spacer(minLength: 0)
      VStack(spacing: DJStyle.xs) {
        SectionLabel("Channel")
        LabeledSlider(
          label: "Vol", value: Binding(get: { state.volume }, set: { model.setVolume(name, $0) }),
          range: 0...1)
        LabeledSlider(
          label: "Filter",
          value: Binding(get: { state.filter }, set: { model.setFilter(name, $0) }), range: 0...1)
        LabeledSlider(
          label: String(format: "Pitch %+.1f%%", state.pitch * Deck.pitchRange * 100),
          value: Binding(get: { state.pitch }, set: { model.setPitch(name, $0) }), range: -1...1)
        if state.nudge != 0 {
          Text(String(format: "nudge %+.1f%%", state.nudge * 100)).font(.caption)
            .foregroundStyle(tint)
        }
      }
    }
    .frame(minWidth: Self.coreWidth.min, maxWidth: .infinity)
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first else { return false }
      model.playClip(id, on: name)
      return true
    }
  }

  /// The deck's letter, what it plays (the most important line on the deck) and its star.
  private var header: some View {
    HStack(spacing: DJStyle.s) {
      DeckBadge(name: name, tint: tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(state.title).font(.headline).lineLimit(1).truncationMode(.tail)
          .contentTransition(.opacity)
        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .animation(.easeOut(duration: 0.25), value: state.title)
      if model.autoMix.incoming == name {
        // auto-mix put the next track here: it can be pre-listened on the headphone cue
        Text("NEXT · auto").font(.caption2.weight(.semibold)).foregroundStyle(tint)
          .padding(.horizontal, 5).padding(.vertical, 1)
          .overlay(Capsule().stroke(tint.opacity(0.6)))
          .help("Auto-mix: the next track, coming in at the hand-off")
      }
      if state.sourceCID != nil {
        let starred = model.isFavorite(name)
        Button {
          model.toggleFavorite(name)
        } label: {
          Image(systemName: starred ? "star.fill" : "star")
            .foregroundStyle(starred ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(starred ? "Remove from favorites" : "Add to favorites")
      }
    }
  }

  /// "live net · 6 sections", "audio · 0.0 s"…: what kind of source, at a glance.
  private var subtitle: String {
    if state.isNet {
      let n = state.sections.count
      return n > 0 ? "live net · \(n) sections" : "live net · loop"
    }
    return state.duration > 0 ? "audio · \(clock(state.duration))" : "audio"
  }

  /// Position, tempo and beat: big enough to read from the controller.
  private var readout: some View {
    HStack(alignment: .firstTextBaseline, spacing: DJStyle.s) {
      Text(clock(state.positionSeconds)).font(DJStyle.readout)
      // a song is counted in bars (where the phrases turn), a sample in time
      Text(
        state.isNet && state.bars > 0
          ? "bar \(min(state.bar, state.bars)) of \(state.bars)" : "/ \(clock(state.duration))"
      )
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      .contentTransition(.numericText())
      Spacer(minLength: DJStyle.s)
      if let bpm = state.bpm {
        Text(String(format: "%.1f", bpm)).font(DJStyle.readout).foregroundStyle(tint)
        Text("BPM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      }
    }
    .overlay(alignment: .bottomLeading) {
      // the turntable's rate is meaningful only for audio decks
      if !state.isNet && state.rate != 0 && abs(state.rate - 1) > 0.0005 {
        Text(String(format: "%.3f×", state.rate)).font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary).offset(y: 14)
      }
    }
  }

  /// Play / pause, cue (PFL), LOOP record and the four hot cues in one row, and LOOP's tap
  /// length and grab buttons on a line under it. The core is 260 pt wide, which never holds
  /// them beside LOOP, so this is fixed rather than a `ViewThatFits` (which would lay out both
  /// candidates on every update, 30 polls a second per deck, to pick the same one each time).
  private var transport: some View {
    VStack(alignment: .leading, spacing: DJStyle.xs) {
      transportRow
      // the second line: LOOP's tap length and grab, then the hot cues (beside ▶ / Cue / LOOP
      // on the first line they were squeezed until their numbers no longer showed)
      HStack(spacing: 4) {
        TapLengthChip(model: model)
        GrabBarsControl(name: name, model: model)
        Spacer(minLength: DJStyle.s)
        hotCues
      }
    }
    .overlay(alignment: .topTrailing) {
      if state.scrubbing {
        Text("SCRATCH").font(.caption2.bold()).foregroundStyle(tint).offset(y: -14)
      }
    }
  }

  private var transportRow: some View {
    HStack(spacing: DJStyle.s) {
      Button {
        model.togglePlay(name)
      } label: {
        Image(systemName: state.playing ? "pause.fill" : "play.fill")
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(TransportButtonStyle(tint: tint, active: state.playing))
      .keyboardShortcut(name == "A" ? "a" : "b", modifiers: [])
      .help(state.playing ? "Pause" : "Play")
      .accessibilityLabel(state.playing ? "Pause" : "Play")
      .lockable(DJActionKind.lockKey(deck: name, .play), model)
      Toggle("Cue", isOn: Binding(get: { state.pfl }, set: { model.setPFL(name, $0) }))
        .toggleStyle(.button).help("Pre-fade listen: this deck in the headphones")
        .lockable(DJActionKind.lockKey(deck: name, .pfl), model)
      LoopRecordButton(name: name, model: model)
      Spacer(minLength: 0)
    }
  }

  /// Hot cues 1–4: set at the playhead, then jump; right-click to clear or lock.
  private var hotCues: some View {
    HStack(spacing: DJStyle.xs) {
      ForEach(0..<4, id: \.self) { slot in
        let key = DJActionKind.lockKey(deck: name, .hotcue, param: "\(slot)")
        let locked = model.isLocked(key)
        Button("\(slot + 1)") { model.hotCue(name, slot) }
          .tint(state.cues.contains(slot) ? tint : nil)
          .buttonStyle(.borderedProminent).controlSize(.small)
          .environment(\.isEnabled, !locked).opacity(locked ? 0.4 : 1)
          .contextMenu {
            Button("Clear cue \(slot + 1)") { model.clearCue(name, slot) }
            Button(locked ? "Enable" : "Disable") { model.setLocked(key, !locked) }
              .environment(\.isEnabled, true)
          }
          .help(
            state.cues.contains(slot)
              ? "Jump to cue (right-click to clear)" : "Set cue at playhead")
      }
    }
  }

  func clock(_ s: Double) -> String {
    String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
  }
}

struct MixerView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 14) {
      SectionLabel("Mixer")
      LabeledSlider(
        label: "Master", value: Binding(get: { model.master }, set: { model.setMaster($0) }),
        range: 0...1)
      // The master flame (SPEC mode 28): feed.html's equalizer bars over the master tap; the flat
      // line while no deck plays.
      if let scopes = model.scopeHub {
        MasterFlameView(
          hub: scopes, active: model.decks.values.contains { $0.playing || $0.scrubbing })
      }
      LabeledSlider(
        label: "Phones",
        value: Binding(get: { model.headphoneLevel }, set: { model.setHeadphoneLevel($0) }),
        range: 0...1)
      LabeledSlider(
        label: "Cue ↔ Mix",
        value: Binding(get: { model.headphoneMix }, set: { model.setHeadphoneMix($0) }),
        range: 0...1)
      SyncPanel(
        rows: [("A", DJStyle.deckA), ("B", DJStyle.deckB)].map { name, tint in
          let s = model.decks[name] ?? .init()
          return SyncPanel.Row(
            name: name, tint: tint, bpm: s.bpm, beat: s.beatInBar, playing: s.playing)
        }
      )
      .padding(.top, DJStyle.s)
      if model.inpulseOutput != nil || model.inpulseRouted {
        Toggle(
          "Inpulse out (1/2 master, 3/4 cue)",
          isOn: Binding(get: { model.inpulseRouted }, set: { _ in model.toggleInpulseOutput() })
        )
        .font(.caption).help("[UNVERIFIED on hardware] needs the Inpulse's own audio interface")
      }
      // the crossfader sits at the card's foot, level with the decks' channel faders
      Spacer(minLength: DJStyle.xl)
      VStack(spacing: 2) {
        Slider(
          value: Binding(get: { model.crossfader }, set: { model.setCrossfader($0) }), in: 0...1)
        HStack {
          Text("A")
          Spacer()
          Text("crossfader").foregroundStyle(.secondary)
          Spacer()
          Text("B")
        }
        .font(.caption)
        AutoMixPanel(model: model)
          .padding(.top, DJStyle.s)
      }
    }
    // 160 pt unless the row sets its width (`ContentView.mixerWidth`)
    .frame(minWidth: 160)
  }
}

struct LabeledSlider: View {
  let label: String
  let value: Binding<Double>
  let range: ClosedRange<Double>

  var body: some View {
    HStack {
      Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
        .monospacedDigit()
      Slider(value: value, in: range)
    }
  }
}

/// Performance controls for a deck running a live net.
struct NetPanel: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      FlowRow(spacing: 6) {
        ForEach(state.roles, id: \.self) { r in
          let off = state.disabledRoles.contains(r)
          Toggle(
            isOn: Binding(
              get: { state.rolesOn.contains(r) }, set: { _ in model.toggleRole(name, r) })
          ) {
            Text(off ? "⊘ \(r)" : r).strikethrough(off)
          }
          .toggleStyle(.button).liveButton().tint(tint)
          .opacity(off ? 0.45 : 1)
          .macroPulseGlow(state.macroPulse.level(of: r))
          .contextMenu {
            if off {
              Button("Enable \(r)") { model.setRoleDisabled(name, r, false) }
            } else {
              Button("Disable \(r) (stays off through new tracks)") {
                model.setRoleDisabled(name, r, true)
              }
            }
          }
          .help(
            off
              ? "Disabled: off through new tracks (right-click to enable)"
              : "Mute / unmute (right-click: disable through new tracks)")
        }
      }
      FlowRow(spacing: 6) {
        ForEach(NetMacro.allCases, id: \.rawValue) { m in
          MacroButton(macro: m, running: state.macroPulse.isRunning(m)) { model.fire(name, m) }
            .lockable(DJActionKind.lockKey(deck: name, .macro, param: m.id), model)
        }
        Button("Panic") { model.panic(name) }.liveButton().tint(.red)
          .lockable(DJActionKind.lockKey(deck: name, .panic), model)
      }
      // A wrapping row, not an HStack: at live-mixing size these no longer fit one line in a
      // 260 pt deck, and a squeezed button truncates its own label.
      FlowRow(spacing: 6) {
        ForEach(0..<4, id: \.self) { n in
          Button("Hit \(n + 1)") { model.stinger(name, n) }.liveButton()
            .help(state.stingers.indices.contains(n) ? state.stingers[n] : "Hit \(n + 1)")
            .lockable(DJActionKind.lockKey(deck: name, .stinger, param: "\(n)"), model)
        }
        WanderButton(name: name, on: state.wander.on, model: model, tint: tint)
        MixButtons(name: name, state: state, model: model, tint: tint)
        Button("Sync") { model.sync(name) }.liveButton()
          .lockable(DJActionKind.lockKey(deck: name, .sync), model)
        Button("Q: \(state.quantize)") { model.cycleQuantize(name) }.liveButton()
          .lockable(DJActionKind.lockKey(deck: name, .quantize), model)
        Button(state.nextReady ? "Next ▶︎" : (state.nextComposing ? "…" : "Next")) {
          model.skipToNext(name)
        }
        .liveButton().disabled(!state.nextReady)
        .lockable(DJActionKind.lockKey(deck: name, .nextTrack), model)
      }
    }
  }
}

/// Wraps its children onto as many rows as the width needs.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  /// Each child's ideal size, measured once per change of the children (SwiftUI calls
  /// `updateCache` then) rather than on every size query: the window asks for sizes many times a
  /// frame, and measuring a row of buttons means laying out their text each time.
  struct Cache { var sizes: [CGSize] }

  func makeCache(subviews: Subviews) -> Cache {
    Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache = makeCache(subviews: subviews)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    layout(in: proposal.width ?? 260, sizes: cache.sizes).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let result = layout(in: bounds.width, sizes: cache.sizes)
    for (sub, p) in zip(subviews, result.positions) {
      sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
    }
  }

  // No alignment guides of its own: the default asks every child (and so measures them again).
  func explicitAlignment(
    of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout Cache
  ) -> CGFloat? { nil }

  func explicitAlignment(
    of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout Cache
  ) -> CGFloat? { nil }

  private func layout(in width: CGFloat, sizes: [CGSize]) -> (size: CGSize, positions: [CGPoint]) {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var maxX: CGFloat = 0
    var positions: [CGPoint] = []
    for size in sizes {
      if x > 0 && x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      positions.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      maxX = max(maxX, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return (CGSize(width: maxX, height: y + rowHeight), positions)
  }
}

extension View {
  /// The size of a performance button: large enough to hit on a controller-side glance and to
  /// show its whole label. `.small` controls truncated "Panic" and the macro names in a 260 pt
  /// deck. One line, never squeezed: a row that runs out of width wraps (`FlowRow`) instead.
  func liveButton() -> some View {
    self.controlSize(.large).lineLimit(1).fixedSize()
  }
}

struct FlowRow<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content
  var body: some View { FlowLayout(spacing: spacing) { content } }
}

/// Right-click ▸ Disable on a button: greyed out and inert, and the controller buttons bound to
/// the same action (`DJActionKind.lockKey`) ignore presses too, until right-click ▸ Enable.
private struct Lockable: ViewModifier {
  let key: String
  let model: AppModel

  func body(content: Content) -> some View {
    let locked = model.isLocked(key)
    content
      // the button itself, not its menu: Enable has to stay clickable
      .environment(\.isEnabled, !locked)
      .opacity(locked ? 0.4 : 1)
      .contextMenu {
        Button(locked ? "Enable" : "Disable") { model.setLocked(key, !locked) }
          .environment(\.isEnabled, true)
      }
  }
}

extension View {
  func lockable(_ key: String, _ model: AppModel) -> some View {
    modifier(Lockable(key: key, model: model))
  }
}
