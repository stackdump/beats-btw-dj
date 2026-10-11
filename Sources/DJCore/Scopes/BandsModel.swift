// BandsModel: the numbers behind the Bands scope (SPEC mode 5): scope.js `modelDb`, `measDb`,
// `rowRefs`, `fullBar`, `scopeStats` and the digit / residual rules of `drawBands`, pinned at
// beats-bitwrap-io 095d030. The view's layout is `BandsScene`; the frame-to-frame state is
// `BandsController`.
//
// WHAT IT HOLDS. A bar is 16 steps; a row is one of the five bands `sub low lomid himid high`
// (0 ... 4) or E (5), the sum of the five. Two sources of per-bar power, both indexed by SONG BAR
// of the feed's lead deck (`bar = floor(step / 16)`, checked on both sides: `ModelEngine.deposit`
// takes `step >> 4` of the fire's step, `MeasuredReader.ingest` takes `floor(step / 16)` of the
// step at "now" from the anchor at or before it):
//   * the MODEL side `ModelEngine.modelBars[bar * 6 + r]` (linear power, units of Σx²);
//   * the MEASURED side `MeasuredReader.measBars[bar * 6 + r] / measCnt[bar]` (the mean analyser
//     power of the bar's reads, units of Σ|X|²/N²).
// The two sides are NOT in the same units (see the headers of ModelEngine and MeasuredReader), so
// nothing here compares levels: the digits are relative to each row's own loudest bar, and the
// residual and the statistics are in dB with each side's per-row MEAN removed, exactly as the JS.
//
// THE SHARED maxBar. scope.js has one `maxBar` for both sides; here each has its own, and the
// view walks `max(model.maxBar, reader.maxBar)` (`maxBar`). `BandsModel(model:reader:)` leaves the
// reader out when the panel's "measured" is off: a reader that stopped reading keeps the bars it
// had (and only forgets them when it is next enabled), which a model-only picture must not show.
//
// WHAT IT COMPUTES (all of it from plain arrays, so it is testable without an engine)
//   * `modelDb` / `measDb`: `10·log10` of the bar's power, nil where there is none (JS NaN).
//   * `rowRefs`: per row the loudest bar's dB (-inf: none) over bars 0 ... maxBar.
//   * `digit`: `clamp(round(9 - (ref - v) / 4), 0, 9)`, `Math.round` rounding (ties up). After the
//     clamp this is the same as Swift's `.rounded()`: they differ only for negative ties, which
//     both clamp to 0.
//   * `fullBar(b)`: `b·16 >= max(modelFrom, measFrom) && (b+1)·16 <= measAt`: both sides covered
//     the whole bar (neither the bar a side started in, nor the one still playing).
//   * `stats` (`scopeStats`): over full bars where both rows exist, per row: the number of bars,
//     `corr` (Pearson, null when a side is flat), `rmsResidualDb = sqrt(Σ(dx - dm)² / n)`,
//     `offsetDb = meanX - meanM`; fewer than 2 bars gives only `bars`. `bars` is the largest n.
//     The tilt is each band's offset minus the mean of the five (only if all five exist), computed
//     from the already rounded offsets. Values are rounded with JS `toFixed` (3, 2, 1 places; an
//     exact tie goes to the larger neighbour, which printf does not do).
//   * `residual`: `D(b, r) = (x - meanX_r) - (m - meanM_r)` on full bars (the means over ALL
//     full bars, not only the ones on screen), `residualLimit` the colour scale
//     `min(24, max(6, max|D|))` over the bars on screen, `residualIndex` the RdBu entry
//     `clamp(round((D / lim + 1) * 16), 0, 32)`.
//
// The cost of `agreement`/`stats` is two passes over at most 1024 bars x 6 rows; the controller
// runs them at most four times a second (the JS 250 ms redraw limit).
//
// `modelDb` / `measDb` repeat `ModelEngine.modelDb` / `MeasuredReader.measDb` on purpose: this is
// a value-type snapshot (sendable, no main actor) that a scene is built from while the engine
// goes on writing. `BandsSourceTests.bothSidesPutAStepInTheSameBarAndBandsModelReadsThemAsTheyAre`
// compares them cell for cell.
//
// A LIMIT THE JS HAS TOO. The model side is energy per bar (a sum of deposits) and the measured
// side the mean analyser power of the bar's reads, so they differ by about the bar's duration. A
// per-row mean removes that only while the tempo is constant: a tempo change inside a track steps
// the residual (a halving of the tempo reads about -4 dB on the measured side against an
// unchanged model, and corr / rms of the whole track suffer). Kept as in scope.js; normalising by
// the bar's duration would be a deliberate deviation (see the report's needsMatt).

import Foundation

/// Which of the two sources.
public enum BandsSide: Sendable {
  case model
  case measured
}

public struct BandsModel: Sendable {
  /// Rows per bar: the five bands and E (scope.js `ROWS`).
  public static let rows = ModelGrid.rows
  /// Steps in a bar.
  public static let stepsPerBar = 16
  /// One digit is this many dB (scope.js `LEVEL_DB`).
  public static let levelDb = 4.0
  /// `sub low lomid himid high E`, row 0 first.
  public static let labels: [String] = ModelGrid.bandLabels + ["E"]

  /// `ModelEngine.modelBars`: `bar * rows + r`.
  public let modelBars: [Double]
  public let modelMaxBar: Int
  /// The first step the model deposited (`Int.max`: none).
  public let modelFrom: Int
  /// `MeasuredReader.measBars` / `measCnt`: `bar * rows + r` and the reads per bar.
  public let measBars: [Double]
  public let measCnt: [Float]
  public let measMaxBar: Int
  /// The first / latest (fractional) step read (`.infinity` / -1: none).
  public let measFrom: Double
  public let measAt: Double

  public init(
    modelBars: [Double], modelMaxBar: Int, modelFrom: Int = .max,
    measBars: [Double] = [], measCnt: [Float] = [], measMaxBar: Int = -1,
    measFrom: Double = .infinity, measAt: Double = -1
  ) {
    self.modelBars = modelBars
    self.modelMaxBar = modelMaxBar
    self.modelFrom = modelFrom
    self.measBars = measBars
    self.measCnt = measCnt
    self.measMaxBar = measMaxBar
    self.measFrom = measFrom
    self.measAt = measAt
  }

  /// Nothing yet.
  public static let empty = BandsModel(modelBars: [], modelMaxBar: -1)

  /// The state of a model and, when the panel's "measured" is on, a reader. Arrays are shared,
  /// not copied.
  @MainActor
  public init(model: ModelEngine, reader: MeasuredReader?) {
    self.init(
      modelBars: model.modelBars, modelMaxBar: model.maxBar, modelFrom: model.modelFrom,
      measBars: reader?.measBars ?? [], measCnt: reader?.measCnt ?? [],
      measMaxBar: reader?.maxBar ?? -1, measFrom: reader?.measFrom ?? .infinity,
      measAt: reader?.measAt ?? -1)
  }

  /// The last bar either side has (-1: none): scope.js's one `maxBar`.
  public var maxBar: Int { max(modelMaxBar, measMaxBar) }

  // MARK: levels

  /// scope.js `modelDb`.
  public func modelDb(bar: Int, row: Int) -> Double? {
    guard bar >= 0, row >= 0, row < Self.rows else { return nil }
    let i = bar * Self.rows + row
    guard i < modelBars.count else { return nil }
    let v = modelBars[i]
    return v > 0 ? 10 * log10(v) : nil
  }

  /// scope.js `measDb`: the mean power of the bar's reads.
  public func measDb(bar: Int, row: Int) -> Double? {
    guard bar >= 0, row >= 0, row < Self.rows, bar < measCnt.count else { return nil }
    let i = bar * Self.rows + row
    guard i < measBars.count else { return nil }
    let n = measCnt[bar]
    let v = n > 0 ? measBars[i] / Double(n) : 0
    return v > 0 ? 10 * log10(v) : nil
  }

  public func db(_ side: BandsSide, bar: Int, row: Int) -> Double? {
    side == .model ? modelDb(bar: bar, row: row) : measDb(bar: bar, row: row)
  }

  /// scope.js `rowRefs`: per row the loudest dB over bars 0 ... maxBar, -inf where a row has none.
  public func rowRefs(_ side: BandsSide) -> [Double] {
    var out = [Double](repeating: -.infinity, count: Self.rows)
    guard maxBar >= 0 else { return out }
    for r in 0..<Self.rows {
      for b in 0...maxBar {
        if let v = db(side, bar: b, row: r), v > out[r] { out[r] = v }
      }
    }
    return out
  }

  /// The digit 0 ... 9 of a level against its row's loudest, nil for a cell that is empty (no
  /// level, or no finite reference).
  public static func digit(value v: Double?, ref: Double) -> Int? {
    guard let v, v.isFinite, ref.isFinite else { return nil }
    return Int(max(0, min(9, jsRound(9 - (ref - v) / levelDb))))
  }

  // MARK: coverage

  /// scope.js `fullBar`: both sides covered the whole of bar `b`.
  public func fullBar(_ b: Int) -> Bool {
    Double(b * Self.stepsPerBar) >= max(Double(modelFrom), measFrom)
      && Double((b + 1) * Self.stepsPerBar) <= measAt
  }

  // MARK: agreement and statistics

  /// Per row, over the full bars where both sides have a level: the sums of the model's and of
  /// the measured dB, and the number of bars (the JS `meanM`, `meanX`, `cntR` before they are
  /// divided).
  public struct Agreement: Equatable, Sendable {
    public var sumModel = [Double](repeating: 0, count: BandsModel.rows)
    public var sumMeasured = [Double](repeating: 0, count: BandsModel.rows)
    public var count = [Int](repeating: 0, count: BandsModel.rows)

    public func meanModel(_ r: Int) -> Double { sumModel[r] / Double(count[r]) }
    public func meanMeasured(_ r: Int) -> Double { sumMeasured[r] / Double(count[r]) }
  }

  /// First pass of `scopeStats`.
  public func agreement() -> Agreement {
    var a = Agreement()
    guard maxBar >= 0 else { return a }
    for b in 0...maxBar where fullBar(b) {
      for r in 0..<Self.rows {
        if let m = modelDb(bar: b, row: r), let x = measDb(bar: b, row: r) {
          a.sumModel[r] += m
          a.sumMeasured[r] += x
          a.count[r] += 1
        }
      }
    }
    return a
  }

  /// scope.js `scopeStats`. `modelStatus` and `fires` ride along as in the JS (`model`, `fires`).
  public func stats(
    agreement a: Agreement? = nil, modelStatus: String = "", fires: Int = 0
  ) -> BandsStats {
    let ag = a ?? agreement()
    var out = BandsStats(model: modelStatus, fires: fires)
    for r in 0..<Self.rows {
      let n = ag.count[r]
      if n < 2 {
        out.bands.append(BandsStats.Band(band: Self.labels[r], bars: n))
        continue
      }
      let mm = ag.sumModel[r] / Double(n)
      let mx = ag.sumMeasured[r] / Double(n)
      var sxy = 0.0
      var sxx = 0.0
      var syy = 0.0
      var se = 0.0
      for b in 0...maxBar where fullBar(b) {
        guard let m = modelDb(bar: b, row: r), let x = measDb(bar: b, row: r) else { continue }
        let dm = m - mm
        let dx = x - mx
        sxy += dm * dx
        sxx += dm * dm
        syy += dx * dx
        se += (dx - dm) * (dx - dm)
      }
      out.bands.append(
        BandsStats.Band(
          band: Self.labels[r], bars: n,
          corr: sxx > 0 && syy > 0 ? Self.toFixed(sxy / (sxx * syy).squareRoot(), 3) : nil,
          rmsResidualDb: Self.toFixed((se / Double(n)).squareRoot(), 2),
          offsetDb: Self.toFixed(mx - mm, 1)))
      out.bars = max(out.bars, n)
    }
    // Spectral tilt: each band's mean offset relative to the across-band mean.
    let nb = ModelGrid.nb
    let off = out.bands.prefix(nb).compactMap(\.offsetDb)
    if off.count == nb {
      let avg = off.reduce(0, +) / Double(nb)
      out.tiltDb = (0..<nb).map {
        BandsStats.Tilt(band: ModelGrid.bandLabels[$0], db: Self.toFixed(off[$0] - avg, 1))
      }
    }
    return out
  }

  // MARK: residual

  /// `D(b, r)` of `drawBands`: the measured level minus the model's, each with its row mean (over
  /// all full bars) removed. Nil outside the full bars, where a side has no level, or for a row
  /// with no bar in common.
  public func residual(bar b: Int, row r: Int, agreement a: Agreement) -> Double? {
    guard fullBar(b), let m = modelDb(bar: b, row: r), let x = measDb(bar: b, row: r),
      a.count[r] >= 1
    else { return nil }
    return (x - a.sumMeasured[r] / Double(a.count[r])) - (m - a.sumModel[r] / Double(a.count[r]))
  }

  /// The residual colour scale: 6 dB, or the largest |D| on `bars`, at most 24.
  public func residualLimit(bars: Range<Int>, agreement a: Agreement) -> Double {
    var lim = 6.0
    for b in bars {
      for r in 0..<Self.rows {
        if let d = residual(bar: b, row: r, agreement: a), abs(d) > lim { lim = abs(d) }
      }
    }
    return min(lim, 24)
  }

  /// The RdBu entry (0 ... 32, 16 = no difference) of a residual: `round((D / lim + 1) * 16)`.
  public static func residualIndex(_ d: Double, limit: Double) -> Int {
    Int(max(0, min(32, jsRound((d / limit + 1) * 16))))
  }

  // MARK: JS number formatting

  /// `+x.toFixed(digits)`: the number JS reads back from `toFixed`, which works from the exact
  /// value of the double and sends an exact tie to the larger neighbour (`printf` sends it to the
  /// even one).
  static func toFixed(_ x: Double, _ digits: Int) -> Double {
    Double(toFixedText(x, digits)) ?? x
  }

  /// JS `x.toFixed(digits)` for a finite `x` below 1e21.
  static func toFixedText(_ x: Double, _ digits: Int) -> String {
    guard x.isFinite else { return x.isNaN ? "NaN" : (x < 0 ? "-Infinity" : "Infinity") }
    let ax = abs(x)
    let scale = pow(10, Double(digits))
    let scaled = ax * scale
    // an exact tie: the product is exact (no rounding error) and ends in .5
    let tie = fma(ax, scale, -scaled) == 0 && scaled.truncatingRemainder(dividingBy: 1) == 0.5
    let body = String(
      format: "%.\(digits)f", tie ? (scaled.rounded(.down) + 1) / scale : ax)
    return x < 0 ? "-" + body : body
  }

  /// A JS number as `String(v)` prints one with at most a few decimals: no ".0" on a whole number.
  static func numberText(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
    return "\(v)"
  }
}

/// `scopeStats`'s result.
public struct BandsStats: Equatable, Sendable {
  /// One row's agreement; `corr` is nil where a side is flat, and the fit fields are nil with
  /// fewer than two bars.
  public struct Band: Equatable, Sendable {
    public var band: String
    public var bars: Int
    public var corr: Double?
    public var rmsResidualDb: Double?
    public var offsetDb: Double?

    public init(
      band: String, bars: Int, corr: Double? = nil, rmsResidualDb: Double? = nil,
      offsetDb: Double? = nil
    ) {
      self.band = band
      self.bars = bars
      self.corr = corr
      self.rmsResidualDb = rmsResidualDb
      self.offsetDb = offsetDb
    }
  }

  public struct Tilt: Equatable, Sendable {
    public var band: String
    public var db: Double
  }

  /// The most bars any row with a fit has.
  public var bars = 0
  /// `sub low lomid himid high E`, always six.
  public var bands: [Band] = []
  /// Present only when all five bands have an offset.
  public var tiltDb: [Tilt]?
  /// The model's kernel status and the fires it has taken in.
  public var model: String
  public var fires: Int

  public init(model: String = "", fires: Int = 0) {
    self.model = model
    self.fires = fires
  }

  /// The tilt line of the view: `tilt sub +1.2  low -0.3  ...`.
  public var tiltText: String? {
    guard let t = tiltDb else { return nil }
    return "tilt "
      + t.map { "\($0.band) \($0.db > 0 ? "+" : "")\(BandsModel.numberText($0.db))" }
      .joined(separator: "  ")
  }
}
