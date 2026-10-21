import Foundation

// A set: a named, ordered run of saved compositions (`CompositionStore`) laid out on an energy
// curve, kept at `~/Library/Application Support/dj-vevr-se/sets/<slug>.json` (`$DJ_SETS_DIR`).
//
//   plan   — the shape you want: slots with a label, an energy 0…1, optionally a tempo and a key
//            ("warm-up 0.3 · 124 BPM", "peak 0.95 · 150 BPM · A minor", …)
//   items  — which composition plays in each slot, with optional mix-out overrides
//   cursor — the item on the deck now (runtime, written back on `start` / `mix`)
//
// `SetPlanner.sequence` fills the plan from what's saved (energy, tempo, key distance) and says
// which slots have nothing close enough, with the brief to compose for each. The hand-offs are
// `AppControl+Set` (`dj_set mix`): the same beat-matched, bass-swapped crossfade each time.

public struct SetPlanSlot: Codable, Equatable {
  public var label: String
  public var energy: Double  // 0…1
  public var bpm: Double?
  public var key: String?  // "A minor", "F# major"
  public var bars: Int?  // wanted length, a hint for composing

  public init(
    label: String, energy: Double, bpm: Double? = nil, key: String? = nil, bars: Int? = nil
  ) {
    self.label = label
    self.energy = min(1, max(0, energy))
    self.bpm = bpm
    self.key = key
    self.bars = bars
  }
}

public struct SetItem: Codable, Equatable {
  public var composition: String  // a CompositionStore entry id
  public var slot: Int?  // index into the plan
  public var mixOutBar: Int?  // start mixing out here (auto runner, step 2)
  public var fadeBars: Int?  // crossfade length into the next item

  public init(composition: String, slot: Int? = nil, mixOutBar: Int? = nil, fadeBars: Int? = nil) {
    self.composition = composition
    self.slot = slot
    self.mixOutBar = mixOutBar
    self.fadeBars = fadeBars
  }
}

public struct DJSet: Codable, Equatable {
  public var v = 1
  public var name: String
  public var created: String
  public var plan: [SetPlanSlot]
  public var items: [SetItem]
  public var cursor: Int
  /// Default crossfade length in bars (an item's `fadeBars` wins).
  public var fadeBars: Int

  public init(
    name: String, created: String = "", plan: [SetPlanSlot] = [], items: [SetItem] = [],
    cursor: Int = 0, fadeBars: Int = 8
  ) {
    self.name = name
    self.created = created
    self.plan = plan
    self.items = items
    self.cursor = cursor
    self.fadeBars = fadeBars
  }
}

public struct SetStore {
  public let directory: URL

  public static var defaultDirectory: URL {
    if let d = ProcessInfo.processInfo.environment["DJ_SETS_DIR"], !d.isEmpty {
      return URL(fileURLWithPath: d, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("dj-vevr-se/sets", isDirectory: true)
  }

  public init(directory: URL = SetStore.defaultDirectory) { self.directory = directory }

  public enum StoreError: Error, Equatable, CustomStringConvertible {
    case noSet(String)
    public var description: String {
      switch self {
      case .noSet(let n): return "no set called `\(n)` (dj_set list; dj_set plan creates one)"
      }
    }
  }

  func url(_ name: String) -> URL {
    directory.appendingPathComponent(CompositionStore.slug(name) + ".json")
  }

  public func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: url(name).path)
  }

  public func save(_ set: DJSet) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(set).write(to: url(set.name), options: .atomic)
  }

  public func load(_ name: String) throws -> DJSet {
    guard let data = FileManager.default.contents(atPath: url(name).path),
      let set = try? JSONDecoder().decode(DJSet.self, from: data)
    else { throw StoreError.noSet(name) }
    return set
  }

  /// All sets, by name.
  public func list() -> [DJSet] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { f in
      FileManager.default.contents(atPath: directory.appendingPathComponent(f).path).flatMap {
        try? JSONDecoder().decode(DJSet.self, from: $0)
      }
    }
  }
}

// MARK: - energy-curve planning

public struct CompositionInfo: Equatable {
  public var id: String
  public var name: String
  public var energy: Double?
  public var key: String?
  public var tempo: Double?
  public var bars: Int?

  public init(
    id: String, name: String, energy: Double? = nil, key: String? = nil, tempo: Double? = nil,
    bars: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.energy = energy
    self.key = key
    self.tempo = tempo
    self.bars = bars
  }
}

public enum SetPlanner {
  /// A slot nothing saved fits: compose this.
  public struct Gap: Equatable {
    public var slot: Int
    public var label: String
    public var energy: Double
    public var bpm: Double?
    public var key: String?
    public var bars: Int?
    /// The closest thing saved, and why it was refused (nil: nothing saved at all).
    public var closest: String?
  }

  public struct Result: Equatable {
    public var items: [SetItem]
    public var gaps: [Gap]
    /// Neighbouring tracks whose tempos can't be matched on the fader (beyond ±8 %, even at
    /// half / double time): `from`, `to` are item indexes after sequencing.
    public var tempoJumps: [(from: Int, to: Int, ratio: Double)]

    public static func == (a: Result, b: Result) -> Bool {
      a.items == b.items && a.gaps == b.gaps
        && a.tempoJumps.map { [$0.from, $0.to] } == b.tempoJumps.map { [$0.from, $0.to] }
    }
  }

  /// How far a composition is from a slot: 0 = exact. Energy counts most, then tempo (matchable
  /// at 1×, ½× or 2×), then key distance on the circle of fifths.
  public static func cost(_ slot: SetPlanSlot, _ c: CompositionInfo) -> Double {
    var cost = 2 * abs(slot.energy - (c.energy ?? 0.5))
    if let want = slot.bpm, let have = c.tempo, want > 0, have > 0 {
      cost += 4 * tempoGap(have, want)
    }
    if let a = slot.key, let b = c.key, let d = keyDistance(a, b) { cost += 0.12 * Double(d) }
    return cost
  }

  /// Relative tempo gap after the best of 1×, ½×, 2× (0 = same).
  static func tempoGap(_ a: Double, _ b: Double) -> Double {
    [1.0, 0.5, 2.0].map { abs(a * $0 / b - 1) }.min() ?? 1
  }

  /// Steps apart on the circle of fifths, relative keys counting as the same (nil: unreadable).
  public static func keyDistance(_ a: String, _ b: String) -> Int? {
    guard let x = fifths(a), let y = fifths(b) else { return nil }
    let d = abs(x - y) % 12
    return min(d, 12 - d)
  }

  /// A key's position on the circle of fifths as its relative major (C = 0, G = 1, F = −1…).
  static func fifths(_ key: String) -> Int? {
    let s = key.trimmingCharacters(in: .whitespaces)
    guard let first = s.first, "ABCDEFGabcdefg".contains(first) else { return nil }
    let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][
      String(first).uppercased()]!
    var pc = base
    let rest = s.dropFirst()
    if rest.first == "#" || rest.first == "♯" {
      pc += 1
    } else if rest.first == "b" || rest.first == "♭" {
      pc -= 1
    }
    let lower = s.lowercased()
    let minor = lower.contains("min") || (rest.contains("m") && !lower.contains("maj"))
    if minor { pc += 3 }  // relative major
    pc = ((pc % 12) + 12) % 12
    return (pc * 7) % 12  // position on the circle (C = 0)
  }

  /// Fill the plan, slot by slot, from `pool` (each composition once): `kept` items keep their
  /// mix overrides. Slots whose best candidate costs more than `maxCost` are gaps.
  public static func sequence(
    plan: [SetPlanSlot], pool: [CompositionInfo], kept: [SetItem] = [], maxCost: Double = 0.6
  ) -> Result {
    var free = pool
    var items: [SetItem] = []
    var gaps: [Gap] = []
    var chosen: [CompositionInfo] = []
    for (i, slot) in plan.enumerated() {
      let ranked = free.map { ($0, cost(slot, $0)) }.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
      if let (best, c) = ranked.first, c <= maxCost {
        free.removeAll { $0.id == best.id }
        var item = kept.first { $0.composition == best.id } ?? SetItem(composition: best.id)
        item.slot = i
        items.append(item)
        chosen.append(best)
      } else {
        gaps.append(
          Gap(
            slot: i, label: slot.label, energy: slot.energy, bpm: slot.bpm, key: slot.key,
            bars: slot.bars,
            closest: ranked.first.map { "\($0.0.name) (cost \(String(format: "%.2f", $0.1)))" }))
      }
    }
    var jumps: [(from: Int, to: Int, ratio: Double)] = []
    for i in 1..<max(1, chosen.count) {
      if let a = chosen[i - 1].tempo, let b = chosen[i].tempo, tempoGap(a, b) > 0.08 {
        jumps.append((i - 1, i, b / a))
      }
    }
    return Result(items: items, gaps: gaps, tempoJumps: jumps)
  }

  /// A ready-made energy curve of `count` slots: `arc` (warm up, peak in the middle, cool down),
  /// `rise` (climb to the end) or `plateau` (ramp, hold, ease off). `bpm` maps the curve's low
  /// and high energy onto a tempo range.
  public static func curve(shape: String, count: Int, bpm: ClosedRange<Double>? = nil)
    -> [SetPlanSlot]
  {
    let n = max(1, min(32, count))
    let energies: [Double] = (0..<n).map { i in
      let t = n == 1 ? 0.5 : Double(i) / Double(n - 1)
      switch shape {
      case "rise": return 0.3 + 0.7 * t
      case "plateau": return t < 0.25 ? 0.3 + 0.6 * (t / 0.25) : (t > 0.85 ? 0.55 : 0.9)
      default: return 0.35 + 0.6 * sin(Double.pi * t)  // arc
      }
    }
    let lo = energies.min() ?? 0
    let hi = energies.max() ?? 1
    return energies.enumerated().map { i, e in
      let label: String =
        e < 0.4
        ? (i < n / 2 ? "warm-up" : "cool-down")
        : e < 0.65 ? "build" : e < 0.85 ? "lift" : "peak"
      let tempo = bpm.map {
        $0.lowerBound + ($0.upperBound - $0.lowerBound) * (hi > lo ? (e - lo) / (hi - lo) : 0.5)
      }
      return SetPlanSlot(
        label: label, energy: (e * 100).rounded() / 100, bpm: tempo.map { $0.rounded() })
    }
  }
}

// MARK: - auto-advance

/// When a running set hands off on its own (`dj_set auto`): the bar (1-based, on the playing deck's
/// clock) the crossfade should start at, and when to begin loading the next track to be ready for it.
public enum SetAuto {
  /// The bar the fade starts at: the item's `mixOutBar`, else `fadeBars` before the track's last
  /// bar so the crossfade ends as the track does. nil: the track's length isn't known (and nothing
  /// was set), so there is nothing to time against.
  public static func startBar(bars: Int?, item: SetItem, fadeBars: Int) -> Int? {
    if let b = item.mixOutBar { return max(1, b) }
    guard let bars else { return nil }
    return max(1, bars - fadeBars + 1)
  }

  /// Begin the hand-off at `bar`: `leadBars` early, so the next track is loaded and aligned and the
  /// fade starts on `startBar` (loading takes under a bar at any tempo worth mixing).
  public static func due(bar: Int, startBar: Int, leadBars: Int) -> Bool {
    bar >= startBar - max(0, leadBars)
  }
}
