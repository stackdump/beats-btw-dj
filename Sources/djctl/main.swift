// djctl — CoreMIDI and audio checks from Swift.
//
//   djctl ports                       list MIDI sources/destinations and which profile claims each
//   djctl monitor [match]             print messages, decoded per device profile, until Ctrl-C
//   djctl play [fileA] [fileB] [--seconds N] [--volume V]
//                                     two decks (demo loop where no file), every supported
//                                     controller connected; Ctrl-C to stop
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

/// `--name value` as a number; the pair is removed from `positional`.
var positional = Array(args.dropFirst())
@MainActor func option(_ name: String) -> Double? {
  guard let i = positional.firstIndex(of: name), positional.indices.contains(i + 1) else {
    return nil
  }
  defer { positional.removeSubrange(i...(i + 1)) }
  return Double(positional[i + 1])
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

default:
  stderr("usage: djctl ports | monitor [match] | play [fileA] [fileB] [--seconds N] [--volume 0-1]")
  exit(2)
}
