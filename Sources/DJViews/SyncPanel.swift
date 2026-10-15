import SwiftUI

/// The mixer's beat-sync panel: for each deck its tempo and four beat lamps (the beat it is on
/// lit in its tint, the downbeat's lamp wider), and how far the two tempos are apart — what a
/// DJ reads to beat-match, in one place between the decks.
struct SyncPanel: View {
  struct Row: Equatable {
    var name: String
    var tint: Color
    var bpm: Double?
    var beat: Int
    var playing: Bool
  }

  let rows: [Row]

  /// "A +2.0 BPM", "in sync", or nil when a deck has no tempo.
  static func tempoDelta(_ rows: [Row]) -> String? {
    guard rows.count == 2, let a = rows[0].bpm, let b = rows[1].bpm else { return nil }
    let d = a - b
    if abs(d) < 0.05 { return "in sync" }
    return String(format: "%@ %+.1f BPM", d > 0 ? rows[0].name : rows[1].name, abs(d))
  }

  var body: some View {
    VStack(spacing: DJStyle.s) {
      SectionLabel("Sync")
      ForEach(rows, id: \.name) { row in
        HStack(spacing: DJStyle.s) {
          Text(row.name).font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(row.tint).frame(width: 12)
          Text(row.bpm.map { String(format: "%.1f", $0) } ?? "—")
            .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
            .frame(width: 48, alignment: .trailing)
          Spacer(minLength: 0)
          BeatLamps(beat: row.bpm == nil ? nil : row.beat, lit: row.playing, tint: row.tint)
        }
      }
      if let delta = Self.tempoDelta(rows) {
        Text(delta).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .contentTransition(.numericText())
      }
    }
  }
}

/// Four lamps, one per beat of the bar: the current one filled in `tint` while the deck plays
/// (outlined when stopped), the rest dim; the downbeat's lamp is wider. No tempo: all dim.
struct BeatLamps: View {
  static let size = CGSize(width: 12, height: 8)
  static let downbeatWidth: CGFloat = 18
  static let spacing: CGFloat = 4

  let beat: Int?
  let lit: Bool
  let tint: Color

  var body: some View {
    HStack(spacing: Self.spacing) {
      ForEach(0..<4, id: \.self) { i in
        let on = beat == i
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(on && lit ? tint : tint.opacity(on ? 0.35 : 0.14))
          .frame(width: i == 0 ? Self.downbeatWidth : Self.size.width, height: Self.size.height)
          .animation(.easeOut(duration: 0.08), value: on && lit)
      }
    }
    .accessibilityLabel(beat.map { "beat \($0 + 1)" } ?? "no tempo")
  }
}
