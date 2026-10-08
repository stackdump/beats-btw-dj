import Foundation

// Typed view over Resources/beats/tables.json, which scripts/beats-tables.mjs lifts
// from beats' generator modules (genres, theory, instruments, structure, energy).

extension JSONValue {
  public var int: Int? { double.map { Int($0) } }
  public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
  public var strings: [String]? { array?.compactMap(\.string) }
  public var ints: [Int]? { array?.compactMap(\.int) }
}

/// An ordered set of roles/sections: a JS object used as a record.
public struct OrderedFlags: Equatable {
  public private(set) var keys: [String] = []
  public init() {}
  public init(_ names: [String]) { for n in names { set(n) } }
  public mutating func set(_ k: String) { if !keys.contains(k) { keys.append(k) } }
  public func contains(_ k: String) -> Bool { keys.contains(k) }
}

public struct ChordDegree: Equatable {
  public var root: Int
  public var tones: [Int]
  var json: JSONValue {
    .object(JSONObject([("root", .int(root)), ("tones", .array(tones.map { .int($0) }))]))
  }
}

/// `{ chords: [{ root, tones }], stepsPer }`
public struct ChordProg: Equatable {
  public var chords: [ChordDegree]
  public var stepsPer: Int
  init(json v: JSONValue) {
    chords = (v["chords"]?.array ?? []).map {
      ChordDegree(root: $0["root"]?.int ?? 0, tones: $0["tones"]?.ints ?? [])
    }
    stepsPer = v["stepsPer"]?.int ?? 4
  }
  init(chords: [ChordDegree], stepsPer: Int) {
    self.chords = chords
    self.stepsPer = stepsPer
  }
  var json: JSONValue {
    .object(
      JSONObject([("chords", .array(chords.map(\.json))), ("stepsPer", .int(stepsPer))]))
  }
}

public struct DrumVariant {
  public var hitsAdd: Int
  public var hitsMul: Double?
  public var rotationAdd: Int
}

public struct GenreTheory {
  public var chordProgs: [ChordProg]
  public var drumStyles: [String: [String: DrumVariant]]
  public var phrasePatterns: OrderedMap<[String]>?
}

public struct GenreDef {
  public var name: String
  public var bpm: Double
  public var scaleName: String  // e.g. "MinorScale"
  public var rootNote: Int
  public var kick: [Int]
  public var snare: [Int]
  public var hihat: [Int]
  public var melodyChannel: Int
  public var melodyDensity: Double
  public var melodyDuration: Int
  public var bassChannel: Int
  public var bassDensity: Double
  public var bassDuration: Int
  public var swing: Double
  public var humanize: Double
  public var durationVariation: Double
  public var syncopation: Double
  public var ghostNotes: Double
  public var drumFills: Bool
  public var walkingBass: Bool
  public var callResponse: Bool
  public var tensionCurve: Bool
  public var modalInterchange: Double
  public var polyrhythm: Int
  public var theory: GenreTheory?

  public func scale(_ root: Int) -> [Int] {
    scaleNotes(root, scaleIntervals(scaleName), octaves: 2)
  }
}

public struct RoleProfile {
  public var active: Bool
  public var motifMode: Int?
  public var registerShift: Int?
}

public struct SectionProfile {
  public var roles: OrderedMap<RoleProfile>
  public var filterOpen: Double
  public var energy: Double
}

public struct StingerSpec {
  public var id: String
  public var channel: Int
  public var defaultInstrument: String
}

public final class BeatsTables: @unchecked Sendable {
  public static let shared: BeatsTables = {
    do { return try BeatsTables(json: .parse(try loadText())) } catch {
      fatalError("beats tables: \(error)")
    }
  }()

  static func loadText() throws -> String {
    // In DJApp.app the tables sit in Contents/Resources/beats (scripts/bundle-app.sh).
    guard
      let url = Bundle.main.url(forResource: "tables", withExtension: "json", subdirectory: "beats")
        ?? Bundle.module.url(forResource: "tables", withExtension: "json", subdirectory: "beats")
    else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "beats/tables.json"]) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  public let genreIDs: [String]
  public let genres: [String: GenreDef]
  public let instrumentSets: [String: OrderedMap<[String]>]
  public let minorChordProg: ChordProg
  public let majorChordProg: ChordProg
  let themes: [String: ThemeTable]
  let archetypes: JSONValue
  let archetypesByFamily: JSONValue
  let genreFamilies: [String: Int]
  let blueprints: JSONValue
  public let stingerSpecs: [StingerSpec]
  public let stingerInstrumentSet: [String]
  let fallbackSets: JSONValue
  public let adjectives: [String]
  public let nouns: [String]
  public let grooves: [String: Int]
  public let motifModes: [String: Int]

  struct ThemeTable {
    var family: String
    var groove: Int
    var supported: Bool
    var energy: OrderedMap<SectionProfile>
  }

  init(json t: JSONValue) throws {
    func theory(_ v: JSONValue?) -> GenreTheory? {
      guard let v else { return nil }
      var styles: [String: [String: DrumVariant]] = [:]
      for (role, vs) in v["drumStyles"]?.object?.entries ?? [] {
        var m: [String: DrumVariant] = [:]
        for (letter, d) in vs.object?.entries ?? [] {
          m[letter] = DrumVariant(
            hitsAdd: d["hitsAdd"]?.int ?? 0, hitsMul: d["hitsMul"]?.double,
            rotationAdd: d["rotationAdd"]?.int ?? 0)
        }
        styles[role] = m
      }
      var phrases: OrderedMap<[String]>?
      if let pp = v["phrasePatterns"]?.object {
        phrases = OrderedMap()
        for (k, a) in pp.entries { phrases![k] = a.strings ?? [] }
      }
      return GenreTheory(
        chordProgs: (v["chordProgs"]?.array ?? []).map { ChordProg(json: $0) },
        drumStyles: styles, phrasePatterns: phrases)
    }
    let theories = t["theories"]
    var defs: [String: GenreDef] = [:]
    var ids: [String] = []
    for (id, g) in t["genres"]?.object?.entries ?? [] {
      ids.append(id)
      func d(_ k: String, _ def: Double = 0) -> Double { g[k]?.double ?? def }
      func i(_ k: String, _ def: Int = 0) -> Int { g[k]?.int ?? def }
      func b(_ k: String) -> Bool { g[k]?.bool ?? false }
      defs[id] = GenreDef(
        name: g["name"]?.string ?? id, bpm: d("bpm"), scaleName: g["scale"]?.string ?? "MajorScale",
        rootNote: i("rootNote"), kick: g["kick"]?.ints ?? [], snare: g["snare"]?.ints ?? [],
        hihat: g["hihat"]?.ints ?? [], melodyChannel: i("melodyChannel"),
        melodyDensity: d("melodyDensity"), melodyDuration: i("melodyDuration"),
        bassChannel: i("bassChannel"), bassDensity: d("bassDensity"),
        bassDuration: i("bassDuration"),
        swing: d("swing"), humanize: d("humanize"), durationVariation: d("durationVariation"),
        syncopation: d("syncopation"), ghostNotes: d("ghostNotes"), drumFills: b("drumFills"),
        walkingBass: b("walkingBass"), callResponse: b("callResponse"),
        tensionCurve: b("tensionCurve"), modalInterchange: d("modalInterchange"),
        polyrhythm: i("polyrhythm"), theory: theory(theories?[id]))
    }
    genreIDs = ids
    genres = defs

    var sets: [String: OrderedMap<[String]>] = [:]
    for (id, s) in t["instrumentSets"]?.object?.entries ?? [] {
      var m = OrderedMap<[String]>()
      for (role, a) in s.object?.entries ?? [] { m[role] = a.strings ?? [] }
      sets[id] = m
    }
    instrumentSets = sets
    minorChordProg = ChordProg(json: t["minorChordProg"] ?? .null)
    majorChordProg = ChordProg(json: t["majorChordProg"] ?? .null)

    var th: [String: ThemeTable] = [:]
    for (id, v) in t["themes"]?.object?.entries ?? [] {
      var energy = OrderedMap<SectionProfile>()
      for (sec, p) in v["energy"]?.object?.entries ?? [] {
        var roles = OrderedMap<RoleProfile>()
        for (role, rp) in p["roles"]?.object?.entries ?? [] {
          roles[role] = RoleProfile(
            active: rp["active"]?.bool ?? false, motifMode: rp["motifMode"]?.int,
            registerShift: rp["registerShift"]?.int)
        }
        energy[sec] = SectionProfile(
          roles: roles, filterOpen: p["filterOpen"]?.double ?? 0, energy: p["energy"]?.double ?? 0)
      }
      th[id] = ThemeTable(
        family: v["family"]?.string ?? "edm", groove: v["groove"]?.int ?? 0,
        supported: v["supported"]?.bool ?? false, energy: energy)
    }
    themes = th

    let s = t["structure"]
    archetypes = s?["sectionArchetypes"] ?? .null
    archetypesByFamily = s?["sectionArchetypesByFamily"] ?? .null
    var fam: [String: Int] = [:]
    for (k, v) in s?["genreFamilies"]?.object?.entries ?? [] { fam[k] = v.int ?? 1 }
    genreFamilies = fam
    blueprints = s?["structureBlueprints"] ?? .null

    stingerSpecs = (t["stingers"]?["STINGER_SPECS"]?.array ?? []).map {
      StingerSpec(
        id: $0["id"]?.string ?? "", channel: $0["channel"]?.int ?? 0,
        defaultInstrument: $0["defaultInstrument"]?.string ?? "")
    }
    stingerInstrumentSet = t["stingers"]?["STINGER_INSTRUMENT_SET"]?.strings ?? []
    fallbackSets = t["stingers"]?["FALLBACK_SETS"] ?? .null
    adjectives = t["nameWords"]?["adjectives"]?.strings ?? []
    nouns = t["nameWords"]?["nouns"]?.strings ?? []
    var g: [String: Int] = [:]
    for (k, v) in t["grooves"]?.object?.entries ?? [] { g[k] = v.int ?? 0 }
    grooves = g
    var mm: [String: Int] = [:]
    for (k, v) in t["motifModes"]?.object?.entries ?? [] { mm[k] = v.int ?? 0 }
    motifModes = mm
  }

  // MARK: queries

  func themeTable(_ genre: String) -> ThemeTable? { themes[genre] }

  /// structure.js `archetypeFor(family, name)` — nil when the section has no archetype.
  func archetype(family: Int, name: String) -> OrderedFlags? {
    let fam = archetypesByFamily[String(family)]?[name] ?? archetypes[name]
    guard let o = fam?.object else { return nil }
    return OrderedFlags(o.keys)
  }

  func blueprints(family: Int, size: String) -> [[String]]? {
    blueprints[String(family)]?[size]?.array?.map { $0.strings ?? [] }
  }

  func family(of genre: String) -> Int { genreFamilies[genre] ?? 1 }

  /// FALLBACK_SETS[group] — nil when absent or null.
  func fallbackSet(_ group: String) -> [String]? { fallbackSets[group]?.strings }
}
