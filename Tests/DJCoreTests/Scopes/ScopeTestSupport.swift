@preconcurrency import AVFoundation

@testable import DJCore

// Shared by every scope test (mode agents: reuse this).
//
//   let rig = try ScopeRig()                       // offline engine, deck A plays a techno net
//   let feed = rig.hub.feed(.deck("A"))
//   feed.acquire()                                 // BEFORE rendering: the taps are off until then
//   rig.render(frames: 22_050)                     // 1 s of engine time
//   rig.hub.pump()
//   ... assert on feed.history / feed.fireLog / feed.lanes / feed.anchors ...
//   rig.stop()
//
// Decks listed in `net` play a composed song (seed `seed + index`), decks in `samples` the demo
// loop. Every net deck runs at `tempo` BPM (300 by default: a step is 50 ms, a bar 0.8 s, so a
// few seconds of rendering cover many bars).

func scopeProject(_ genre: String, seed: Double = 42, structure: String = "loop") -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

@MainActor
final class ScopeRig {
  static let rate = 22_050.0

  let dj: DJEngine
  let hub: ScopeHub
  /// The measured readers of this rig's hub (private, so tests do not share reads).
  let readers = MeasuredReaderStore()
  private let buffer: AVAudioPCMBuffer
  /// Frames per render cycle (the engine's manual-rendering block).
  let block: Int

  init(
    net: [String] = ["A"], samples: [String] = [], genre: String = "techno", seed: Double = 42,
    structure: String = "loop", tempo: Double = 300, play: Bool = true, block: Int = 512,
    start: Bool = true
  ) throws {
    let names = (net + samples).sorted()
    dj = try DJEngine(decks: names, offline: true, sampleRate: Self.rate)
    self.block = block
    buffer = makeEngineRenderBuffer(dj, frames: block)
    for (i, name) in net.sorted().enumerated() {
      let d = dj[name]!
      d.loadNet(scopeProject(genre, seed: seed + Double(i), structure: structure))
      d.wave.setTempo(tempo)
      if play { d.setPlaying(true) }
    }
    for name in samples {
      let d = dj[name]!
      d.loadDemo()
      if play { d.setPlaying(true) }
    }
    hub = ScopeHub(engine: dj, readers: readers)
    if start { try dj.start() }
  }

  func stop() { dj.stop() }

  /// Put a hand-made song on a deck and run it at `tempo` (as the rig's own decks do).
  func load(_ project: Project, on name: String = "A", tempo: Double = 300, play: Bool = true) {
    let d = dj[name]!
    d.loadNet(project)
    d.wave.setTempo(tempo)
    if play { d.setPlaying(true) }
  }

  /// Render at least `frames` frames (whole blocks).
  func render(frames: Int) {
    pullEngine(dj, buffer, cycles: max(1, (frames + block - 1) / block), frames: block)
  }

  /// Render `seconds` of audio.
  func render(seconds: Double) { render(frames: Int(seconds * Self.rate)) }
}

/// `project` with every MIDI binding rewritten by `edit`.
func rewritingBindings(_ project: Project, _ edit: (inout MidiBinding) -> Void) -> Project {
  var p = project
  for (id, net) in p.nets.pairs {
    var n = net
    for (t, binding) in n.bindings.pairs {
      var b = binding
      edit(&b)
      n.bindings[t] = b
    }
    p.nets[id] = n
  }
  return p
}

/// Render cycles driven by hand the way the engine runs them: the frame clock counts first, then
/// each deck renders its block. The output unit is never pulled, so the master tap stays unfed
/// (a master feed then has only the decks' bound to go on), and a test can stop a cycle between
/// two decks, which an engine pull never does.
@MainActor
final class ManualCycles {
  let dj: DJEngine
  let frames: Int
  private var left: [Float]
  private var right: [Float]

  init(_ dj: DJEngine, frames: Int = 512) {
    self.dj = dj
    self.frames = frames
    left = [Float](repeating: 0, count: frames)
    right = [Float](repeating: 0, count: frames)
  }

  /// The clock counts a cycle.
  func tickClock() { dj.frameClock.frames.add(frames, ordering: .relaxed) }

  /// One deck renders its block of the current cycle.
  func render(_ name: String) {
    let d = dj[name]!
    let n = frames
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        d.renderBlock(frames: n, left: l.baseAddress!, right: r.baseAddress!)
      }
    }
  }

  /// A whole cycle: clock, then every deck in name order.
  func cycle() {
    tickClock()
    for name in dj.decks.keys.sorted() { render(name) }
  }
}
