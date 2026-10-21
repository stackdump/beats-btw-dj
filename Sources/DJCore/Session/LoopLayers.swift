import Foundation

// Loop layers: library sounds — vocals, risers, impacts, textures — that a raw track brings in as
// parallel tracks on the loop channel. A roll (or composition) names them in `loopLayers`:
//
//   {"loop": "Heavy Tech Riser 01", "bar": 28, "bars": 4, "gain": -6}
//   {"loop": "Bhangra Glow Chop Vox 01", "bar": [13, 29], "bars": 8, "gain": -9, "keyLock": true}
//
// `bar` is the (1-based) bar it comes in on (one, or a list), `bars` how long it stays (default one
// pass of the loop), `gain` dB under unity (−24…0, default −3), `keyLock` keeps its pitch when the
// deck's tempo isn't its own (default on). The app (`LayerRunner`) puts the loop on the row and
// launches and stops it on the deck's own bar clock, a bar ahead so the loop bank's launch
// quantizing lands it on the bar. Apple's licence covers playing the sounds in your music, not
// handing them on: a track with layers is local only (never published), and the envelope names
// the loop, never carries its audio.

public struct LoopLayerSpec: Equatable, Sendable {
  /// A library path, a loop's name, or a unique part of one (resolved by `LoopLayers.resolve`).
  public var loop: String
  /// The loop's name once resolved (kept for reading; the path is `loop`).
  public var name: String?
  public var bars: [Int]
  public var length: Int?
  public var gainDB: Double
  public var keyLock: Bool
  /// Set once resolved against the library (the loop's length in beats and its category), so a
  /// saved layer can be played and Wander-edited without the library at hand.
  public var beats: Int?
  public var category: String?

  public init(
    loop: String, name: String? = nil, bars: [Int], length: Int? = nil, gainDB: Double = -3,
    keyLock: Bool = true, beats: Int? = nil, category: String? = nil
  ) {
    self.loop = loop
    self.name = name
    self.bars = bars
    self.length = length
    self.gainDB = gainDB
    self.keyLock = keyLock
    self.beats = beats
    self.category = category
  }

  public var json: JSONValue {
    var o = JSONObject([("loop", .string(loop))])
    if let name { o["name"] = .string(name) }
    o["bar"] = .array(bars.map { .int($0) })
    if let length { o["bars"] = .int(length) }
    o["gain"] = .number(gainDB)
    o["keyLock"] = .bool(keyLock)
    if let beats { o["beats"] = .int(beats) }
    if let category { o["category"] = .string(category) }
    return .object(o)
  }
}

public enum LoopLayers {
  public static let maxLayers = 12
  public static let envelopeKey = "loopLayers"

  /// Validate and read a `loopLayers` / `layers` value.
  public static func parse(_ v: JSONValue?) throws -> [LoopLayerSpec] {
    guard let v else { return [] }
    guard let list = v.array else {
      throw PianoRollError.bad("`layers` must be a list: [{loop, bar, bars?, gain?, keyLock?}, …]")
    }
    guard list.count <= maxLayers else {
      throw PianoRollError.bad("at most \(maxLayers) layers (a mix that many loops wide is mud)")
    }
    return try list.enumerated().map { i, l in
      guard let loop = l["loop"]?.string, !loop.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw PianoRollError.bad(
          "layer \(i): `loop` is the loop's name or path (dj_stock_loops lists them)")
      }
      var starts: [Int] = []
      if let n = l["bar"]?.double ?? l["at"]?.double {
        starts = [Int(n.rounded())]
      } else if let a = (l["bar"] ?? l["at"])?.array {
        starts = a.compactMap { $0.double.map { Int($0.rounded()) } }
      }
      guard !starts.isEmpty, starts.allSatisfy({ (1...256).contains($0) }) else {
        throw PianoRollError.bad(
          "layer \(i) (\(loop)): `bar` is the bar it comes in on, 1 or more (or a list)")
      }
      var length: Int?
      if let b = l["bars"]?.double {
        guard (1...64).contains(Int(b.rounded())) else {
          throw PianoRollError.bad("layer \(i) (\(loop)): `bars` must be 1…64")
        }
        length = Int(b.rounded())
      }
      let gain = l["gain"]?.double ?? -3
      guard (-24...0).contains(gain) else {
        throw PianoRollError.bad(
          "layer \(i) (\(loop)): `gain` is dB under unity, −24…0 (loops can't be boosted)")
      }
      return LoopLayerSpec(
        loop: loop, name: l["name"]?.string, bars: starts.sorted(), length: length, gainDB: gain,
        keyLock: l["keyLock"]?.bool ?? true, beats: l["beats"]?.double.map { Int($0) },
        category: l["category"]?.string)
    }
  }

  public static func json(_ specs: [LoopLayerSpec]) -> JSONValue { .array(specs.map(\.json)) }

  /// Linear clip gain (`clipGain`, 0…1) for dB under unity.
  public static func gain(db: Double) -> Double { min(1, max(0, pow(10, min(0, db) / 20))) }

  /// The bars a layer is on: each start with its end (exclusive), `length` bars (default: one pass
  /// of the loop, `beats` / 4 rounded up, at least 1).
  public static func windows(_ s: LoopLayerSpec, loopBeats: Int) -> [(start: Int, end: Int)] {
    let n = s.length ?? max(1, (loopBeats + 3) / 4)
    return s.bars.map { ($0, $0 + n) }
  }

  /// A loop from the library: by exact path, exact name, or a unique substring of the name (nearest
  /// tempo to `bpm` first when given). Ambiguity is an error naming the candidates.
  public static func resolve(_ text: String, in library: [StockLoop], near bpm: Double? = nil)
    -> Result<StockLoop, PianoRollError>
  {
    let q = text.trimmingCharacters(in: .whitespaces)
    if let l = library.first(where: { $0.path == q }) { return .success(l) }
    let exact = library.filter { $0.name.lowercased() == q.lowercased() }
    if exact.count == 1 { return .success(exact[0]) }
    let pool =
      exact.isEmpty ? library.filter { $0.name.lowercased().contains(q.lowercased()) } : exact
    if pool.isEmpty {
      return .failure(
        PianoRollError.bad("no loop called `\(q)` in the library (dj_stock_loops list query=…)"))
    }
    if pool.count == 1 { return .success(pool[0]) }
    // several: the nearest tempo if that settles it, else ask
    if let bpm {
      let sorted = pool.sorted { abs($0.bpm - bpm) < abs($1.bpm - bpm) }
      if abs(sorted[0].bpm - bpm) + 0.5 < abs(sorted[1].bpm - bpm) { return .success(sorted[0]) }
    }
    let names = pool.prefix(6).map { "\($0.name) (\($0.pack))" }.joined(separator: "; ")
    return .failure(
      PianoRollError.bad(
        "`\(q)` matches \(pool.count) loops: \(names): use the full name or the path"))
  }
}

// MARK: - the live layer list (what a deck is performing)

/// A library sound a layer plays: enough to launch it and to describe it.
public struct LayerLoop: Equatable, Sendable, Hashable {
  public var path: String
  public var name: String
  public var category: String
  public var beats: Int

  public init(path: String, name: String, category: String = "", beats: Int = 16) {
    self.path = path
    self.name = name
    self.category = category
    self.beats = beats
  }

  public init(_ l: StockLoop) {
    self.init(path: l.path, name: l.name, category: l.category, beats: l.beats)
  }

  /// One pass of the loop in bars (at least 1).
  public var bars: Int { max(1, (beats + 3) / 4) }
}

/// One window of one loop on a deck's layer list: the loop is on from bar `start` for `length` bars.
/// A track's `loopLayers` expand into these at load; Wander adds, swaps and removes them as it walks
/// (`WanderAction.layers`), and `LayerRunner` follows the list.
public struct LayerEntry: Equatable, Sendable {
  public var loop: LayerLoop
  public var start: Int  // 1-based bar
  public var length: Int
  public var gainDB: Double
  public var keyLock: Bool
  /// The bar after the last one it is on.
  public var end: Int { start + length }

  public init(loop: LayerLoop, start: Int, length: Int, gainDB: Double = -3, keyLock: Bool = true) {
    self.loop = loop
    self.start = start
    self.length = max(1, length)
    self.gainDB = gainDB
    self.keyLock = keyLock
  }
}

extension LoopLayers {
  /// A track's layers as windows: each start of each layer is one entry (`length`: the layer's, else
  /// one pass of the loop).
  public static func entries(from specs: [LoopLayerSpec]) -> [LayerEntry] {
    specs.flatMap { s -> [LayerEntry] in
      let loop = LayerLoop(
        path: s.loop,
        name: s.name ?? URL(fileURLWithPath: s.loop).deletingPathExtension().lastPathComponent,
        category: s.category ?? "", beats: s.beats ?? 16)
      return s.bars.map {
        LayerEntry(
          loop: loop, start: $0, length: s.length ?? loop.bars, gainDB: s.gainDB, keyLock: s.keyLock
        )
      }
    }.sorted { ($0.start, $0.loop.path) < ($1.start, $1.loop.path) }
  }

  /// The categories Wander and the agent draw layers from: sounds that sit over a track, not drums.
  public static let layerCategories: Set<String> = ["Vocals", "Sound Effect", "Texture/Atmosphere"]

  /// How loud a layer from `category` goes in under the track.
  public static func defaultGain(category: String) -> Double {
    switch category {
    case "Sound Effect": -6
    default: -9
    }
  }

  /// The library loops that could go over a track at `bpm` in `key` ("A minor", nil = unknown): the
  /// layer categories, a tempo that matches at 1×, ½× or 2× within 8 %, and for a tonal loop a key
  /// that is the track's, its relative or a fifth away (a loop with no key goes anywhere; with the
  /// track's key unknown only keyless loops are offered). A deterministic sample of at most `limit`
  /// (by a hash of the path), by name: the pool Wander draws its layer moves from.
  public static func pool(library: [StockLoop], bpm: Double, key: String?, limit: Int = 400)
    -> [LayerLoop]
  {
    guard bpm > 0 else { return [] }
    let ok = library.filter { l in
      guard layerCategories.contains(l.category), l.bpm > 0 else { return false }
      guard [1.0, 0.5, 2.0].contains(where: { abs(l.bpm * $0 / bpm - 1) <= 0.08 }) else {
        return false
      }
      guard let lk = l.key, !lk.isEmpty else { return true }
      guard let key else { return false }
      return keysNear(loopKey: lk, trackKey: key)
    }
    func hash(_ s: String) -> UInt64 {
      var h: UInt64 = 0xcbf2_9ce4_8422_2325
      for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x100_0000_01b3
      }
      return h
    }
    let sampled =
      ok.count <= limit ? ok : Array(ok.sorted { hash($0.path) < hash($1.path) }.prefix(limit))
    return sampled.sorted { ($0.name, $0.path) < ($1.name, $1.path) }.map(LayerLoop.init)
  }

  /// A loop's tonic (mode unknown: it may be major or minor) against the track's key: within a fifth.
  static func keysNear(loopKey: String, trackKey: String) -> Bool {
    for mode in ["major", "minor"] {
      if let d = SetPlanner.keyDistance(loopKey + " " + mode, trackKey), d <= 1 { return true }
    }
    return false
  }
}
