import Testing

@testable import DJCore

// The 2.4 gate: Swift compose() must reproduce beats' project for the same
// (genre, overrides) — canonical model bytes, model CID, and the full serialized
// document (tracks, generator params, structure included).

private func fixture(_ name: String) throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText(name))
}

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

private struct Mismatch: CustomStringConvertible {
  var tag: String
  var what: String
  var description: String { "\(tag): \(what)" }
}

private func check(
  _ tag: String, _ project: Project, expectBytes: Int, modelCID: String, docSha: String
) -> [Mismatch] {
  var out: [Mismatch] = []
  let canonical = project.canonicalJSON
  if canonical.utf8.count != expectBytes {
    out.append(
      Mismatch(tag: tag, what: "canonical bytes \(canonical.utf8.count) != \(expectBytes)"))
  }
  if sha(canonical) != modelCID { out.append(Mismatch(tag: tag, what: "model CID")) }
  if sha(project.toJSON().jsStringified) != docSha {
    out.append(Mismatch(tag: tag, what: "document"))
  }
  return out
}

struct ComposerGateTests {
  /// The gate has to be able to fail: a different seed must not satisfy a fixture.
  @Test func gateRejectsADifferentSeed() throws {
    let row = try #require(fixture("projects")["projects"]?.array?.first)
    var ov = JSONObject()
    ov["seed"] = .number(row["seed"]!.double! + 1)
    ov["cohesion"] = row["cohesion"]!
    let project = compose(genre: row["genre"]!.string!, overrides: .object(ov))
    #expect(project.modelCID != row["modelCID"]!.string!)
  }

  @Test func matrixMatchesBeats() throws {
    let rows = try #require(fixture("projects")["projects"]?.array)
    #expect(rows.count == 304)
    var bad: [Mismatch] = []
    for row in rows {
      let genre = row["genre"]!.string!
      let size = row["structure"]!.string!
      var ov = JSONObject()
      ov["seed"] = row["seed"]!
      ov["cohesion"] = row["cohesion"]!
      if size != "loop" { ov["structure"] = .string(size) }
      let tag = "\(genre)/\(row["seed"]!.double!)/\(size)/\(row["cohesion"]!.string!)"
      let project = compose(genre: genre, overrides: .object(ov))
      bad += check(
        tag, project, expectBytes: Int(row["canonicalBytes"]!.double!),
        modelCID: row["modelCID"]!.string!, docSha: row["docSha"]!.string!)
      #expect(project.name == row["name"]!.string!, "\(tag) name")
    }
    #expect(bad.isEmpty, "\(bad.count) mismatches; first: \(bad.prefix(12).map(\.description))")
  }

  @Test func overrideVariationsMatchBeats() throws {
    let rows = try #require(fixture("compose")["cases"]?.array)
    var bad: [Mismatch] = []
    for row in rows {
      let genre = row["genre"]!.string!
      let ov = row["overrides"]!
      let tag = "\(genre) \(ov.jsStringified)"
      let project = compose(genre: genre, overrides: ov)
      bad += check(
        tag, project, expectBytes: Int(row["canonicalBytes"]!.double!),
        modelCID: row["modelCID"]!.string!, docSha: row["docSha"]!.string!)
    }
    #expect(
      bad.isEmpty,
      "\(bad.count)/\(rows.count) mismatches; first: \(bad.prefix(12).map(\.description))")
  }
}

// MARK: - Module vectors (modules.json)

private func json(_ cell: MotifCell) -> JSONValue {
  .object(
    JSONObject([
      ("degrees", .array(cell.degrees.map { .int($0) })),
      ("mask", .array(cell.mask.map { .bool($0) })), ("contour", .int(cell.contour)),
    ]))
}

private func json(_ t: SongTemplate) -> JSONValue {
  .object(
    JSONObject([
      ("name", .string(t.name)),
      (
        "sections",
        .array(
          t.sections.map { s in
            var phrases = JSONObject()
            for (k, v) in s.phrases.pairs { phrases[k] = .array(v.map { .string($0) }) }
            var active = JSONObject()
            for k in s.active.keys { active[k] = .bool(true) }
            return .object(
              JSONObject([
                ("name", .string(s.name)), ("steps", .int(s.steps)), ("active", .object(active)),
                ("phrases", .object(phrases)),
              ]))
          })
      ),
      ("slotMap", .object(JSONObject())),
    ]))
}

struct ModuleVectorTests {
  @Test func bjorklundMatches() throws {
    for row in try #require(fixture("modules")["bjorklund"]?.array) {
      let k = row["k"]!.int!
      let n = row["n"]!.int!
      #expect(bjorklund(k, n) == row["bits"]!.ints!, "bjorklund(\(k), \(n))")
    }
  }

  @Test func generateStructureMatches() throws {
    let rows = try #require(fixture("modules")["structures"]?.array)
    #expect(rows.count == 19 * 8 * 2)
    for row in rows {
      var rng = Mulberry32(seed: row["seed"]!.double!)
      let t = generateStructure(
        genre: row["genre"]!.string!, size: row["size"]!.string!, rng: &rng)
      #expect(
        json(t).jsStringified == row["result"]!.jsStringified,
        "\(row["genre"]!.string!) \(row["size"]!.string!) seed \(row["seed"]!.double!)")
    }
  }

  @Test func trackThemesMatch() throws {
    for row in try #require(fixture("modules")["themes"]?.array) {
      let genre = row["genre"]!.string!
      let seed = row["seed"]!.double!
      #expect(cohesionGenreSupported(genre) == row["supported"]!.bool!)
      let theme = buildTrackTheme(genre: genre, seed: seed)
      let want = row["theme"]!
      #expect(json(theme.motif).jsStringified == want["motif"]!.jsStringified, "\(genre) \(seed)")
      #expect(theme.plan.stepsPerChord == want["plan"]!["stepsPerChord"]!.int!)
      #expect(
        JSONValue.array(theme.plan.chords.map(\.json)).jsStringified
          == want["plan"]!["chords"]!.jsStringified, "\(genre) \(seed) chords")
      #expect(theme.groove == want["groove"]!.int!)
    }
  }

  @Test func renderMotifMatches() throws {
    let themes = try #require(fixture("modules")["themes"]?.array)
    for row in try #require(fixture("modules")["motifs"]?.array) {
      let genre = row["genre"]!.string!
      let src = themes.first { $0["genre"]!.string! == genre && $0["seed"]!.double! == 42 }!
      let theme = buildTrackTheme(genre: genre, seed: 42)
      _ = src
      let out = renderMotif(
        theme.motif, mode: row["mode"]!.int!, harmonicOffset: row["offset"]!.int!)
      #expect(
        json(out).jsStringified == row["out"]!.jsStringified,
        "\(genre) mode \(row["mode"]!.int!) off \(row["offset"]!.int!)")
    }
  }
}
