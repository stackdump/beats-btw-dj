import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// "Loops master FX" in the UI: the Loops row's Master FX fold opens the decks' master FX panel
/// aimed at "L"; its buttons are the deck pokes with deck "L", the row shows what runs, the link
/// is the `loopFxLink` poke, and the strip draws.
@MainActor
struct LoopMasterFxViewTests {
  @Test func theStripFiresOnTheLoopsAndShowsWhatRuns() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.model()
    defer { dj.stop() }
    #expect(m.clips.first?.loop == .on)
    #expect(!m.showLoopMasterFx && m.loopChannel.masterRunning.isEmpty)
    m.showLoopMasterFx = true
    m.fire("L", .sweepLp)
    m.poll()
    #expect(m.loopChannel.masterRunning == [.sweepLp], "lit while it waits for its bar and runs")
    #expect(dj["A"]!.wave.activeMasterMacros.isEmpty)
    m.setLoopFxLink(true)
    m.poll()
    #expect(m.loopChannel.fxLink && dj.loopFxLink)
    m.panic("L")
    try t.run(dj, 2048)
    m.poll()
    #expect(m.loopChannel.masterRunning.isEmpty)

    let row = LoopRowView(model: m).padding().background(Color.black)
      .environment(\.colorScheme, .dark)
    #expect(renderPixels(row, width: 1100, height: 330) != nil)
    let strip = LoopMasterFxStrip(model: m).padding().background(Color.black)
    #expect(renderPixels(strip, width: 800, height: 200) != nil)
  }
}

/// For a human: `make swift-shots SHOT_DIR=… FILTER=LoopMasterFxShots`.
@MainActor
struct LoopMasterFxShots {
  @Test func theLoopsMasterFxStrip() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.pads(3)
    defer { dj.stop() }
    m.showLoopMasterFx = true
    m.fire("L", .riser)
    m.fire("L", .octaveDown)
    m.poll()
    saveWindowPNG(
      LoopRowView(model: m).padding(12).frame(width: 1240, alignment: .topLeading)
        .background(Color(white: 0.1)),
      width: 1240, height: 420, name: "loops-master-fx-row")
    saveWindowPNG(
      LoopMasterFxStrip(model: m).padding(12).frame(width: 760, alignment: .topLeading)
        .background(Color(white: 0.1)),
      width: 760, height: 160, name: "loops-master-fx-strip")
  }
}
