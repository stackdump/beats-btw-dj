import Foundation

extension Session {
  /// A one-deck set that plays `spec` from the first frame to the end of its song (plus
  /// `tail` seconds), or for `seconds` — a loop has no end, so it needs them. For rendering a
  /// composed track offline (`djctl render`) with nothing recorded by hand.
  public static func playing(
    _ spec: TrackSpec, seconds: Double? = nil, tail: Double = 2, sampleRate: Double = 44100
  ) -> Session? {
    var length = seconds
    if length == nil {
      let p = spec.project()
      let steps = p.structure.reduce(0) { $0 + $1.steps }
      guard steps > 0, p.tempo > 0 else { return nil }
      length = Double(steps) * 60 / (p.tempo * 4) + tail
    }
    return Session(
      sampleRate: sampleRate, frames: Int((length! * sampleRate).rounded()),
      decks: ["A": .net(spec)], params: ["A": DeckParams()], crossfader: 0, master: 0.8,
      events: [SessionEvent(frame: 0, kind: .action(.play(deck: "A", on: true)))])
  }
}

extension RenderedAudio {
  /// Peak and RMS over both channels, in dBFS.
  public var levels: (peak: Double, rms: Double) {
    var peak: Float = 0
    var sum = 0.0
    for ch in [left, right] {
      for x in ch {
        peak = max(peak, abs(x))
        sum += Double(x) * Double(x)
      }
    }
    let n = max(1, left.count + right.count)
    func db(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -.infinity }
    return (db(Double(peak)), db((sum / Double(n)).squareRoot()))
  }
}
