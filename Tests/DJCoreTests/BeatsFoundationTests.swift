import Testing

@testable import DJCore

// Every expectation below was produced by beats' own JS (scripts/beats-parity.mjs,
// `make fixtures-beats`), never by this code. A failure means Swift disagrees with
// the oracle, not that a fixture is stale.

private func fixture(_ name: String) throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText(name))
}

private func bits(_ hex: String) -> Double { Double(bitPattern: UInt64(hex, radix: 16)!) }

private func bytes(_ hex: String) -> [UInt8] {
  var out: [UInt8] = []
  var i = hex.startIndex
  while i < hex.endIndex {
    let j = hex.index(i, offsetBy: 2)
    out.append(UInt8(hex[i..<j], radix: 16)!)
    i = j
  }
  return out
}

struct JSNumberTests {
  @Test func numberToStringMatchesJS() throws {
    let rows = try #require(fixture("foundation")["numbers"]?.array)
    #expect(rows.count > 500)
    for row in rows {
      let d = bits(row["bits"]!.string!)
      #expect(jsNumberString(d) == row["str"]!.string!, "bits \(row["bits"]!.string!)")
      // JSON.stringify differs from String() only for non-finite values (null).
      #expect(JSONValue.number(d).jsStringified == row["json"]!.string!)
      #expect(Double(jsToInt32(d)) == row["int32"]!.double!, "int32 \(row["str"]!.string!)")
    }
  }

  @Test func knownFormats() {
    #expect(jsNumberString(1e21) == "1e+21")
    #expect(jsNumberString(1e-7) == "1e-7")
    #expect(jsNumberString(0.000001) == "0.000001")
    #expect(jsNumberString(123_456_789_012_345_680_000) == "123456789012345680000")
    #expect(jsNumberString(-0.0) == "0")
    #expect(jsNumberString(0.1 + 0.2) == "0.30000000000000004")
  }
}

struct JSONTests {
  @Test func parseStringifyCanonicalMatchJS() throws {
    let rows = try #require(fixture("foundation")["json"]?.array)
    for row in rows {
      let input = row["input"]!.string!
      let v = try JSONValue.parse(input)
      #expect(v.jsStringified == row["stringified"]!.string!, "stringify \(input)")
      #expect(v.canonicalJS == row["canonical"]!.string!, "canonical \(input)")
      #expect(v.canonicalGo == row["canonicalGo"]!.string!, "go \(input)")
    }
  }

  @Test func integerKeysComeFirstLikeJS() throws {
    let v = try JSONValue.parse(#"{"b":1,"2":"x","a":2,"1":"y"}"#)
    #expect(v.jsStringified == #"{"1":"y","2":"x","b":1,"a":2}"#)
  }

  @Test func rejectsMalformed() {
    for bad in ["", "{", "[1,]", "{\"a\":}", "01", "1.", "\"\\x\"", "nul", "[1] 2"] {
      #expect(throws: JSONError.self) { try JSONValue.parse(bad) }
    }
  }
}

struct RNGTests {
  @Test func mulberry32MatchesCreateRng() throws {
    let rows = try #require(fixture("foundation")["rng"]?.array)
    #expect(rows.count >= 16)
    for row in rows {
      let seed = row["seed"]!.double!
      var a = Mulberry32(seed: seed)
      for (i, want) in row["next"]!.array!.enumerated() {
        #expect(a.next().bitPattern == bits(want.string!).bitPattern, "seed \(seed) next[\(i)]")
      }
      var b = Mulberry32(seed: seed)
      #expect(
        row["nextInt7"]!.array!.map { _ in b.nextInt(7) }
          == row["nextInt7"]!.array!.map { Int($0.double!) })
      var c = Mulberry32(seed: seed)
      #expect(
        row["nextInt63"]!.array!.map { _ in c.nextInt63() }
          == row["nextInt63"]!.array!.map { Int($0.double!) })
    }
  }
}

struct CIDTests {
  @Test func base58MatchesJS() throws {
    for row in try #require(fixture("foundation")["base58"]?.array) {
      let raw = bytes(row["hex"]!.string!)
      let text = row["b58"]!.string!
      #expect(BeatsCID.encodeBase58(raw) == text)
      #expect(BeatsCID.decodeBase58(text) == raw)
    }
  }

  @Test func cidV1MatchesJS() throws {
    for row in try #require(fixture("foundation")["cids"]?.array) {
      let input = row["input"]!.string!
      let hash = BeatsCID.sha256(Array(input.utf8))
      #expect(BeatsCID.hex(hash) == row["sha256"]!.string!)
      #expect(BeatsCID.hex(BeatsCID.cidV1Bytes(hash: hash)) == row["cidBytes"]!.string!)
      #expect(BeatsCID.shareCID(canonical: input) == row["cid"]!.string!, "input \(input)")
    }
  }

  @Test func shareEnvelopesCanonicalizeAndHashLikeBeats() throws {
    let rows = try #require(fixture("envelopes")["envelopes"]?.array)
    #expect(rows.count >= 10)
    for row in rows {
      let payload = row["payload"]!
      #expect(payload.canonicalJS == row["canonical"]!.string!, "\(payload.jsStringified)")
      #expect(BeatsCID.shareCID(payload) == row["cid"]!.string!, "\(payload.jsStringified)")
    }
  }

  @Test func storedProjectsRoundTripToTheirModelCID() throws {
    let rows = try #require(fixture("projects")["projects"]?.array)
    #expect(rows.count == 19 * 4 * 2 * 2)
    var full = 0
    for row in rows {
      guard let canonical = row["canonical"]?.string else { continue }
      full += 1
      // Re-serialising the parsed model must reproduce JS's bytes exactly: this is
      // the sort order, number formatting and Go escaping that 2.3 builds on.
      let parsed = try JSONValue.parse(canonical)
      #expect(parsed.canonicalGo == canonical)
      #expect(canonical.utf8.count == Int(row["canonicalBytes"]!.double!))
      #expect(BeatsCID.modelCID(canonicalProject: canonical) == row["modelCID"]!.string!)
    }
    #expect(full == 3)
  }

  @Test func moduleVectorsAreWrittenForTheComposerGates() throws {
    // Consumed by the 2.4 module ports; here only proof the harness produced them.
    let m = try fixture("modules")
    #expect(m["bjorklund"]?.array?.isEmpty == false)
    #expect(m["structures"]?.array?.count == 19 * 8 * 2)
    #expect(m["themes"]?.array?.count == 19 * 4)
    #expect(m["motifs"]?.array?.isEmpty == false)
  }
}
