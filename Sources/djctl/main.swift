// djctl — CoreMIDI and audio checks from Swift.
//
//   djctl ports                       list MIDI sources/destinations and which profile claims each
//   djctl monitor [match]             print messages, decoded per device profile, until Ctrl-C
//   djctl play [fileA] [fileB] [--seconds N] [--volume V]
//                                     two decks (demo loop where no file), every supported
//                                     controller connected; Ctrl-C to stop
//   djctl render <genre> <seed> <out.wav> [--structure S] [--cohesion v1|v2]
//                [--options JSON] [--mute r,…] [--solo r,…] [--seconds N] [--float32]
//                                     compose a track and render it offline (no app)
import DJCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered, so redirected monitor logs fill live
let args = Array(CommandLine.arguments.dropFirst())
let jog = JogProfile.inpulse200MK3
let surfaces = SurfaceProfile.all

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func profileName(_ port: String) -> String? {
  jog.matches(portName: port) ? jog.name : surfaces.first { $0.matches(portName: port) }?.name
}

/// Monitor decoding: the same decoder + layout lookup the hub uses, against
/// a silent offline engine (nothing is played).
var monitorSurfaces: [String: SurfaceController] = [:]
let monitorEngine = try! DJEngine(offline: true)

@MainActor func decode(_ m: MIDIMessage) -> String {
  if jog.matches(portName: m.port), let e = jog.parse(m.bytes) { return "\(e)" }
  guard let p = surfaces.first(where: { $0.matches(portName: m.port) }) else { return "" }
  let s = monitorSurfaces[m.port] ?? SurfaceController(profile: p, engine: monitorEngine)
  monitorSurfaces[m.port] = s
  guard let e = s.decode(m.bytes) else { return "(undecoded)" }
  let control =
    "\(e.group)[\(e.index)]" + (e.name.map { " \($0)" } ?? "")
    + (e.delta != 0 ? " Δ\(e.delta)" : String(format: "=%.3f", e.value))
  // Track shift so layered bindings show correctly.
  if e.group == "shift" || s.binding(for: e)?.action == .shift { s.handle(e) }
  switch s.outcome(for: e) {
  case .bound(let b), .pickup(let b): return "\(control) → \(b.action.rawValue) \(b.deck ?? "")"
  case .unbound(let reason): return "\(control) (unbound: \(reason))"
  case .unmapped: return "\(control) (UNMAPPED)"
  }
}

/// Handle Ctrl-C on the main queue, not in a raw signal handler.
func onInterrupt(_ body: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
  signal(SIGINT, SIG_IGN)
  let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  s.setEventHandler(handler: body)
  s.resume()
  return s
}

/// `--store DIR` (default: the app's session directory); the pair is removed from `positional`.
@MainActor func storeOption() -> SessionStore {
  guard let i = positional.firstIndex(of: "--store"), positional.indices.contains(i + 1) else {
    return SessionStore()
  }
  defer { positional.removeSubrange(i...(i + 1)) }
  return SessionStore(directory: URL(fileURLWithPath: positional[i + 1], isDirectory: true))
}

/// `--name value` as a number; the pair is removed from `positional`.
var positional = Array(args.dropFirst())
@MainActor func option(_ name: String) -> Double? {
  guard let i = positional.firstIndex(of: name), positional.indices.contains(i + 1) else {
    return nil
  }
  defer { positional.removeSubrange(i...(i + 1)) }
  return Double(positional[i + 1])
}

/// `--name value` as a string; the pair is removed from `positional`.
@MainActor func stringOption(_ name: String) -> String? {
  guard let i = positional.firstIndex(of: name), positional.indices.contains(i + 1) else {
    return nil
  }
  defer { positional.removeSubrange(i...(i + 1)) }
  return positional[i + 1]
}

/// `--mute a,b` / `--solo a,b` (roles, mixer groups or net ids) as a render filter.
@MainActor func roleFilterOption() -> RoleFilter? {
  func list(_ n: String) -> Set<String>? {
    stringOption(n).map { Set($0.split(separator: ",").map(String.init)) }
  }
  let f = RoleFilter(mute: list("--mute") ?? [], solo: list("--solo"))
  return f.isEmpty ? nil : f
}

@MainActor func writeRender(_ session: Session, filter: RoleFilter?, to path: String, float32: Bool)
  throws
{
  let audio = try SessionPlayer(session: session, roleFilter: filter).render()
  try WAV.encode(audio, float32: float32).write(to: URL(fileURLWithPath: path), options: .atomic)
  let (peak, rms) = audio.levels
  print(
    "wrote \(path)  \(String(format: "%.2f", Double(audio.frames) / audio.sampleRate)) s  "
      + "peak \(String(format: "%.2f", peak)) dBFS  rms \(String(format: "%.2f", rms)) dBFS")
}

switch args.first {
case "ports":
  print("sources:")
  for p in MIDIPort.sources() {
    print("  \(p.name)" + (profileName(p.name).map { "   ← \($0)" } ?? ""))
  }
  print("destinations:")
  for p in MIDIPort.destinations() { print("  \(p.name)") }

case "monitor":
  let match = positional.joined(separator: " ").lowercased()
  let t0 = ProcessInfo.processInfo.systemUptime
  let midi = try MIDIIn { m in
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        let port = m.port.padding(toLength: 28, withPad: " ", startingAt: 0)
        let d = decode(m)
        print(
          String(format: "%10.3f", (m.time - t0) * 1000) + "  \(port)  \(hex(m.bytes))"
            + (d.isEmpty ? "" : "  \(d)"))
      }
    }
  }
  let ports = try midi.connect { match.isEmpty || $0.name.lowercased().contains(match) }
  if ports.isEmpty {
    stderr("no MIDI source matches \"\(match)\" (try: djctl ports)")
    exit(1)
  }
  for p in ports { stderr("listening: \(p.name)" + (profileName(p.name).map { " (\($0))" } ?? "")) }
  let sigint = onInterrupt { exit(0) }
  withExtendedLifetime((midi, sigint)) { dispatchMain() }

case "audio":
  // Output devices CoreAudio offers, and whether one is the Inpulse's own interface.
  for d in AudioDevices.outputs() {
    print("\(d.outputChannels) ch  \(d.name)  [\(d.uid)]")
  }
  if let i = AudioDevices.inpulse() {
    print("Inpulse interface: \(i.name) with \(i.outputChannels) output channels")
  } else {
    print("no Inpulse audio interface found")
  }

case "cue-test":
  // Route master -> outputs 1/2 and the headphone cue -> 3/4 of the Inpulse's interface and
  // play the demo loop quietly for a few seconds. Prints what the engine ended up with.
  guard let device = AudioDevices.inpulse() else {
    stderr("no Inpulse audio interface")
    exit(1)
  }
  let seconds = option("--seconds") ?? 3
  let dj = try DJEngine(decks: ["A"])
  dj["A"]!.loadDemo()
  dj["A"]!.pfl = true
  dj.master = 0.15
  dj.headphoneLevel = 0.25
  Task { @MainActor in
    do {
      try await dj.enableCueOutput(device: device)
      try dj.start()
      dj["A"]!.setPlaying(true)
      var hub: ControllerHub?
      if CommandLine.arguments.contains("--live") {
        // Controller input drives the engine; print each control and the value it produced.
        let h = ControllerHub(engine: dj)
        h.onControl = { _, group, index in
          DispatchQueue.main.async {
            stderr(
              "control \(group)[\(index)] · master \(String(format: "%.2f", dj.master))"
                + " · headphoneLevel \(String(format: "%.2f", dj.headphoneLevel))"
                + " · headphoneMix \(String(format: "%.2f", dj.headphoneMix))")
          }
        }
        try h.start()
        hub = h
        stderr("live: move the master and headphone faders now")
      }
      defer { hub?.stop() }
      let out = dj.engine.outputNode.outputFormat(forBus: 0)
      stderr(
        "routed: \(device.name) · output format \(out.channelCount) ch @ \(Int(out.sampleRate)) Hz")
      try await Task.sleep(for: .seconds(seconds))
      stderr(
        "engine running: \(dj.engine.isRunning) · deck A at \(String(format: "%.2f", dj["A"]!.positionSeconds)) s · frames rendered \(dj.frame)"
      )
      dj.stop()
      exit(dj.frame > 0 ? 0 : 1)
    } catch {
      stderr("failed: \(error)")
      exit(1)
    }
  }
  RunLoop.main.run()

case "demo-session":
  // Write a tiny hand-built session (no audio) to --store DIR, to try publishing on.
  func dirOption() -> URL? {
    guard let i = positional.firstIndex(of: "--store"), positional.indices.contains(i + 1) else {
      return nil
    }
    defer { positional.removeSubrange(i...(i + 1)) }
    return URL(fileURLWithPath: positional[i + 1], isDirectory: true)
  }
  guard let dir = dirOption() else {
    stderr("usage: djctl demo-session --store DIR")
    exit(2)
  }
  let demo = Session(
    sampleRate: 44100, frames: 44100 * 4,
    decks: ["A": .net(TrackSpec(genre: "techno", seed: 42, structure: "standard"))],
    params: ["A": DeckParams()], crossfader: 0.5, master: 0.8,
    events: [SessionEvent(frame: 4410, kind: .action(.play(deck: "A", on: true)))])
  let saved = try SessionStore(directory: dir).save(demo)
  print(saved.cid)

case "sessions":
  let store = storeOption()
  for cid in store.list() {
    if let s = try? store.load(cid: cid) {
      print(
        "\(cid)  \(String(format: "%.0f", s.duration)) s  \(s.decks.count) decks  \(s.events.count) events"
      )
    }
  }

case "export":
  // djctl export <cid> <out.wav> [--float32]: offline render of a stored set (what the app's
  // Export does), e.g. to feed `djctl publish --audio`.
  // --mute / --solo leave roles out of the render (stems); the stored set is unchanged.
  let store = storeOption()
  let filter = roleFilterOption()
  let float32 = positional.contains("--float32")
  let args = positional.filter { $0 != "--float32" }
  guard args.count == 2 else {
    stderr("usage: djctl export <cid> <out.wav> [--float32] [--mute r,…] [--solo r,…]")
    exit(2)
  }
  do {
    try writeRender(try store.load(cid: args[0]), filter: filter, to: args[1], float32: float32)
  } catch {
    stderr("export failed: \(error)")
    exit(1)
  }

case "bounce":
  // djctl bounce <genre> <seed> <out.wav> [--structure S] [--cohesion v1|v2] [--options JSON]
  //              [--mute r,…] [--solo r,…] [--seconds N] [--float32]
  // Composes the spec (with `generate`'s options) and renders it offline on one deck, from
  // the first frame to the end of the song; prints the share CID the deck would carry.
  let structure = stringOption("--structure")
  let cohesion = stringOption("--cohesion") ?? "v2"
  let optionsText = stringOption("--options")
  let seconds = option("--seconds")
  let filter = roleFilterOption()
  let float32 = positional.contains("--float32")
  let args = positional.filter { $0 != "--float32" }
  guard args.count == 3, let seed = Double(args[1]) else {
    stderr(
      "usage: djctl bounce <genre> <seed> <out.wav> [--structure S] [--cohesion v1|v2] "
        + "[--options JSON] [--mute r,…] [--solo r,…] [--seconds N] [--float32]")
    exit(2)
  }
  do {
    guard BeatsTables.shared.genres[args[0]] != nil else {
      throw ComposeOptions.Invalid(description: "unknown genre \(args[0])")
    }
    var spec = TrackSpec(genre: args[0], seed: seed, structure: structure, cohesion: cohesion)
    if let optionsText {
      guard let o = try JSONValue.parse(optionsText).object else {
        throw ComposeOptions.Invalid(description: "--options must be a JSON object")
      }
      spec = try ComposeOptions.apply(o, to: spec)
    }
    guard let session = Session.playing(spec, seconds: seconds) else {
      throw ComposeOptions.Invalid(description: "a loop (no --structure) needs --seconds")
    }
    print("share \(BeatsCID.shareCID(spec.payload))  \(spec.payload.canonicalJS)")
    try writeRender(session, filter: filter, to: args[2], float32: float32)
  } catch {
    stderr("render failed: \(error)")
    exit(1)
  }

case "publish":
  // djctl publish <cid> [--audio FILE.wav] [--title T] [--draft] [--host H] [--blobs DIR]
  //                     [--no-reload] [--mirror] [--dry-run]
  // Stages the set into the CDN master's blob tree on valoper (as the render farm does) and
  // reloads its index. Only --mirror makes it public (runs mirror-push.sh -> pflow.dev), and
  // then it polls the public URL until the blob answers (up to ~3 min).
  func flag(_ n: String) -> Bool {
    guard let i = positional.firstIndex(of: n) else { return false }
    positional.remove(at: i)
    return true
  }
  func value(_ n: String) -> String? {
    guard let i = positional.firstIndex(of: n), positional.indices.contains(i + 1) else {
      return nil
    }
    defer { positional.removeSubrange(i...(i + 1)) }
    return positional[i + 1]
  }
  let store = storeOption()
  let dry = flag("--dry-run")
  let mirror = flag("--mirror")
  let draft = flag("--draft")
  let noReload = flag("--no-reload")
  let audio = value("--audio")
  let title = value("--title")
  let host = value("--host") ?? "valoper.local"
  let blobs = value("--blobs")
  guard let cid = positional.first else {
    stderr(
      "usage: djctl publish <cid> [--audio f.wav] [--title T] [--draft] [--host H] [--blobs DIR] [--no-reload] [--mirror] [--dry-run]   (djctl sessions lists cids)"
    )
    exit(2)
  }
  do {
    let session = try store.load(cid: cid)
    let wav = try audio.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let bundle = try SessionBundle(
      session: session, title: title, audioWAV: wav, renderedAt: stamp, draft: draft)
    for f in bundle.files { print("  \(f.name)  \(f.data.count) bytes") }
    print("public URL (once mirrored): \(bundle.publicURL)")
    if dry { exit(0) }
    var t = SSHTransport(host: host)
    if let blobs { t.blobsDir = blobs }
    if noReload { t.reloadURL = "http://127.0.0.1:1/none" }
    let r = try publishSession(bundle, via: t, mirror: mirror) { step in
      switch step {
      case .staging(let file, let i, let n): stderr("  uploading \(file) (\(i)/\(n))")
      case .reloading: stderr("  reloading the CDN index")
      case .mirroring: stderr("  starting mirror-push")
      case .done: break
      }
    }
    print(
      "staged on \(host) · index reload \(noReload ? "skipped" : (r.reloaded ? "ok" : "FAILED"))")
    if mirror {
      // mirror-push runs in the background on valoper; wait for the blob to appear publicly.
      stderr("  waiting for \(r.url) …")
      let live = PublicProbe(attempts: 60, interval: 3).wait(for: bundle)
      print(
        live
          ? "public: \(r.url)"
          : "mirror-push started, not visible yet (a large WAV can take a while): \(r.url)")
    } else {
      print("not public yet: re-run with --mirror")
    }
  } catch {
    stderr("publish failed: \(error)")
    exit(1)
  }

case "play":
  let seconds = option("--seconds")
  let volume = option("--volume")
  let dj = try DJEngine()
  for (i, name) in ["A", "B"].enumerated() {
    let deck = dj[name]!
    if positional.indices.contains(i) {
      try deck.load(contentsOf: URL(fileURLWithPath: positional[i]))
    } else {
      deck.loadDemo()
    }
  }
  dj.master = volume ?? 0.8
  try dj.start()
  dj["A"]!.setPlaying(true)

  let hub = ControllerHub(engine: dj)
  hub.onMessage = { m, d in if !d.isEmpty { print("\(m.port): \(d)") } }
  try hub.start()
  stderr("engine \(Int(dj.sampleRate)) Hz · A: \(dj["A"]!.title) (playing) · B: \(dj["B"]!.title)")
  stderr(
    hub.devices.isEmpty
      ? "no supported controller connected"
      : hub.devices.map { "controller: \($0.profile) [\($0.port)]" }.joined(separator: "\n"))

  let finish: @MainActor () -> Void = {
    hub.stop()
    stderr(
      String(
        format: "stopped · A at %.2f s · B at %.2f s", dj["A"]!.positionSeconds,
        dj["B"]!.positionSeconds))
    dj.stop()
    exit(0)
  }
  // Both fire on the main queue.
  let sigint = onInterrupt { MainActor.assumeIsolated { finish() } }
  if let seconds { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() } }
  withExtendedLifetime((hub, sigint)) { RunLoop.main.run() }

case "mcp":
  // MCP over stdio for the running DJApp: each tool call is one request on its control
  // socket, so the app can be started and restarted under a long-lived MCP session.
  let bridge = MCPBridge { method, params in
    try ControlClient().request(method, params)
  }
  while let line = readLine() {
    guard let reply = bridge.handle(line) else { continue }
    print(reply)
    fflush(stdout)
  }

case "ctl":
  // djctl ctl <method> ['{"json":"params"}'] — one raw control request, for debugging.
  guard args.count >= 2 else {
    stderr(
      "usage: djctl ctl state|catalog|perform|generate|loadFile|loadShare|pad|record ['{params}']")
    exit(2)
  }
  do {
    let params = args.count > 2 ? try JSONValue.parse(args[2]) : .object(JSONObject())
    print(try ControlClient().request(args[1], params).jsStringified)
  } catch {
    stderr("\(error)")
    exit(1)
  }

case "render":
  // djctl render <genre> <seed> [--structure S|loop] [--seconds N] [--out f.wav] [--notes f.txt] [--synth] [--room] [--balance]
  // Composes the track as a deck would, renders it offline (nothing on the speakers) and
  // prints its musicality report and audio metrics as JSON. --synth skips sampled instruments;
  // --room renders it a second time without the reverb and reports the room's return level;
  // --balance solos each part (`MixBalance`) and reports its level against the mix.
  let seconds = option("--seconds") ?? 90
  var structure: String? = "standard"
  var out: String?
  if let i = positional.firstIndex(of: "--structure"), positional.indices.contains(i + 1) {
    structure = positional[i + 1] == "loop" ? nil : positional[i + 1]
    positional.removeSubrange(i...(i + 1))
  }
  if let i = positional.firstIndex(of: "--out"), positional.indices.contains(i + 1) {
    out = positional[i + 1]
    positional.removeSubrange(i...(i + 1))
  }
  var notesOut: String?
  if let i = positional.firstIndex(of: "--notes"), positional.indices.contains(i + 1) {
    notesOut = positional[i + 1]
    positional.removeSubrange(i...(i + 1))
  }
  // --fixes key,timing,… (or none / all): which DJMusicality fixes to apply; default all.
  var fixes = DJMusicality.Fixes.all
  if let i = positional.firstIndex(of: "--fixes"), positional.indices.contains(i + 1) {
    fixes = []
    for n in positional[i + 1].split(separator: ",") {
      guard let f = n == "all" ? .all : DJMusicality.Fixes.named[String(n)] else {
        stderr(
          "unknown fix \(n); one of: all, none, "
            + DJMusicality.Fixes.named.keys.sorted().joined(separator: ", "))
        exit(2)
      }
      fixes.formUnion(f)
    }
    positional.removeSubrange(i...(i + 1))
  }
  let synth = positional.contains("--synth")
  let room = positional.contains("--room")
  let balance = positional.contains("--balance")
  positional.removeAll { $0 == "--synth" || $0 == "--room" || $0 == "--balance" }
  guard positional.count >= 2, let seed = Double(positional[1]) else {
    stderr(
      "usage: djctl render <genre> <seed> [--structure S|loop] [--seconds N] [--out f.wav] [--synth]"
    )
    exit(2)
  }
  let spec = TrackSpec(genre: positional[0], seed: seed, structure: structure)
  let sr = 48_000.0
  var deckOpts = WaveOptions.extended
  deckOpts.musicality = fixes
  let source = WaveDeckSource(sampleRate: sr, opts: deckOpts)
  var trackOpts = WaveOptions.extended(samplers: synth ? nil : source.samplers)
  trackOpts.musicality = fixes
  let track = PreparedTrack(spec: spec, sampleRate: sr, opts: trackOpts)
  let (log, controls) = NoteLog.captureAll(track.played)
  let report = MusicalityReport(project: track.project, log: log, controls: controls)
  if let notesOut {
    // one note per line: tick net group note velocity channel steps
    let lines = log.map {
      "\($0.tick) \($0.net) \($0.group) \($0.note) \($0.velocity) \($0.channel) \($0.steps)"
    }
    let changes = controls.map { "\($0.tick) \($0.net) <\($0.action)> \($0.target) 0 0 0" }
    try ((lines + changes).joined(separator: "\n") + "\n").write(
      toFile: notesOut, atomically: true, encoding: .utf8)
  }
  let render = OfflineRender(track: track, source: source, seconds: seconds)
  if let out { try render.wav().write(to: URL(fileURLWithPath: out)) }
  var audio = render.metrics.dictionary
  let levels = render.sectionLevels(track.played)
  audio["sections"] = levels.map { ["name": $0.name, "rmsDB": round3($0.db)] }
  if let lo = levels.map(\.db).min(), let hi = levels.map(\.db).max() {
    audio["sectionSpreadDB"] = round3(hi - lo)
  }
  let dips = render.preDropDips(track.played)
  if !dips.isEmpty { audio["preDropDipDB"] = round3(dips.reduce(0, +) / Double(dips.count)) }
  // --room: render it again without `.space`; what the room adds, against the dry mix
  if room && fixes.contains(.space) {
    var dryDeck = deckOpts
    dryDeck.musicality.remove(.space)
    let drySource = WaveDeckSource(sampleRate: sr, opts: dryDeck)
    var dryOpts = WaveOptions.extended(samplers: synth ? nil : drySource.samplers)
    dryOpts.musicality = fixes.subtracting(.space)
    let dry = OfflineRender(
      track: PreparedTrack(spec: spec, sampleRate: sr, opts: dryOpts), source: drySource,
      seconds: seconds)
    var wet = 0.0
    var base = 0.0
    for i in 0..<min(dry.left.count, render.left.count) {
      let dl = Double(render.left[i] - dry.left[i])
      let dr = Double(render.right[i] - dry.right[i])
      wet += dl * dl + dr * dr
      base += Double(dry.left[i] * dry.left[i] + dry.right[i] * dry.right[i])
    }
    if wet > 0 && base > 0 { audio["roomReturnDB"] = round3(10 * log10(wet / base)) }
  }
  // --balance: each part soloed against the whole mix, K-weighted (synth voices)
  if balance {
    var o = WaveOptions.extended
    o.musicality = fixes
    let levels = MixBalance.measure(track.played, opts: o.forGenre(spec.genre))
    audio["balanceDB"] = levels.mapValues(round3)
    if let e = MixBalance.error(levels) { audio["balanceErrorDB"] = round3(e) }
  }
  let doc: [String: Any] = [
    "genre": spec.genre, "seed": seed, "structure": structure ?? "loop",
    "seconds": Double(render.left.count) / sr, "musicality": report.dictionary,
    "audio": audio, "tempo": track.played.tempo,
    "sectionSteps": track.played.structure.map(\.steps),
  ]
  let data = try JSONSerialization.data(
    withJSONObject: doc, options: [.sortedKeys, .prettyPrinted])
  print(String(decoding: data, as: UTF8.self))

default:
  stderr(
    "usage: djctl ports | audio | sessions | export <cid> <out.wav> | render <genre> <seed> | bounce <genre> <seed> <out.wav> | publish <cid> | cue-test [--seconds N] | monitor [match] | play [fileA] [fileB] [--seconds N] [--volume 0-1] | mcp | ctl <method> [json]"
  )
  exit(2)
}
