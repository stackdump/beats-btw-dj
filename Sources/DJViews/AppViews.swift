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
}

@MainActor @Observable
public final class AppModel {
  public var status = "starting…"
  var devices: [ControllerHub.Device] = []
  var lastMessage = ""
  var decks: [String: DeckState] = ["A": .init(), "B": .init()]
  var crossfader = 0.5
  var master = 0.8
  var headphoneMix = 0.0
  var headphoneLevel = 0.7
  var inpulseOutput: AudioOutputDevice?
  var inpulseRouted = false
  var padLights: [String: [PadLight]] = [:]
  /// Every attached controller's LEDs by profile name, for the device map (SPEC 25).
  var deviceLights: [String: DeviceLights] = [:]
  var padPort: String?
  var showPads = false
  var showMap = false
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
  var walk: ControlWalk?
  var walkReportPath: String?
  var lastControl: (device: String, group: String, index: Int, at: Date)?

  private var dj: DJEngine?
  private var hub: ControllerHub?
  private var refresh: Timer?
  private var injectedRouter: ControllerRouter?
  @ObservationIgnored var controlServer: ControlServer?
  /// The audition playing now (held so it isn't freed mid-sound).
  @ObservationIgnored var auditionSound: NSSound?
  /// Samplers for auditions, apart from the decks' (a sampler renders on one thread only).
  @ObservationIgnored lazy var auditionBank = SamplerBank(sampleRate: dj?.sampleRate ?? 48_000)

  /// The engine and router the UI drives (nil until `start`).
  var engine: DJEngine? { dj }
  var router: ControllerRouter? { hub?.router ?? injectedRouter }

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
  public init(engine: DJEngine? = nil, perf: PerfMonitor? = nil) {
    injected = engine
    injectedPerf = perf
  }
  private let injected: DJEngine?
  private let injectedPerf: PerfMonitor?

  public func start() {
    guard dj == nil else { return }
    if let injected {
      dj = injected
      scopeHub = ScopeHub(engine: injected, perf: injectedPerf ?? PerfMonitor())
      stageModel = scopeHub.map { StageModel(hub: $0) }
      injectedRouter = ControllerRouter(engine: injected)
      status = "\(Int(injected.sampleRate)) Hz"
      poll()
      return
    }
    do {
      let dj = try DJEngine()
      for d in dj.decks.values { d.loadDemo() }
      dj.master = master
      try dj.start()
      let hub = ControllerHub(engine: dj)
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
    controlServer?.stop()
    scopeHub?.perf.stop()
    hub?.stop()
    dj?.stop()
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
    master = dj.master
    headphoneMix = dj.headphoneMix
    headphoneLevel = dj.headphoneLevel
    inpulseOutput = AudioDevices.inpulse()
    if let apc = router?.lights(profileName: SurfaceProfile.apcMiniMK2.name) {
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
        state.masterRunning = Set(d.wave.activeMasterMacros)
        state.duration = Double(d.sections.map(\.steps).reduce(0, +)) * 15 / max(d.netBaseBPM, 1)
        state.positionSeconds = Double(d.wave.tick) * 15 / max(d.effectiveBPM ?? 120, 1)
        state.platterSeconds = state.positionSeconds
        state.bars = d.sections.map(\.steps).reduce(0, +) / 16
        state.bar = d.wave.tick / 16 + 1
      }
      decks[name] = state
    }
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
  func setMaster(_ v: Double) { dj?.perform(.master(v)) }
  // Cue/headphone state doesn't change the master mix a session renders: not recorded.
  /// Show the APC grid on screen; with no hardware attached, a virtual APC takes its place.
  func setShowPads(_ on: Bool) {
    showPads = on
    if on,
      (hub?.router ?? injectedRouter)?.lights(profileName: SurfaceProfile.apcMiniMK2.name) == nil
    {
      (hub?.router ?? injectedRouter)?.attach(port: "APC mini mk2 Control (on screen)")
    }
  }
  func pressPad(_ group: String, _ index: Int) {
    guard let port = padPort else { return }
    (hub?.router ?? injectedRouter)?.press(port: port, group: group, index: index)
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
    guard let dj else { return }
    Task { @MainActor in
      dj.stop()
      do {
        if inpulseRouted {
          try dj.disableCueRouting()
          inpulseRouted = false
        } else if let dev = AudioDevices.inpulse() {
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
    }
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
    let track = await Task.detached(priority: .userInitiated) {
      PreparedTrack(source: source, sampleRate: sr, opts: .extended(samplers: bank))
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
  func queueNext(_ deck: String, _ spec: TrackSpec) {
    dj?.perform(.queueNext(deck: deck, spec: spec))
  }
  func setAutoAdvance(_ deck: String, _ on: Bool) { dj?.perform(.autoAdvance(deck: deck, on: on)) }
  func launchSection(_ deck: String, _ i: Int) { dj?.perform(.section(deck: deck, index: i)) }
  func toggleRole(_ deck: String, _ role: String) {
    guard let d = dj?[deck] else { return }
    dj?.perform(.role(deck: deck, role: role, on: !d.isRoleOn(role)))
  }
  func fire(_ deck: String, _ macro: NetMacro) { dj?.perform(.macro(deck: deck, id: macro.id)) }
  func fire(_ deck: String, _ macro: MasterMacro) { dj?.perform(.macro(deck: deck, id: macro.id)) }
  func panic(_ deck: String) { dj?.perform(.panic(deck: deck)) }
  func stinger(_ deck: String, _ n: Int) { dj?.perform(.stinger(deck: deck, n: n)) }
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
      return true
    } catch {
      status = "\(error)"
      return false
    }
  }

  // Session recording
  var isRecording = false
  var lastSession: String?
  var publishedURL: String?
  private var recorder: SessionRecorder?
  private var lastSessionValue: Session?

  func toggleRecording() {
    guard let dj else { return }
    if let r = recorder {
      let session = r.finish()
      recorder = nil
      isRecording = false
      do {
        let saved = try SessionStore().save(session)
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
        isRecording = true
        status = "recording"
      } catch {
        status = "can't record yet: \(error)"
      }
    }
  }

  /// Publish the last recorded set to cdn.stackdump.com: render its WAV, stage both on valoper
  /// (as the render farm does), reload the CDN index and mirror to pflow.dev. Asks first —
  /// this one is public.
  func publishLastSession() {
    guard let session = lastSessionValue, let dj else { return }
    let alert = NSAlert()
    alert.messageText = "Publish this set to cdn.stackdump.com?"
    alert.informativeText =
      "Uploads the session and a WAV render, content-addressed as \(session.cid). It becomes public."
    alert.addButton(withTitle: "Publish")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let library = dj.sampleLibrary
    let stamp = ISO8601DateFormatter().string(from: Date())
    status = "publishing…"
    Task.detached {
      do {
        let audio = try SessionPlayer(session: session, samples: { library[$0] }).render()
        let wav = [UInt8](try WAV.encode(audio, float32: false))
        let bundle = try SessionBundle(session: session, audioWAV: wav, renderedAt: stamp)
        let r = try publishSession(bundle, via: SSHTransport(), mirror: true)
        await MainActor.run {
          self.publishedURL = r.url
          self.status = "published " + (r.reloaded ? "" : "(index reload failed) ") + r.url
        }
      } catch {
        await MainActor.run { self.status = "publish failed: \(error)" }
      }
    }
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

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    VStack(spacing: 0) {
      // The decks and the panels under them scroll when the window is too short for them; the
      // bottom bar stays put. Without the scroll view the content's height was the window's
      // minimum, so decks + Scopes (up to 640 pt) could ask for more than the screen has and the
      // window ran off its bottom edge. When everything fits it is laid out plainly: no scroller,
      // and `ImageRenderer` (the layout tests) cannot draw an NSScrollView-backed ScrollView.
      ViewThatFits(in: .vertical) {
        panels.padding()
        ScrollView(.vertical) { panels.padding() }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      Divider()
      bottomBar.padding()
    }
    .background {
      if model.showScopes { ScreenHeightReader { model.scopeWindowHeight = $0 } }
    }
    // the rings and the small animations pace themselves by the hub's visual level
    .environment(\.scopeHub, model.scopeHub)
    // what auto mode did to the visuals (SPEC mode 27): a toast over the window's foot for its
    // 8 s, as monitor.js' is (bottom centre), so it takes no room from the header or the bottom
    // bar, which are full at the window's minimum width
    .overlay(alignment: .bottom) {
      if let scopes = model.scopeHub {
        VizNoticeView(perf: scopes.perf).padding(.bottom, 64)
      }
    }
  }

  private var panels: some View {
    VStack(spacing: 16) {
      // the three cards share one height (the tallest's), so their edges line up as one row
      HStack(alignment: .top, spacing: DJStyle.l) {
        DeckView(name: "A", model: model, tint: DJStyle.deckA)
          .frame(maxHeight: .infinity, alignment: .top).djCard(tint: DJStyle.deckA)
        MixerView(model: model)
          .frame(maxHeight: .infinity, alignment: .top).djCard()
        DeckView(name: "B", model: model, tint: DJStyle.deckB)
          .frame(maxHeight: .infinity, alignment: .top).djCard(tint: DJStyle.deckB)
      }
      .fixedSize(horizontal: false, vertical: true)
      if let w = model.walk {
        WalkPanel(
          walk: w, reportPath: model.walkReportPath, skip: { model.walkSkip() },
          back: { model.walkBack() }, stop: { model.stopWalk() }
        )
        .frame(height: 300)
      } else if model.showMap {
        DeviceMapView(
          maps: SurfaceProfile.all.map { ($0.name, $0.deviceMap()) },
          highlight: model.lastControl.flatMap {
            Date().timeIntervalSince($0.at) < 1.5 ? ($0.device, $0.group, $0.index) : nil
          },
          lights: model.deviceLights
        )
        .frame(height: 240)
      }
      if model.showPads, let pads = model.padLights["pads"] {
        PadGridView(
          pads: pads, tracks: model.padLights["track"] ?? [], scenes: model.padLights["scene"] ?? []
        ) { model.pressPad($0, $1) }
        .frame(width: 300, height: 300)
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
        Toggle("Map", isOn: Binding(get: { model.showMap }, set: { model.showMap = $0 }))
          .toggleStyle(.button)
        Menu("Check controls") {
          ForEach(model.devices, id: \.port) { d in
            Button(d.profile) { model.startWalk(device: d.profile) }
          }
        }
        .disabled(model.devices.isEmpty)
        Toggle("Pads", isOn: Binding(get: { model.showPads }, set: { model.setShowPads($0) }))
          .toggleStyle(.button)
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
          .disabled(model.lastSession == nil || model.isRecording)
      }
      VStack(alignment: .trailing, spacing: 2) {
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

struct DeckView: View {
  let name: String
  let model: AppModel
  let tint: Color
  @State private var importing = false
  @State private var generating = false

  var state: DeckState { model.decks[name] ?? .init() }

  var body: some View {
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
        VStack(spacing: DJStyle.s) {
          SectionLabel("Perform")
          NetPanel(name: name, state: state, model: model, tint: tint)
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
    .frame(width: 260)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
      if case .success(let url) = result { model.load(name, url: url) }
    }
    .sheet(isPresented: $generating) { GenerateSheet(name: name, model: model) }
  }

  /// The deck's letter, what it plays (the most important line on the deck) and the Load menu.
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
      Menu {
        Button("Audio file…") { importing = true }
        Button("Demo loop") { model.loadDemo(name) }
        Button("Generate…") { generating = true }
        Button("Share link from clipboard") {
          model.loadShare(name, NSPasteboard.general.string(forType: .string) ?? "")
        }
      } label: {
        Text("Load")
      }
      .menuStyle(.borderlessButton).fixedSize()
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

  /// Play / pause, cue (PFL) and the four hot cues, in one row.
  private var transport: some View {
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
      Toggle("Cue", isOn: Binding(get: { state.pfl }, set: { model.setPFL(name, $0) }))
        .toggleStyle(.button).help("Pre-fade listen: this deck in the headphones")
      Spacer(minLength: 0)
      HStack(spacing: DJStyle.xs) {
        ForEach(0..<4, id: \.self) { slot in
          Button("\(slot + 1)") { model.hotCue(name, slot) }
            .tint(state.cues.contains(slot) ? tint : nil)
            .buttonStyle(.borderedProminent).controlSize(.small)
            .contextMenu { Button("Clear cue \(slot + 1)") { model.clearCue(name, slot) } }
            .help(
              state.cues.contains(slot)
                ? "Jump to cue (right-click to clear)" : "Set cue at playhead")
        }
      }
    }
    .overlay(alignment: .trailing) {
      if state.scrubbing {
        Text("SCRATCH").font(.caption2.bold()).foregroundStyle(tint).offset(y: -26)
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
      }
    }
    .frame(width: 160)
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
      FlowRow(spacing: 4) {
        ForEach(state.roles, id: \.self) { r in
          Toggle(
            r,
            isOn: Binding(
              get: { state.rolesOn.contains(r) }, set: { _ in model.toggleRole(name, r) })
          )
          .toggleStyle(.button).controlSize(.small).tint(tint)
          .macroPulseGlow(state.macroPulse.level(of: r))
        }
      }
      FlowRow(spacing: 4) {
        ForEach(NetMacro.allCases, id: \.rawValue) { m in
          MacroButton(macro: m, running: state.macroPulse.isRunning(m)) { model.fire(name, m) }
        }
        Button("Panic") { model.panic(name) }.controlSize(.small).tint(.red)
      }
      HStack(spacing: 4) {
        ForEach(0..<4, id: \.self) { n in
          Button("Hit \(n + 1)") { model.stinger(name, n) }.controlSize(.small)
        }
        MasterMacroMenu(name: name, running: state.masterRunning, model: model)
        Spacer()
        Button("Sync") { model.sync(name) }.controlSize(.small)
        Button("Q: \(state.quantize)") { model.cycleQuantize(name) }.controlSize(.small)
        Button(state.nextReady ? "Next ▶︎" : (state.nextComposing ? "…" : "Next")) {
          model.skipToNext(name)
        }
        .controlSize(.small).disabled(!state.nextReady)
      }
    }
  }
}

/// The master chain's macros (beats' FX, Pitch and Feel groups) in one menu; its title shows a
/// dot while any of them is in effect, and the running ones are checked.
struct MasterMacroMenu: View {
  let name: String
  let running: Set<MasterMacro>
  let model: AppModel

  var body: some View {
    Menu {
      ForEach(["FX", "Pitch", "Feel"], id: \.self) { group in
        Section(group) {
          ForEach(MasterMacro.allCases.filter { $0.group == group }, id: \.rawValue) { m in
            Button {
              model.fire(name, m)
            } label: {
              if running.contains(m) {
                Label(m.label, systemImage: "checkmark")
              } else {
                Text(m.label)
              }
            }
          }
        }
      }
    } label: {
      Text(running.isEmpty ? "FX" : "FX ●")
    }
    .controlSize(.small).fixedSize()
  }
}

/// Wraps its children onto as many rows as the width needs.
struct FlowLayout: Layout {
  var spacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(in: proposal.width ?? 260, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = layout(in: bounds.width, subviews: subviews)
    for (sub, p) in zip(subviews, result.positions) {
      sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
    }
  }

  private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint])
  {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var maxX: CGFloat = 0
    var positions: [CGPoint] = []
    for sub in subviews {
      let size = sub.sizeThatFits(.unspecified)
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

struct FlowRow<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: Content
  var body: some View { FlowLayout(spacing: spacing) { content } }
}

struct GenerateSheet: View {
  let name: String
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var genre = "techno"
  @State private var structure = "standard"
  @State private var seed = String(Int.random(in: 1...999_999))
  @State private var cohesion = "v2"
  @State private var autoAdvance = false

  private var spec: TrackSpec {
    TrackSpec(
      genre: genre, seed: Double(seed) ?? 1, structure: structure == "loop" ? nil : structure,
      cohesion: cohesion)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Generate on deck \(name)").font(.title3.bold())
      Picker("Genre", selection: $genre) {
        ForEach(BeatsTables.shared.genreIDs, id: \.self) { Text($0).tag($0) }
      }
      Picker("Structure", selection: $structure) {
        ForEach(["loop", "minimal", "standard", "extended"], id: \.self) { Text($0).tag($0) }
      }
      Picker("Cohesion", selection: $cohesion) {
        Text("v2 (motif + harmony)").tag("v2")
        Text("v1 (legacy)").tag("v1")
      }
      HStack {
        TextField("Seed", text: $seed).frame(width: 120)
        Button("Roll") { seed = String(Int.random(in: 1...999_999)) }
      }
      Toggle("Start the next track when this one ends", isOn: $autoAdvance)
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Queue next") {
          model.queueNext(name, spec)
          model.setAutoAdvance(name, autoAdvance)
          dismiss()
        }
        Button("Generate now") {
          model.generate(name, spec)
          model.setAutoAdvance(name, autoAdvance)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
  }
}
