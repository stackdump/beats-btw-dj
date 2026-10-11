import Testing

@testable import DJCore

// ROADMAP 2.8 gate: arrangeWithOpts, the overlay directives and the share overrides must
// reproduce beats' JS exactly — project node count, canonical model bytes, model CID and the
// full serialized document — on fixtures written by scripts/beats-arrange.mjs from the real JS.
// A fixture whose JS run threw (`result.error`) must make the Swift throw too.
//
// Debugging a mismatch: the message names the case as `<section>:<index>`.
//   node scripts/beats-arrange.mjs --dump arranges:12 > /tmp/js.json
//   DJ_ARRANGE_DUMP=/tmp make swift-test-filter FILTER=Arrange   # writes arranges-12.swift.json
// Both files are the bytes behind `docSha` (JSON.stringify(projectToJSON(…))); pretty-print
// and diff them.

private func fixture() throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText("arrange"))
}

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

/// The JS script's `digest`: node count, canonical bytes / CID and the serialized document.
/// (The script parses its plain control nets first; Swift's arrange output is already parsed.)
private struct Digest: Equatable, CustomStringConvertible {
  var nets: Int
  var counter: Int
  var bytes: Int
  var cid: String
  var doc: String
  var description: String { "nets \(nets) counter \(counter) bytes \(bytes) cid \(cid.prefix(8))" }

  init(_ project: Project) {
    let parsed = project
    nets = parsed.nets.count
    counter = parsed.nets.keys.filter { $0.hasPrefix("counter-melody-") }.count
    let canonical = parsed.canonicalJSON
    bytes = canonical.utf8.count
    cid = sha(canonical)
    doc = sha(parsed.toJSON().jsStringified)
  }

  init(expected r: JSONValue) {
    nets = Int(r["nets"]!.double!)
    counter = Int(r["counter"]!.double!)
    bytes = Int(r["canonicalBytes"]!.double!)
    cid = r["modelCID"]!.string!
    doc = r["docSha"]!.string!
  }
}

private func composeBase(genre: String, seed: Double, structure: String, cohesion: String)
  -> Project
{
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  ov["cohesion"] = .string(cohesion)
  if !structure.isEmpty { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

/// Composing is the slow part; the fixtures reuse a few hundred bases.
private final class BaseCache: @unchecked Sendable {
  var cache: [String: Project] = [:]
  func base(_ genre: String, _ seed: Double, _ structure: String, _ cohesion: String) -> Project {
    let key = "\(genre)/\(seed)/\(structure)/\(cohesion)"
    if let p = cache[key] { return p }
    let p = composeBase(genre: genre, seed: seed, structure: structure, cohesion: cohesion)
    cache[key] = p
    return p
  }
}

/// `wireOf` in the script: the unparsed document the share path hands to arrange.
private func wireDoc(_ p: Project, withMutes: Bool) -> JSONValue {
  var o = JSONObject()
  o["name"] = .string(p.name)
  o["tempo"] = .number(p.tempo)
  o["swing"] = .number(p.swing)
  o["humanize"] = .number(p.humanize)
  o["nets"] = p.toJSON()["nets"]!
  if withMutes { o["initialMutes"] = .array(p.initialMutes.map { .string($0) }) }
  return .object(o)
}

private let chunks = 8

/// The rows of one chunk, with their index in the fixture section.
private func slice(_ rows: [JSONValue], _ chunk: Int) -> [(index: Int, row: JSONValue)] {
  rows.enumerated().filter { $0.offset % chunks == chunk }.map { ($0.offset, $0.element) }
}

struct ArrangeTableTests {
  @Test func tablesMatchTheJSSource() throws {
    let want = try #require(fixture()["tables"])
    #expect(ArrangeTables.json.jsStringified == want.jsStringified)
  }

  /// JS toFixed rounds the exact binary value half up; printf rounds exact ties to even.
  @Test func toFixedSixMatchesJS() {
    let cases: [(Double, String)] = [
      (0.0078125, "0.007813"), (0.5, "0.500000"), (0.7, "0.700000"), (0, "0.000000"),
      (1, "1.000000"), (0.9999995, "1.000000"), (0.0000005, "0.000000"), (5e-7, "0.000000"),
      (-5e-7, "-0.000000"), (0.0000015, "0.000002"), (0.1250005, "0.125000"),
      (123456.0078125, "123456.007813"),
      (0.1234565, "0.123456"), (0.123456789, "0.123457"), (0.33333333, "0.333333"),
      (7, "7.000000"), (-0.25, "-0.250000"), (0.0000004, "0.000000"), (1e21, "1e+21"),
      (0.99999951, "1.000000"), (0.015625, "0.015625"), (0.0234375, "0.023438"),
    ]
    for (x, want) in cases { #expect(jsToFixed6(x) == want, "\(x)") }
  }

  /// The fixtures have to reach every directive in every genre, for both cohesion engines,
  /// with the JS completing (a counter-melody case must also add a net), and the interesting
  /// JS throws.
  @Test func fixturesCoverTheDirectives() throws {
    let f = try fixture()
    #expect(f["meta"]?["beatsCommit"]?.string?.hasPrefix("668978e") == true)
    let overlays = try #require(f["overlays"]?.array)
    let arranges = try #require(f["arranges"]?.array)
    func completes(_ r: JSONValue, _ key: String) -> Bool {
      r["opts"]?[key] != nil && r["result"]!["error"] == nil
        && (key != "counterMelody" || (r["result"]!["counter"]?.double ?? 0) > 0)
    }
    let overlayKeys = ["fadeIn", "drumBreak", "feelCurve", "macroCurve", "counterMelody"]
    for genre in Set(overlays.map { $0["genre"]!.string! }) {
      for cohesion in ["v1", "v2"] {
        let rows = overlays.filter {
          $0["genre"]!.string! == genre && $0["cohesion"]!.string! == cohesion
        }
        for key in overlayKeys {
          #expect(rows.contains { completes($0, key) }, "overlay \(key) \(genre)/\(cohesion)")
        }
      }
    }
    #expect(Set(overlays.map { $0["genre"]!.string! }).count == 8)
    let arrangeKeys = overlayKeys + ["velocityDeltas", "maxVariants", "sections"]
    for genre in Set(arranges.map { $0["source"]!["genre"]!.string! }) {
      for cohesion in ["v1", "v2"] {
        for form in ["parsed", "wire"] {
          let rows = arranges.filter {
            $0["source"]!["genre"]!.string! == genre
              && $0["source"]!["cohesion"]!.string! == cohesion
              && $0["form"]!.string! == form
          }
          // A counter-melody on wire input always throws in JS (plain nets): parsed only.
          for key in arrangeKeys where form == "parsed" || key != "counterMelody" {
            #expect(
              rows.contains { completes($0, key) }, "arrange \(key) \(genre)/\(cohesion)/\(form)")
          }
        }
      }
    }
    #expect(Set(arranges.map { $0["source"]!["genre"]!.string! }).count == 6)
    // The JS throws are part of the oracle: each kind is represented.
    let errors = Set(
      (overlays + arranges).compactMap { $0["result"]!["error"]?.string })
    for e in [
      "nb.resetState is not a function", "Cannot read properties of undefined (reading 'map')",
      "Cannot read properties of null (reading 'active')",
      "Cannot read properties of null (reading 'length')",
      "Cannot read properties of null (reading 'section')",
    ] {
      #expect(errors.contains(e), "\(e)")
    }
    #expect(arranges.filter { $0["result"]!["error"] != nil }.count >= 10)
    #expect(
      Set(arranges.map { $0["size"]!.string! }).isSuperset(of: [
        "minimal", "standard", "extended", "ab", "drop", "build", "jam", "", "bogus", "constructor",
      ]))
    #expect(Set(arranges.map { $0["form"]!.string! }) == ["parsed", "wire"])
  }

  @Test func counterSeedIsFnv32a() {
    // fnv32a("") and ("a"), the standard vectors.
    #expect(counterSeed([""]) == 0x811c_9dc5)
    #expect(counterSeed(["a"]) == 0xe40c_292c)
    #expect(counterSeed(["foo", "bar"]) == counterSeed(["foobar"]))
  }
}

struct ArrangeOverlayTests {
  @Test(arguments: 0..<chunks) func overlaysMatchBeats(chunk: Int) throws {
    let all = try #require(fixture()["overlays"]?.array)
    #expect(all.count >= 150)
    let rows = slice(all, chunk)
    let cache = BaseCache()
    var bad: [String] = []
    var threw = 0
    for (index, row) in rows {
      let tag =
        "overlays:\(index) \(row["genre"]!.string!)/\(row["seed"]!.double!)/"
        + "\(row["structure"]!.string!)/\(row["cohesion"]!.string!) \(row["opts"]!.jsStringified)"
      var proj = cache.base(
        row["genre"]!.string!, row["seed"]!.double!, row["structure"]!.string!,
        row["cohesion"]!.string!)
      var opts = ArrangeOpts(json: row["opts"]!)
      opts.overlayOnly = true
      let before = row["noop"] != nil ? Digest(proj) : nil
      do {
        try arrangeWithOpts(&proj, genre: row["genre"]!.string!, size: "", opts: opts)
        if row["result"]!["error"] != nil {
          bad.append("\(tag): expected a throw")
          continue
        }
        let got = Digest(proj)
        let want = Digest(expected: row["result"]!)
        if got != want {
          bad.append("\(tag): \(got) != \(want)")
          dumpSwiftDocument("overlays", index, proj)
        }
        if let noop = row["noop"]?.string {
          if got.cid != noop || got != before! {
            bad.append("\(tag): overlay on a loop must be a no-op")
          }
        }
      } catch {
        threw += 1
        if row["result"]!["error"] == nil { bad.append("\(tag): threw \(error)") }
      }
    }
    #expect(bad.isEmpty, "\(bad.count)/\(rows.count) mismatches; first: \(bad.prefix(6))")
    _ = threw
  }

  /// In the browser `el._project` is plain JSON, where the JS counterMelody throws.
  @Test func counterMelodyThrowsOnUnparsedNets() throws {
    let probes = try #require(fixture()["wireProbe"]?.array)
    #expect(!probes.isEmpty)
    for p in probes {
      #expect(p["error"]?.string == "nb.resetState is not a function")
      let base = composeBase(
        genre: p["genre"]!.string!, seed: p["seed"]!.double!, structure: "standard",
        cohesion: "v2")
      var proj = Project(wireJSON: wireDoc(base, withMutes: false))
      proj.structure = base.structure
      var opts = ArrangeOpts()
      opts.overlayOnly = true
      opts.wireForm = true
      opts.counterMelody = [
        .object(
          JSONObject([("section", .string(base.structure[0].name)), ("mode", .string("answer"))]))
      ]
      var thrown: Error?
      do {
        try arrangeWithOpts(&proj, genre: p["genre"]!.string!, size: "", opts: opts)
      } catch {
        thrown = error
      }
      #expect(thrown is ArrangeError)
    }
  }
}

struct ArrangeFullTests {
  @Test(arguments: 0..<chunks) func arrangeWithOptsMatchesBeats(chunk: Int) throws {
    let all = try #require(fixture()["arranges"]?.array)
    #expect(all.count >= 150)
    let rows = slice(all, chunk)
    let cache = BaseCache()
    var bad: [String] = []
    for (index, row) in rows {
      let src = row["source"]!
      let genre = src["genre"]!.string!
      let base = cache.base(genre, src["seed"]!.double!, "", src["cohesion"]!.string!)
      let wire = row["form"]!.string! == "wire"
      var proj = wire ? Project(wireJSON: wireDoc(base, withMutes: true)) : base
      var opts = ArrangeOpts(json: row["opts"]!)
      opts.wireForm = wire
      // A row may arrange under another genre name than the one it composed.
      let arrangeGenre = row["genre"]?.string ?? genre
      let tag =
        "arranges:\(index) \(genre)/\(src["seed"]!.double!)/\(arrangeGenre)/\(row["size"]!.string!)/"
        + "\(row["form"]!.string!) \(row["opts"]!.jsStringified)"
      do {
        try arrangeWithOpts(&proj, genre: arrangeGenre, size: row["size"]!.string!, opts: opts)
        if row["result"]!["error"] != nil {
          bad.append("\(tag): expected a throw")
          continue
        }
        let got = Digest(proj)
        let want = Digest(expected: row["result"]!)
        if got != want {
          bad.append("\(tag): \(got) != \(want)")
          dumpSwiftDocument("arranges", index, proj)
        }
      } catch {
        if row["result"]!["error"] == nil { bad.append("\(tag): threw \(error)") }
      }
    }
    #expect(bad.isEmpty, "\(bad.count)/\(rows.count) mismatches; first: \(bad.prefix(6))")
  }

  /// Hand-written wire documents: omitted durations (the JS stamp skips them), sparse
  /// bindings, a stinger, velocity deltas that find nothing to tweak.
  /// (Hand C: the stamp reads the raw JSON — a fractional ms, a positive `durationSteps` the
  /// parse then drops.)
  @Test func handAuthoredDocumentsMatchBeats() throws {
    let rows = try #require(fixture()["docs"]?.array)
    #expect(rows.count == 12)
    for (index, row) in rows.enumerated() {
      var proj = Project(wireJSON: row["doc"]!)
      var opts = ArrangeOpts(json: row["opts"]!)
      opts.wireForm = true
      let tag = "docs:\(index) \(row["doc"]!["name"]!.string!) \(row["size"]!.string!)"
      #expect(row["result"]!["error"] == nil, "\(tag)")
      try arrangeWithOpts(
        &proj, genre: row["genre"]!.string!, size: row["size"]!.string!, opts: opts)
      let ok = Digest(proj) == Digest(expected: row["result"]!)
      #expect(ok, "\(tag)")
      if !ok { dumpSwiftDocument("docs", index, proj) }
    }
  }

  /// The gate must be able to fail: arranging a different source must not satisfy a fixture.
  @Test func gateRejectsADifferentSource() throws {
    let rows = try #require(fixture()["arranges"]?.array)
    let row = try #require(
      rows.first { $0["form"]!.string! == "parsed" && $0["result"]!["error"] == nil })
    let src = row["source"]!
    var proj = composeBase(
      genre: src["genre"]!.string!, seed: src["seed"]!.double! + 1, structure: "",
      cohesion: src["cohesion"]!.string!)
    try arrangeWithOpts(
      &proj, genre: src["genre"]!.string!, size: row["size"]!.string!,
      opts: ArrangeOpts(json: row["opts"]!))
    #expect(Digest(proj) != Digest(expected: row["result"]!))
  }
}

struct ShareArrangeTests {
  @Test func wholeEnvelopesBuildTheBrowsersProject() throws {
    let rows = try #require(fixture()["shares"]?.array)
    let cache = BaseCache()
    var bad: [String] = []
    var rawNets = 0
    for (index, row) in rows.enumerated() {
      var payload = row["payload"]!
      if let from = row["netsFrom"], from != .null {
        let base = cache.base(
          from["genre"]!.string!, from["seed"]!.double!, "", from["cohesion"]!.string!)
        var o = payload.object!
        o["nets"] = wireDoc(base, withMutes: false)["nets"]!
        payload = .object(o)
        rawNets += 1
      }
      let cid = row["cid"]!.string!
      let tag = "shares:\(index) \(row["payload"]!.jsStringified)"
      if BeatsCID.shareCID(payload) != cid { bad.append("\(tag): share CID") }
      let share = Share(payload: payload, cid: cid)
      guard let project = share.project() else {
        bad.append("\(tag): no project")
        continue
      }
      if row["result"]!["error"] != nil {
        bad.append("\(tag): JS threw")
        continue
      }
      let got = Digest(project)
      let want = Digest(expected: row["result"]!)
      if got != want {
        bad.append("\(tag): \(got) != \(want)")
        dumpSwiftDocument("shares", index, project)
      }
    }
    #expect(rawNets >= 10)
    #expect(bad.isEmpty, "\(bad.count)/\(rows.count) mismatches; first: \(bad.prefix(6))")
  }

  /// A deck generated from a share (`TrackSpec(share:)` → `PreparedTrack`) plays the project
  /// the envelope describes, overrides and overlay included — the JS digest — and a recorded
  /// session's payload (`TrackSpec.payload` / `init(payload:)`) replays the same project.
  @Test func decksAndSessionsPlayTheEnvelopesProject() throws {
    let rows = try #require(fixture()["shares"]?.array).filter { $0["netsFrom"] == .null }
    var layered = 0
    for (index, row) in rows.enumerated() {
      let share = Share(payload: row["payload"]!, cid: row["cid"]!.string!)
      let spec = try #require(TrackSpec(share: share))
      let tag = "composer share \(index) \(row["payload"]!.jsStringified)"
      let want = Digest(expected: row["result"]!)
      #expect(Digest(spec.project()) == want, "\(tag)")
      let back = try #require(TrackSpec(payload: spec.payload))
      #expect(back == spec, "\(tag)")
      #expect(Digest(back.project()) == want, "\(tag)")
      // The session payload is itself an envelope that reads back to the same project.
      #expect(Digest(Share(payload: spec.payload).project()!) == want, "\(tag)")
      if !spec.layers.entries.isEmpty { layered += 1 }
    }
    #expect(layered >= 10)
    // A spec without layers writes exactly the payload it always did.
    let plain = TrackSpec(
      genre: "techno", seed: 42, structure: "standard", cohesion: "v2",
      extra: JSONObject([("bpm", .number(126))]))
    #expect(
      plain.payload.jsStringified
        == #"{"genre":"techno","seed":42,"structure":"standard","cohesion":"v2","bpm":126}"#)
    #expect(TrackSpec(payload: plain.payload) == plain)
  }

  @Test func derivedNamesNeedNoCIDOrFallBackToTheSeed() {
    let withCID = Share(
      payload: .object(JSONObject([("genre", .string("house")), ("nets", .object(JSONObject()))])),
      cid: "zdj7WabcDEF")
    let noCID = Share(
      payload: .object(
        JSONObject([
          ("genre", .string("house")), ("seed", .number(77)), ("nets", .object(JSONObject())),
        ])
      ))
    #expect(withCID.derivedName.hasPrefix("house \u{00b7} "))
    #expect(noCID.derivedName == generateTrackName(genre: "house", seed: 77))
    // seed 0 / absent degenerates to 1 (mulberry32 at 0).
    let none = Share(payload: .object(JSONObject([("nets", .object(JSONObject()))])))
    #expect(none.derivedName == generateTrackName(genre: "custom", seed: 1))
  }

  @Test func overridesMatchTheRealApplyShareOverrides() throws {
    let rows = try #require(fixture()["overrides"]?.array)
    let cache = BaseCache()
    var bad: [String] = []
    var fxOnly = 0
    for (index, row) in rows.enumerated() {
      var proj = cache.base(
        row["genre"]!.string!, row["seed"]!.double!, row["structure"]!.string!,
        row["cohesion"]!.string!)
      // The envelope path filters first (shareFromPayload), so go through it.
      var payload = JSONObject()
      payload["genre"] = .string(row["genre"]!.string!)
      for (k, v) in row["ov"]!.object!.entries { payload[k] = v }
      let share = Share(payload: .object(payload))
      if let ov = share.overrides { proj.applyShareOverrides(ov) }
      let tag = "overrides:\(index) \(row["genre"]!.string!) \(row["ov"]!.jsStringified)"
      let got = Digest(proj)
      let want = Digest(expected: row["result"]!)
      if got != want {
        bad.append("\(tag): \(got) != \(want)")
        dumpSwiftDocument("overrides", index, proj)
      }
      if row["ov"]!.object!.keys == ["fx"] {
        // `fx` is slider state, not model: the document must be untouched.
        fxOnly += 1
        if got.doc != row["plain"]!.string! { bad.append("\(tag): fx changed the model") }
      }
    }
    #expect(fxOnly == 3)
    #expect(rows.count == 27)
    #expect(bad.isEmpty, "\(bad.count)/\(rows.count) mismatches; first: \(bad.prefix(6))")
  }
}
