import Testing

@testable import DJCore

// Second oracle (ROADMAP 2.7). go.json holds what beats' *Go* generator produced for
// every case the JS fixtures cover (scripts/beats-go-oracle.mjs). Findings baked into
// the fixture, and why these tests are shaped the way they are:
//
//  * Go and JS do not agree end to end. Go gives every drum voice MIDI channel 10 (JS:
//    kick 10, snare 11, hihat 12, clap 13) and draws from math/rand where JS uses
//    mulberry32 / the variety.js LCG, so every RNG-driven net differs.
//  * What does agree — kick, stingers, the cohesion-v2 bass/melody/harmony/arp nets in
//    most genres, whole projects for some genres — is a three-way check: Swift must
//    equal Go wherever Go equals JS.
//
// Swift follows the JS (what shipped share links were built with); `ComposerGateTests`
// already pins Swift to JS byte for byte. These tests add Go as an independent witness.

private func fixture() throws -> JSONValue { try JSONValue.parse(try beatsFixtureText("go")) }

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

/// Go's view of drum voices: MIDI channels 10–15 collapse to 10.
private func drumChannelsTo10(_ v: JSONValue) -> JSONValue {
  guard case .object(var doc) = v, case .object(var nets)? = doc["nets"] else { return v }
  for (id, net) in nets.entries {
    guard case .object(var n) = net, case .object(var trans)? = n["transitions"] else { continue }
    for (tid, t) in trans.entries {
      guard case .object(var to) = t, case .object(var midi)? = to["midi"],
        let ch = midi["channel"]?.int, ch >= 10, ch <= 15
      else { continue }
      midi["channel"] = .int(10)
      to["midi"] = .object(midi)
      trans[tid] = .object(to)
    }
    n["transitions"] = .object(trans)
    nets[id] = .object(n)
  }
  doc["nets"] = .object(nets)
  return .object(doc)
}

private func swiftProject(_ row: JSONValue) -> Project {
  compose(genre: row["genre"]!.string!, overrides: row["overrides"]!)
}

struct GoOracleTests {
  @Test func goAndJSFixturesCoverTheSameCases() throws {
    let rows = try #require(fixture()["cases"]?.array)
    #expect(rows.count == 542)
    #expect(rows.filter { $0["nets"] != nil }.count == 76)
  }

  @Test func wholeProjectsMatchGoWhereGoMatchesJS() throws {
    let rows = try #require(fixture()["cases"]?.array)
    let agreeing = rows.filter { $0["agreeModuloDrumChannel"]?.bool == true }
    #expect(agreeing.count >= 24, "the oracle must not be vacuous")
    for row in agreeing {
      let project = swiftProject(row)
      let mapped = drumChannelsTo10(project.normalizedForCID()).canonicalGo
      #expect(sha(mapped) == row["go"]!["cid"]!.string!, "\(row["id"]!.string!)")
      #expect(mapped.utf8.count == row["go"]!["bytes"]!.int!, "\(row["id"]!.string!) bytes")
    }
  }

  @Test func netsGoAndJSAgreeOnMatchSwift() throws {
    let rows = try #require(fixture()["cases"]?.array).filter { $0["nets"] != nil }
    var compared = 0
    var kinds = Set<String>()
    for row in rows {
      let doc = drumChannelsTo10(swiftProject(row).normalizedForCID())
      let nets = doc["nets"]!
      for (id, prefix) in row["nets"]!["same"]!.object!.entries {
        let digest = sha(nets[id]!.canonicalGo)
        #expect(String(digest.prefix(16)) == prefix.string!, "\(row["id"]!.string!) net \(id)")
        compared += 1
        kinds.insert(id)
      }
      // Every net Swift produces is accounted for: same, differing, or Swift-only is a bug.
      let n = row["nets"]!
      let accounted =
        Set(n["same"]!.object!.keys).union(n["differ"]!.strings!).union(n["onlyJs"]!.strings!)
      #expect(accounted == Set(nets.object!.keys), "\(row["id"]!.string!) net set")
    }
    #expect(compared > 500)
    #expect(["kick", "hit1", "hit4", "melody", "bass", "harmony"].allSatisfy(kinds.contains))
  }

  @Test func theKnownGoDivergencesAreRecorded() throws {
    // If Go is ever fixed to share channels / RNG with JS these counts change and this
    // test says so; update the fixture and the expectations together.
    let rows = try #require(fixture()["cases"]?.array)
    let fullAgreement = rows.filter { $0["agree"]?.bool == true }
    #expect(fullAgreement.isEmpty)
    let loops = rows.filter { $0["nets"] != nil }
    // After the drum-channel mapping only RNG-driven nets (and the clap) still differ.
    let allowed: Set<String> = ["bass", "melody", "hihat", "clap"]
    #expect(loops.allSatisfy { allowed.isSuperset(of: $0["nets"]!["differ"]!.strings!) })
    #expect(loops.allSatisfy { !$0["nets"]!["differ"]!.strings!.contains("snare") })
    #expect(loops.allSatisfy { $0["nets"]!["same"]!["kick"] != nil })
    #expect(loops.allSatisfy { $0["nets"]!["onlyGo"]!.array!.isEmpty })
  }
}
