/// Every beats visualization, by the names beats uses. `scope.js` calls its four views
/// `live` / `spectro` / `bands` / `raster`; `stage.js` calls its visualizers `mandala`
/// (shown as "Constellation"), `corona`, `sonar` and `petal`. Ports add one line to
/// `ScopeRegistry` (DJViews) per mode.
public enum ScopeMode: String, CaseIterable, Identifiable, Sendable {
  /// scope.js `live`: waveform x and fired events μ on one rolling time axis.
  case scope
  /// Log-frequency spectrogram.
  case spectro
  /// Per-bar band energy as IR digits.
  case bands
  /// Score raster of the arrangement.
  case raster
  /// stage.js `mandala`.
  case constellation
  case corona
  case sonar
  case petal

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .scope: "Scope"
    case .spectro: "Spectro"
    case .bands: "Bands"
    case .raster: "Raster"
    case .constellation: "Constellation"
    case .corona: "Corona"
    case .sonar: "Sonar"
    case .petal: "Petal"
    }
  }

  /// The one-line description scope.js / stage.js give the mode.
  public var summary: String {
    switch self {
    case .scope: "Waveform and fired events on one time axis"
    case .spectro: "Log-frequency spectrogram"
    case .bands: "Per-bar band energy, IR digits 0-9"
    case .raster: "Score raster of the whole arrangement"
    case .constellation: "Every net as a ring panel, hits fading toward the centre"
    case .corona: "A halo around the master, one arc per part"
    case .sonar: "Fires as pings sweeping out from the centre"
    case .petal: "Parts as petals that open on each fire"
    }
  }
}

/// stage.js `vizModes`: layers that stack on top of a visualizer (a set, several at once).
public struct ScopeOverlays: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// Panels drift.
  public static let flow = ScopeOverlays(rawValue: 1 << 0)
  /// Beats fade toward the centre.
  public static let pulse = ScopeOverlays(rawValue: 1 << 1)
  /// Radial equalizer from the centre.
  public static let flame = ScopeOverlays(rawValue: 1 << 2)
  /// 3D perspective rotation.
  public static let tilt = ScopeOverlays(rawValue: 1 << 3)
  /// Lightning during macros (flame).
  public static let bolts = ScopeOverlays(rawValue: 1 << 4)
  /// Show every slot variant (A+B+…) rather than the active one.
  public static let expand = ScopeOverlays(rawValue: 1 << 5)
  /// Panel backgrounds.
  public static let backs = ScopeOverlays(rawValue: 1 << 6)
  /// Track labels.
  public static let labels = ScopeOverlays(rawValue: 1 << 7)

  /// stage.js starts with flow, pulse and flame on (and bolts).
  public static let stageDefault: ScopeOverlays = [.flow, .pulse, .flame, .bolts]
}

/// stage.js `bgMode`: the layer behind the visualizer (one at a time).
public enum ScopeBackground: String, CaseIterable, Identifiable, Sendable {
  case void
  case stars
  case aurora

  public var id: String { rawValue }
  public var title: String { rawValue.capitalized }
}
