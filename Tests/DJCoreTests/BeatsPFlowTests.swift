import Testing

@testable import DJCore

// Oracle: beats' pflow.js, via scripts/beats-parity.mjs (`make fixtures-beats`).

private func fixture(_ name: String) throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText(name))
}

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

/// null in the fixture stands for NaN (JSON.stringify turned it into null).
private func num(_ v: JSONValue?) -> Double { v?.double ?? .nan }

struct PFlowEdgeDocTests {
  @Test func parseSerializeAndCanonicalizeMatchJS() throws {
    let rows = try #require(fixture("pflow")["docs"]?.array)
    #expect(rows.count == 7)
    for (i, row) in rows.enumerated() {
      let project = Project(json: row["doc"]!)
      #expect(
        project.toJSON().jsStringified == row["projectToJSON"]!.string!, "projectToJSON doc \(i)")
      #expect(project.canonicalJSON == row["canonical"]!.string!, "canonical doc \(i)")
      #expect(project.modelCID == row["modelCID"]!.string!, "modelCID doc \(i)")

      var stamped = Project(json: row["doc"]!)
      stamped.stampDurationSteps()
      #expect(
        stamped.toJSON().jsStringified == row["stampedProjectToJSON"]!.string!, "stamped doc \(i)")
      #expect(stamped.modelCID == row["stampedModelCID"]!.string!, "stamped CID doc \(i)")
      var again = stamped
      again.stampDurationSteps()  // idempotent
      #expect(again.modelCID == stamped.modelCID)
    }
  }
}

struct PFlowGeneratedTests {
  /// compose() output, serialized by JS projectToJSON: Swift must parse it, reproduce
  /// the same document bytes, and reach the same model CID the composed object had.
  @Test func composerOutputRoundTripsToTheSameModelCID() throws {
    let rows = try #require(fixture("pflow")["generated"]?.array)
    #expect(rows.count == 40)
    for row in rows {
      let tag =
        "\(row["genre"]!.string!)/\(row["seed"]!.double!)/\(row["structure"]!.string!)/\(row["cohesion"]!.string!)"
      let doc = row["doc"]!
      #expect(sha(doc.jsStringified) == row["docSha"]!.string!, "doc \(tag)")
      let project = Project(json: doc)
      #expect(
        sha(project.toJSON().jsStringified) == row["roundTripSha"]!.string!, "roundtrip \(tag)")
      #expect(project.modelCID == row["modelCID"]!.string!, "modelCID \(tag)")
      #expect(project.modelCID == row["viaCompose"]!.string!, "viaCompose \(tag)")
    }
  }

  /// The same CIDs are in projects.json (2.2), keyed by what the composer was given.
  @Test func agreesWithTheProjectFixturesFrom22() throws {
    let projects = try #require(fixture("projects")["projects"]?.array)
    var cid: [String: String] = [:]
    for p in projects {
      cid[
        "\(p["genre"]!.string!)/\(p["seed"]!.double!)/\(p["structure"]!.string!)/\(p["cohesion"]!.string!)"
      ] =
        p["modelCID"]!.string!
    }
    for row in try #require(fixture("pflow")["generated"]?.array) {
      let tag =
        "\(row["genre"]!.string!)/\(row["seed"]!.double!)/\(row["structure"]!.string!)/\(row["cohesion"]!.string!)"
      #expect(Project(json: row["doc"]!).modelCID == cid[tag], "\(tag)")
    }
  }
}

struct PFlowDurationTests {
  @Test func stepsFromMs() throws {
    let rows = try #require(fixture("pflow")["durations"]?.array)
    #expect(rows.count > 100)
    for r in rows {
      let ms = num(r["ms"])
      let bpm = num(r["bpm"])
      #expect(
        durationStepsFromMs(ms, bpm: bpm) == Int(r["steps"]!.double!), "ms \(ms) bpm \(bpm)")
    }
  }

  @Test func resolveMs() throws {
    let rows = try #require(fixture("pflow")["resolves"]?.array)
    for r in rows {
      let midi = r["midi"]
      if midi == .null {  // JS: `if (!midi) return 0` — Swift callers hold a binding or none
        #expect(r["ms"]!.double! == 0)
        continue
      }
      let ms = resolveDurationMs(
        durationSteps: midi?["durationSteps"]?.double, duration: midi?["duration"]?.double,
        bpm: num(r["bpm"]))
      #expect(ms == r["ms"]!.double!, "\(midi?.jsStringified ?? "null") bpm \(num(r["bpm"]))")
    }
  }

  @Test func jsRoundTiesGoUp() {
    #expect(jsRound(2.5) == 3)
    #expect(jsRound(-2.5) == -2)
    #expect(jsRound(-0.5) == 0)
    #expect(jsRound(0.49999999999999994) == 0)
  }
}
