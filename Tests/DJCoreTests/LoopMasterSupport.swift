import Foundation

@testable import DJCore

// Helpers for LoopMasterFxTests (Foundation kept out of the Testing files): a recorded set with
// the loops' master FX, through a session recorder and the journal at once.

struct LoopMasterSet {
  let session: Session
  let audio: RenderedAudio
  let journal: Journal.Contents
}

/// The demo loop on deck A (120 bpm, 22.05 kHz), a one-bar take looping on the loop channel, then
/// `script(bar, block)` (bars of 128-frame blocks since the start) poking the loops' master FX.
/// Recorded by a `SessionRecorder` and a `Journal` side by side.
@MainActor
func loopMasterSet(
  blocks: Int, midi: ((_ router: ControllerRouter, _ bar: Int, _ block: Int) -> Void)? = nil,
  _ script: (_ dj: DJEngine, _ bar: Int, _ block: Int) -> Void
) throws -> LoopMasterSet {
  let rate = 22_050.0
  let dir = fxTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
  dj.deterministic = true
  try dj.start()
  defer { dj.stop() }
  let journal = try Journal(
    engine: dj, directory: dir, started: Date(timeIntervalSince1970: 1_760_000_000)
  ) { JournalStoreState() }
  let recorder = try SessionRecorder.start(on: dj)
  let router = ControllerRouter(engine: dj)
  let conductor = OfflineConductor(engine: dj, router: router)
  let bar = Int(rate * 2) / OfflineConductor.blockFrames
  var l: [Float] = []
  var r: [Float] = []
  for b in 0..<blocks {
    let (bl, br) = try conductor.step {
      switch b {
      case 0:
        dj.perform(
          .load(
            deck: "A", source: .sample(id: DeckSourceDescriptor.demoID, title: "demo", grid: nil)))
        dj.perform(.play(deck: "A", on: true))
      case bar + bar / 2: dj.perform(.loopRecord(deck: "A", on: true, bars: 1))
      case bar + bar / 2 + 2: dj.perform(.loopRecord(deck: "A", on: false))
      default: break
      }
      script(dj, bar, b)
      midi?(router, bar, b)
    }
    l += bl
    r += br
  }
  let session = recorder.finish()
  journal.close()
  return LoopMasterSet(
    session: session, audio: RenderedAudio(sampleRate: rate, left: l, right: r),
    journal: try readNewestJournal(dir))
}
