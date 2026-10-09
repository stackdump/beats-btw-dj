// The analytic scope views and the height rule of their panel (scope.js `VIEWS`, `viewHeight`).

import Foundation

/// Which analytic view the scope panel shows. (The stage visualisers of SPEC modes 7...21 are
/// not scope kinds: they have their own entry point.)
public enum ScopeKind: String, CaseIterable, Identifiable, Sendable {
  case live, spectro, bands, raster

  public var id: String { rawValue }

  /// The button label (scope.js `VIEWS`).
  public var title: String {
    switch self {
    case .live: "Scope"
    case .spectro: "Spectro"
    case .bands: "Bands"
    case .raster: "Raster"
    }
  }

  /// The tooltip (scope.js `VIEWS`).
  public var help: String {
    switch self {
    case .live: "Waveform x and fired events μ on one time axis (rolling 4 bars)"
    case .spectro:
      "Log-frequency spectrogram — model (Σ events × kernel × FX); measured below when on"
    case .bands: "Per-bar band energy, IR digits 0-9 (4 dB/step below each band's loudest bar)"
    case .raster: "Score raster μ of the whole arrangement, sections marked"
    }
  }

  /// Do modes 3 and 5 add a measured half to this view?
  public var supportsMeasured: Bool { self == .spectro || self == .bands }

  /// scope.js `viewHeight`: the panel's height in points.
  ///
  /// `room` is what a window leaves: `clamp(round(windowHeight * 0.55), 0, 640)`, with 800 for a
  /// window of unknown height (JS `window.innerHeight || 800`). `laneCount` is the number of
  /// lanes of the feed.
  public static func viewHeight(
    kind: ScopeKind, measured: Bool, laneCount: Int, windowHeight: Double?
  ) -> Double {
    let h = (windowHeight ?? 0) > 0 ? windowHeight! : 800
    let room = max(0, min(640, jsRound(h * 0.55)))
    let lanes = Double(laneCount)
    switch kind {
    case .spectro: return measured ? max(300, room) : max(170, jsRound(room * 0.7))
    case .bands: return measured ? 300 : 124
    case .raster: return max(90, min(max(560, room), lanes * 28 + 32))
    case .live: return max(170, min(640, max(110 + lanes * 12, room)))
    }
  }

  public func height(measured: Bool, laneCount: Int, windowHeight: Double?) -> Double {
    Self.viewHeight(
      kind: self, measured: measured, laneCount: laneCount, windowHeight: windowHeight)
  }
}
