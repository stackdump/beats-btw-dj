import Testing

@testable import DJCore

private func fixture(_ name: String) throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText(name))
}

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

struct ShareEnvelopeTests {
  @Test func shareFromPayloadMatchesJS() throws {
    let rows = try #require(fixture("envelopes")["envelopes"]?.array)
    #expect(rows.count >= 19)
    for row in rows {
      let share = Share(payload: row["payload"]!, cid: row["cid"]!.string!)
      #expect(
        share.toJSON().jsStringified == row["share"]!.jsStringified,
        "\(row["payload"]!.jsStringified)")
    }
  }

  @Test func composerPathReproducesTheEnvelopesProject() throws {
    let rows = try #require(fixture("envelopes")["envelopes"]?.array)
    var checked = 0
    for row in rows {
      guard let want = row["project"] else { continue }
      let share = Share(payload: row["payload"]!, cid: row["cid"]!.string!)
      // Compose directly (no model-level overrides): the oracle digest is of compose().
      let project = compose(genre: share.genre!, overrides: .object(share.params))
      let tag = row["payload"]!.jsStringified
      #expect(project.canonicalJSON.utf8.count == Int(want["canonicalBytes"]!.double!), "\(tag)")
      #expect(project.modelCID == want["modelCID"]!.string!, "\(tag)")
      #expect(sha(project.toJSON().jsStringified) == want["docSha"]!.string!, "\(tag)")
      checked += 1
    }
    #expect(checked >= 14)
  }

  @Test func oldEnvelopesPinCohesionV1() throws {
    let legacy = Share(payload: try JSONValue.parse(#"{"genre":"techno","seed":42}"#))
    #expect(legacy.params["cohesion"] == .string("v1"))
    let v2 = Share(payload: try JSONValue.parse(#"{"genre":"techno","seed":42,"cohesion":"v2"}"#))
    #expect(v2.params["cohesion"] == .string("v2"))
    let odd = Share(payload: try JSONValue.parse(#"{"genre":"techno","seed":42,"cohesion":"v3"}"#))
    #expect(odd.params["cohesion"] == .string("v1"))
    // The two compose differently: that is the whole reason for the pin.
    #expect(legacy.project()!.modelCID != v2.project()!.modelCID)
  }

  @Test func traitsOverrideEarlierParams() throws {
    let s = Share(
      payload: try JSONValue.parse(
        #"{"genre":"house","seed":1,"structure":"minimal","traits":{"seed":9,"cohesion":"v2","ghost-notes":0.5}}"#
      ))
    #expect(s.params.keys == ["seed", "structure", "cohesion", "ghost-notes"])
    #expect(s.params["seed"] == .number(9))
    #expect(s.params["cohesion"] == .string("v2"))
  }

  @Test func decodeVerifiesTheCID() throws {
    let rows = try #require(fixture("envelopes")["envelopes"]?.array)
    let row = rows[0]
    let text = row["canonical"]!.string!
    let ok = try Share.decode(json: text, cid: row["cid"]!.string!)
    #expect(ok.genre == "techno")
    #expect(throws: ShareError.self) { try Share.decode(json: text, cid: "zNotTheCid") }
  }

  @Test func tempoOverrideDoesNotChangeAComposedProject() throws {
    let s = Share(
      payload: try JSONValue.parse(
        #"{"genre":"jazz","seed":25,"cohesion":"v2","tempo":150,"swing":0.4}"#))
    #expect(s.overrides?["tempo"] == .number(150))
    #expect(s.project()!.tempo == compose(genre: "jazz", overrides: .object(s.params)).tempo)
  }

  @Test func trackAndMuteOverridesLandOnTheProject() throws {
    let s = Share(
      payload: try JSONValue.parse(
        #"{"genre":"jazz","seed":25,"cohesion":"v2","initialMutes":["bass","hit1"],"tracks":{"4":{"instrument":"vibes","mix":{"vol":0.5},"instrumentSet":["vibes","piano"]}}}"#
      ))
    let p = s.project()!
    #expect(p.initialMutes == ["bass", "hit1"])
    let melody = try #require(p.nets["melody"])
    #expect(melody.track.channel == 4)
    #expect(melody.track.instrument == "vibes")
    #expect(melody.track.mix == .object(JSONObject([("vol", .number(0.5))])))
    #expect(melody.track.instrumentSet == [.string("vibes"), .string("piano")])
    // channel 6 (bass) is untouched
    #expect(p.nets["bass"]!.track.instrument != "vibes")
  }

  @Test func rawNetsEnvelopesAreNotComposed() throws {
    let s = Share(payload: try JSONValue.parse(#"{"genre":"techno","nets":{"a":{}}}"#))
    // loaded literally (BeatsShareURLTests checks them against JS), never composed
    #expect(s.project()?.nets.keys == ["a"])
    // With a structure the literal nets are arranged, as the JS does (the arranged bytes are
    // checked against the real JS in BeatsArrangeTests): the lone net is split into phrase
    // variants under a section control net and the song gets a structure; nothing is composed.
    let arranged = Share(
      payload: try JSONValue.parse(#"{"genre":"techno","nets":{"a":{}},"structure":"standard"}"#))
    let p = try #require(arranged.project())
    #expect(p.nets.keys == ["a-0", "a-1", "a-2", "struct-a", "struct-stop"])
    #expect(!p.structure.isEmpty)
  }
}
