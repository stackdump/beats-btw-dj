// djctl — CoreMIDI hardware checks from Swift.
//
//   djctl ports            list MIDI sources and destinations
//   djctl monitor [match]  print messages (and decoded jog events) until Ctrl-C
import DJCore
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let profile = JogProfile.inpulse200MK3

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

switch args.first {
case "ports":
  print("sources:")
  for p in MIDIPort.sources() {
    print("  \(p.name)\(profile.matches(portName: p.name) ? "   ← \(profile.name)" : "")")
  }
  print("destinations:")
  for p in MIDIPort.destinations() { print("  \(p.name)") }

case "monitor":
  let match = args.dropFirst().joined(separator: " ").lowercased()
  let t0 = ProcessInfo.processInfo.systemUptime
  let midi = try MIDIIn { m in
    let decoded = profile.parse(m.bytes).map { "  \($0)" } ?? ""
    let port = m.port.padding(toLength: 28, withPad: " ", startingAt: 0)
    print(String(format: "%10.3f", (m.time - t0) * 1000) + "  \(port)  \(hex(m.bytes))\(decoded)")
  }
  let ports = try midi.connect { match.isEmpty || $0.name.lowercased().contains(match) }
  if ports.isEmpty {
    FileHandle.standardError.write(
      "no MIDI source matches \"\(match)\" (try: djctl ports)\n".data(using: .utf8)!)
    exit(1)
  }
  for p in ports { FileHandle.standardError.write("listening: \(p.name)\n".data(using: .utf8)!) }
  // Handle Ctrl-C on a dispatch queue, not in a raw signal handler.
  signal(SIGINT, SIG_IGN)
  let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  sigint.setEventHandler { exit(0) }
  sigint.resume()
  withExtendedLifetime((midi, sigint)) { dispatchMain() }

default:
  FileHandle.standardError.write("usage: djctl ports | monitor [match]\n".data(using: .utf8)!)
  exit(2)
}
