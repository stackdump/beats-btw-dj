import SwiftUI
import Testing

@testable import DJViews

/// The mixer's beat-sync panel: lamps and the tempo difference.
@MainActor
struct SyncPanelTests {
  private let orange = Color(red: 1, green: 0.5, blue: 0)

  /// The current beat's lamp is filled in the deck's tint while it plays, the others dim; the
  /// downbeat's lamp is the wide one.
  @Test func theCurrentBeatIsLit() throws {
    // lamps at x 0–18 (downbeat), 22–34, 38–50, 54–66
    let centres = [9, 28, 44, 60]
    func lamps(_ beat: Int?, lit: Bool) throws -> [Int] {
      let px = try #require(
        renderPixels(BeatLamps(beat: beat, lit: lit, tint: orange), width: 66, height: 8))
      return centres.map { px.color($0, 4).r }
    }
    let playing = try lamps(2, lit: true)
    #expect(playing[2] > 200, "lit lamp \(playing)")
    #expect(playing.enumerated().allSatisfy { $0.offset == 2 || $0.element < 80 }, "\(playing)")
    let stopped = try lamps(2, lit: false)
    #expect(stopped[2] < playing[2] - 80 && stopped[2] > stopped[1], "stopped \(stopped)")
    let none = try lamps(nil, lit: true)
    #expect(none.allSatisfy { $0 < 80 }, "no tempo \(none)")
    // the downbeat's lamp is wider: lit at x 2 and 16, where a narrow lamp would end at 12
    let down = try #require(
      renderPixels(BeatLamps(beat: 0, lit: true, tint: orange), width: 66, height: 8))
    #expect(down.color(2, 4).r > 200 && down.color(16, 4).r > 200)
  }

  /// Which deck is faster and by how much; "in sync" within 0.05 BPM; nothing without both tempos.
  @Test func tempoDifference() {
    func rows(_ a: Double?, _ b: Double?) -> [SyncPanel.Row] {
      [
        .init(name: "A", tint: orange, bpm: a, beat: 0, playing: true),
        .init(name: "B", tint: .blue, bpm: b, beat: 0, playing: true),
      ]
    }
    #expect(SyncPanel.tempoDelta(rows(128, 120)) == "A +8.0 BPM")
    #expect(SyncPanel.tempoDelta(rows(120, 124.5)) == "B +4.5 BPM")
    #expect(SyncPanel.tempoDelta(rows(128, 128.02)) == "in sync")
    #expect(SyncPanel.tempoDelta(rows(128, nil)) == nil)
  }
}
