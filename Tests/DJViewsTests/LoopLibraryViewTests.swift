import DJCore
import SwiftUI
import Testing

@testable import DJViews

@MainActor
struct LoopLibraryViewTests {
  /// Deck A plays the demo loop (120 bpm); LOOP record takes `takes` one-bar clips of it.
  func model(takes n: Int = 2, library: LoopLibrary? = nil) throws -> (AppModel, DJEngine) {
    let rate = 22_050.0
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: rate)
    dj["A"]!.loadDemo()
    dj["A"]!.setPlaying(true)
    try dj.start()
    let bar = Int(rate * 2)
    func run(_ frames: Int) throws {
      var done = 0
      while done < frames {
        done += try renderOffline(dj, frames: 512)
        dj.serviceLoopTakes()
      }
    }
    let m = AppModel(engine: dj, takes: library)
    m.start()
    try run(bar + bar / 2)
    for k in 0..<n {
      // identical bars would be one clip (same audio, same id): each take is EQ'd apart
      dj.perform(.param(deck: "A", name: "eqHigh", value: 0.5 - 0.1 * Double(k)))
      m.loopRecord("A", on: true)
      try run(bar / 2)
      m.loopRecord("A", on: false)
      try run(bar)
    }
    m.poll()
    #expect(m.clips.count == n && Set(m.clips.map(\.id)).count == n, "\(n) different takes")
    return (m, dj)
  }

  @Test func removingShowsUndoForAFewSecondsAndUndoPutsItBack() throws {
    let (m, dj) = try model()
    defer { dj.stop() }
    var now = 100.0
    m.uptime = { now }
    let ids = m.clips.map(\.id)
    m.removeClip(ids[0])
    #expect(m.clips.map(\.id) == [ids[1]] && m.lastRemoval?.id == ids[0])
    #expect(m.removedLoops.map(\.id) == [ids[0]], "listed under Removed")
    m.undoRemove()
    #expect(m.clips.map(\.id) == ids, "back where it was")
    #expect(m.lastRemoval == nil && m.removedLoops.isEmpty)
    m.removeClip(ids[1])
    now += LoopRemoval.undoSeconds + 1
    m.poll()
    #expect(m.lastRemoval == nil, "the Undo goes after a few seconds")
    #expect(m.removedLoops.map(\.id) == [ids[1]], "but it can still be restored")
    #expect(m.restoreRemoved(ids[1]) && m.clips.map(\.id) == ids)
  }

  @Test func theLibraryKeepsRemovedLoopsAcrossLaunches() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try model(library: lib)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    m.flushLoopLibrary()
    m.removeClip(ids[0])
    m.flushLoopLibrary()
    #expect(removedLoopFiles(lib).contains("\(ids[0]).wav"), "the audio is kept")
    #expect(lib.load(sampleRate: dj.sampleRate).map(\.id) == [ids[1]])
    // the next launch lists it, and restores it from removed/ where it was
    let dj2 = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: dj.sampleRate)
    let m2 = AppModel(engine: dj2, takes: lib)
    m2.start()
    m2.poll()
    #expect(m2.removedLoops.map(\.id) == [ids[0]] && m2.clips.map(\.id) == [ids[1]])
    #expect(m2.restoreRemoved(ids[0]))
    #expect(m2.clips.map(\.id) == ids)
    #expect(m2.clips.first?.provenance.first == "Deck A: demo loop", "with its provenance")
    m2.flushLoopLibrary()
    #expect(lib.removed().isEmpty && lib.load(sampleRate: dj.sampleRate).map(\.id) == ids)
    // and delete forever deletes
    m2.removeClip(ids[1])
    m2.flushLoopLibrary()
    m2.deleteForever(ids[1])
    m2.flushLoopLibrary()
    #expect(!removedLoopFiles(lib).contains("\(ids[1]).wav") && m2.removedLoops.isEmpty)
    #expect(!m2.restoreRemoved(ids[1]))
    let state = m2.controlState()
    #expect(state["loops"]?["removed"]?.array?.isEmpty == true)
  }

  @Test func namesAndColoursAreSavedAndRecorded() throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try model(takes: 1, library: lib)
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.renameClip(id, "big drop")
    m.setClipColor(id, "teal")
    #expect(m.clips.first?.title == "big drop" && m.clips.first?.color == "teal")
    m.flushLoopLibrary()
    let saved = try #require(lib.load(sampleRate: dj.sampleRate).first)
    #expect(saved.title == "big drop" && saved.color == "teal")
    #expect(m.controlState()["loops"]?["clips"]?[0]?["color"]?.string == "teal")
  }

  @Test func deleteForeverIsNotUndoneByASaveAlreadyUnderWay() async throws {
    let lib = tempLoopLibrary()
    defer { removeLoopLibrary(lib) }
    let (m, dj) = try model(library: lib)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    m.flushLoopLibrary()
    // the removal's save is still queued (it reads removed/ after writing) when the delete comes
    let release = holdQueue(m.saveQueue)
    m.removeClip(ids[0])
    m.deleteForever(ids[0])
    release()
    m.saveQueue.sync {}
    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }  // the posts land on main
    m.poll()
    #expect(!m.removedLoops.contains { $0.id == ids[0] }, "\(m.removedLoops.map(\.id))")
    #expect(!m.diskRemoved.contains { $0.id == ids[0] })
    #expect(lib.removed().isEmpty && !removedLoopFiles(lib).contains("\(ids[0]).wav"))
    // a later removal still shows up, from the library's list
    m.removeClip(ids[1])
    m.saveQueue.sync {}
    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(m.diskRemoved.map(\.id) == [ids[1]])
  }

  @Test func thePlayingTempoChangesOnlyWithTheTempo() throws {
    let (m, dj) = try model(takes: 1)
    defer { dj.stop() }
    let flag = ChangeFlag()
    withObservationTracking {
      _ = m.playingTempo
    } onChange: {
      flag.set()
    }
    for _ in 0..<3 {
      _ = try renderOffline(dj, frames: 2048)
      m.poll()
    }
    #expect(m.decks["A"]?.playing == true)
    #expect(!flag.changed, "deck A's position moves on; its tempo does not")
    m.setPitch("A", 0.5)
    m.poll()
    #expect(flag.changed && m.playingTempo.map { abs($0 - 124.8) < 0.5 } == true)
  }

  @Test func filtersHideTilesButPadSlotsFollowTheWholeRow() throws {
    let (m, dj) = try model(takes: 4)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    m.toggleSelected(ids[0])
    m.joinSelected()
    let seq = try #require(m.clips.last?.id)
    m.toggleSourceFilter("seq")
    #expect(m.visibleClips.map(\.id) == [seq])
    #expect(m.padSlot(seq) == "B1", "its slot is its place on the whole row")
    m.toggleSourceFilter("seq")
    m.toggleSourceFilter("B")
    #expect(m.visibleClips.isEmpty, "nothing was taken from B")
    m.loopFilter = LoopFilter()
    m.renameClip(ids[1], "Warehouse stab")
    m.loopFilter.search = "wareHOUSE"
    #expect(m.visibleClips.map(\.id) == [ids[1]] && m.padSlot(ids[1]) == "A2")
    m.loopFilter = LoopFilter(nearTempo: true)
    #expect(m.playingTempo.map { abs($0 - 120) < 0.5 } == true, "deck A plays at 120")
    #expect(m.visibleClips.count == 5, "every take is at 120")
    m.setPitch("A", 1)  // +8 %
    m.poll()
    #expect(m.visibleClips.isEmpty, "none within 5 % of 129.6 bpm")
    let view = LoopRowView(model: m).padding().background(Color.black)
      .environment(\.colorScheme, .dark)
    savePNG(view, width: 900, height: 220, name: "loop-row-filtered")
  }

  @Test func aLoopLoadsTheTrackItCameFrom() async throws {
    let (m, dj) = try model(takes: 1)
    defer { dj.stop() }
    let clip = try #require(m.clips.first)
    #expect(clip.canLoadOrigin, "the demo loop can always be loaded")
    #expect(m.decks["B"]?.title != "demo loop")
    #expect(await m.loadOrigin(clip.id, on: "B"))
    m.poll()
    #expect(m.decks["B"]?.title == "demo loop")
  }

  @Test func aDraggedTileIsAWAVFileNamedAfterIt() throws {
    let (m, dj) = try model(takes: 1)
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.renameClip(id, "drop/2")
    let clip = try #require(dj.clip(id))
    let url = try ClipDrag.file(for: clip)
    #expect(fileExists(url) && fileName(url) == "drop-2.wav")
  }
}
