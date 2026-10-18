@preconcurrency import AVFoundation
import Testing

@testable import DJCore

// ClipRetune: a net take rendered again from its provenance. The decks here play synth voices
// on every tonal channel (instruments with no sampled category): sampled sounds with round
// robin differ between any two renders, synth voices never do.

private let bar = 96_000  // 120 bpm at 48 kHz

/// An offline engine run the way the app runs it (small blocks, takes serviced between them).
@MainActor
private final class RetuneRig {
  let dj: DJEngine
  let out: AVAudioPCMBuffer
  static let block = 512

  init() throws {
    dj = try DJEngine(decks: ["A"], offline: true, sampleRate: 48_000)
    out = AVAudioPCMBuffer(
      pcmFormat: dj.engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.block))!
  }

  func run(to frame: Int) throws {
    while dj.frame < frame {
      let n = min(Self.block, frame - dj.frame)
      guard try dj.engine.renderOffline(AVAudioFrameCount(n), to: out) == .success else { return }
      for d in dj.allDecks {
        d.turntable.drainRetired()
        d.service()
      }
      dj.serviceLoopTakes()
    }
  }

  func runUntilClip(limit: Int = 4 * 96_000) throws -> LoopClip? {
    let count = dj.clips.count
    let stop = dj.frame + limit
    while dj.clips.count == count, dj.frame < stop { try run(to: dj.frame + Self.block) }
    return dj.clips.count > count ? dj.clips.last : nil
  }
}

/// Techno at 120 with every tonal channel on a plain synth voice ("saw": no sampled category).
private func synthSpec() -> TrackSpec {
  let spec = TrackSpec(genre: "techno", seed: 1, extra: JSONObject([("bpm", .number(120))]))
  let project = spec.project()
  let drums = Set(project.drumChannels)
  let tonal = Set(
    project.nets.values.filter { $0.role != "control" }.map(\.track.channel)
  ).subtracting(drums)
  var source = DeckSourceDescriptor.net(spec)
  for ch in tonal.sorted() { source = source.withInstrument("saw", channel: ch) ?? source }
  guard case .net(let s) = source else { return spec }
  return s
}

private func samples(_ b: SampleBuffer) -> ([Float], [Float]) {
  (
    Array(UnsafeBufferPointer(start: b.left, count: b.length)),
    Array(UnsafeBufferPointer(start: b.right, count: b.length))
  )
}

/// The difference of `a` and `b` against `b`'s level, dB (both channels).
private func nullDB(_ a: SampleBuffer, _ b: SampleBuffer) -> Double {
  let (al, ar) = samples(a)
  let (bl, br) = samples(b)
  var diff = 0.0
  var ref = 0.0
  for i in 0..<min(al.count, bl.count) {
    let dl = Double(al[i] - bl[i])
    let dr = Double(ar[i] - br[i])
    diff += dl * dl + dr * dr
    ref += Double(bl[i]) * Double(bl[i]) + Double(br[i]) * Double(br[i])
  }
  return 10 * log10(max(diff, 1e-30) / max(ref, 1e-30))
}

@MainActor
struct LoopRetuneTests {
  /// A two-bar take from bar 1 of the synth-voiced deck.
  func netTake() async throws -> (LoopClip, [RoleVoice]) {
    let rig = try RetuneRig()
    let a = try #require(rig.dj["A"])
    await a.generate(synthSpec())
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    #expect(rig.dj.loopRecord("A", on: true))
    try rig.run(to: 2 * bar + bar / 2)
    #expect(rig.dj.loopRecord("A", on: false))
    let clip = try #require(try rig.runUntilClip())
    #expect(clip.startBeat == 4 && clip.beats == 8)
    return (clip, a.roleVoices)
  }

  @Test func theSameVoicesNullAgainstTheTake() async throws {
    let (clip, _) = try await netTake()
    let again = try ClipRetune.render(clip: clip, voices: [:], sampleRate: 48_000)
    #expect(again.buffer.length == clip.buffer.length, "exactly the take's beats")
    let db = nullDB(again.buffer, clip.buffer)
    print("retune null, same voices: \(db) dB")
    #expect(db <= -40)
    #expect(again.source == clip.originSource)
  }

  @Test func aCropRendersItsOwnBeats() async throws {
    let (clip, _) = try await netTake()
    // the crop as `cropClip` makes it: beats 2..<6 of the take
    let perBeat = clip.buffer.length / clip.beats
    let (l, r) = samples(clip.buffer)
    let buffer = SampleBuffer(
      left: Array(l[(2 * perBeat)..<(6 * perBeat)]),
      right: Array(r[(2 * perBeat)..<(6 * perBeat)]), sampleRate: 48_000)
    let crop = LoopClip(
      id: buffer.contentID, title: clip.title, source: clip.source, beats: 4, bpm: clip.bpm,
      startBeat: clip.startBeat + 2, buffer: buffer,
      waveform: WaveformOverview(buffer: buffer, columns: 40),
      provenance: LoopProvenance.crop(clip, from: 2, to: 6))
    let again = try ClipRetune.render(clip: crop, voices: [:], sampleRate: 48_000)
    #expect(again.buffer.length == crop.buffer.length)
    #expect(nullDB(again.buffer, crop.buffer) <= -40)
  }

  @Test func anotherInstrumentChangesOnlyItsPart() async throws {
    let (clip, roles) = try await netTake()
    let part = try #require(
      roles.first { !$0.role.contains(" · ") && $0.instrument == "saw" })
    let voices = [part.channel: "square"]
    let changed = try ClipRetune.render(clip: clip, voices: voices, sampleRate: 48_000)
    let db = nullDB(changed.buffer, clip.buffer)
    print("retune null, \(part.role) on square: \(db) dB")
    #expect(db > -30, "the part sounds different")
    // with that part left out of both, the rest of the mix is the take's
    let rest = try ClipRetune.render(
      clip: clip, voices: voices, sampleRate: 48_000, rolesOff: [part.role])
    let restAsTaken = try ClipRetune.render(
      clip: clip, voices: [:], sampleRate: 48_000, rolesOff: [part.role])
    let restDB = nullDB(rest.buffer, restAsTaken.buffer)
    print("retune null without \(part.role): \(restDB) dB")
    #expect(restDB <= -40)
    // the override is the share's own `tracks` entry
    #expect(
      changed.source == clip.originSource?.withInstrument("square", channel: part.channel))
  }

  @Test func sampleTakesAreRefused() throws {
    let rig = try RetuneRig()
    let a = try #require(rig.dj["A"])
    a.loadDemo()
    a.setPlaying(true)
    try rig.dj.start()
    defer { rig.dj.stop() }
    try rig.run(to: bar + bar / 3)
    #expect(rig.dj.loopRecord("A", on: true))
    try rig.run(to: 2 * bar + bar / 2)
    #expect(rig.dj.loopRecord("A", on: false))
    let clip = try #require(try rig.runUntilClip())
    #expect(throws: ClipRetune.Refusal.notANet) {
      try ClipRetune.render(clip: clip, voices: [:], sampleRate: 48_000)
    }
    // and so is a crop of one
    let crop = LoopClip(
      id: "crop", title: "crop", source: "A", beats: 4, bpm: clip.bpm,
      startBeat: clip.startBeat, buffer: clip.buffer, waveform: clip.waveform,
      provenance: LoopProvenance.crop(clip, from: 0, to: 4))
    #expect(throws: ClipRetune.Refusal.notANet) {
      try ClipRetune.render(clip: crop, voices: [:], sampleRate: 48_000)
    }
  }

  @Test func sequencesMacrosAndBareClipsAreRefused() async throws {
    let (clip, _) = try await netTake()
    let seq = LoopClip(
      id: "seq", title: "seq", source: "A", beats: clip.beats, bpm: clip.bpm,
      startBeat: clip.startBeat, buffer: clip.buffer, waveform: clip.waveform,
      steps: [SequenceStep(clipID: clip.id)],
      provenance: LoopProvenance.sequence([(SequenceStep(clipID: clip.id), clip)]))
    #expect(throws: ClipRetune.Refusal.sequence) {
      try ClipRetune.render(clip: seq, voices: [:], sampleRate: 48_000)
    }
    // a take with a macro running
    var o = try #require(clip.provenance?.object)
    o["macros"] = .array([.string("beatRepeat")])
    let macro = LoopClip(
      id: "m", title: "m", source: "A", beats: clip.beats, bpm: clip.bpm,
      startBeat: clip.startBeat, buffer: clip.buffer, waveform: clip.waveform,
      provenance: .object(o))
    #expect(throws: ClipRetune.Refusal.macros(["beatRepeat"])) {
      try ClipRetune.render(clip: macro, voices: [:], sampleRate: 48_000)
    }
    let bare = LoopClip(
      id: "b", title: "b", source: "A", beats: clip.beats, bpm: clip.bpm,
      startBeat: clip.startBeat, buffer: clip.buffer, waveform: clip.waveform)
    #expect(throws: ClipRetune.Refusal.noProvenance) {
      try ClipRetune.render(clip: bare, voices: [:], sampleRate: 48_000)
    }
  }
}
