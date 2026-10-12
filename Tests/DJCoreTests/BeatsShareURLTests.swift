import Testing

@testable import DJCore

private func fixture() throws -> JSONValue {
  try JSONValue.parse(try beatsFixtureText("share-urls"))
}

private func sha(_ s: String) -> String { BeatsCID.hex(BeatsCID.sha256(Array(s.utf8))) }

private func describe(_ l: ShareLink) -> String {
  switch l {
  case .envelope(let s): return "e" + s.toJSON().jsStringified
  case .legacy(let v): return "l" + v.jsStringified
  case .needsFetch(let c, _): return "f" + c
  }
}

struct ShareCodecTests {
  @Test func gunzipsWhatJSAndZlibProduce() throws {
    let rows = try #require(fixture()["gunzip"]?.array)
    #expect(rows.count >= 18)
    for r in rows {
      let text = r["text"]!.string!
      #expect(try ShareCodec.b64URLToGunzip(r["z"]!.string!) == text, "\(r["label"]!.string!)")
    }
  }

  @Test func gzipRoundTripsAndSystemGzipAgrees() throws {
    let texts = [
      "", "a", #"{"genre":"techno","seed":42}"#, String(repeating: "x", count: 100_000),
      "h\u{e9}llo \u{1F600} \u{2028} \u{0} end",
      String(
        (0..<5000).map { Character(UnicodeScalar(UInt8(truncatingIfNeeded: $0 &* 131 &+ $0 >> 3))) }
      ),
    ]
    for t in texts {
      let gz = ShareCodec.gzip(Array(t.utf8))
      #expect(try ShareCodec.gunzip(gz) == Array(t.utf8))
      #expect(try ShareCodec.b64URLToGunzip(ShareCodec.gzipToB64URL(t)) == t)
      #expect(systemGunzip(gz) == Array(t.utf8), "system gzip: \(t.prefix(20))")
    }
  }

  @Test func rejectsDamagedStreams() throws {
    let gz = ShareCodec.gzip(Array("hello hello hello hello".utf8))
    var badCRC = gz
    badCRC[badCRC.count - 8] ^= 0xFF
    var badSize = gz
    badSize[badSize.count - 1] ^= 0x01
    for bad in [badCRC, badSize, Array(gz.dropLast(3)), Array(gz.prefix(12)), [], [1, 2, 3]] {
      #expect(throws: ShareError.self) { try ShareCodec.gunzip(bad) }
    }
    #expect(throws: ShareError.self) { try ShareCodec.b64URLToGunzip("!!!notbase64") }
    // "hello": valid base64, not gzip
    #expect(throws: ShareError.self) { try ShareCodec.b64URLToGunzip("aGVsbG8") }
  }

  @Test func base64URLMatchesBtoaAtob() {
    #expect(ShareCodec.base64URL([0xFB, 0xFF, 0xFE]) == "-__-")
    #expect(ShareCodec.base64URL([1]) == "AQ")
    #expect(ShareCodec.base64URLDecode("-__-") == [0xFB, 0xFF, 0xFE])
    #expect(ShareCodec.base64URLDecode("AQ") == [1])
    #expect(ShareCodec.base64URLDecode("AQ==") == [1])
    #expect(ShareCodec.base64URLDecode("A") == nil)
    #expect(ShareCodec.base64URLDecode("A$Q") == nil)
    let v = JSONValue.object(JSONObject([("a", .string("\u{e9}\u{1F600}")), ("b", .number(1.5))]))
    #expect(ShareCodec.b64urlDecode(ShareCodec.b64urlEncode(v)) == v)
  }
}

struct ShareURLTests {
  @Test func parseMatchesParseShareFromUrl() throws {
    let rows = try #require(fixture()["urls"]?.array)
    var envelopes = 0
    var legacies = 0
    var nils = 0
    var fetches = 0
    for r in rows {
      let tag = "\(r["label"]!.string!): \(r["search"]!.string!.prefix(60))"
      let got = ShareLink.parse(r["search"]!.string!)
      if r["needsFetch"]?.bool == true {
        guard case .needsFetch(let cid, let legacy)? = got else {
          Issue.record("expected needsFetch: \(tag)")
          continue
        }
        #expect(cid == r["cid"]!.string!)
        #expect(legacy == nil)
        fetches += 1
        continue
      }
      let want = r["share"]!
      switch got {
      case .envelope(let s)?:
        #expect(s.toJSON().jsStringified == want.jsStringified, "\(tag)")
        envelopes += 1
      case .legacy(let v)?:
        #expect(v.jsStringified == want.jsStringified, "\(tag)")
        legacies += 1
      case .needsFetch?:
        Issue.record("unexpected needsFetch: \(tag)")
      case nil:
        #expect(want == .null, "\(tag)")
        nils += 1
      }
      // the full https URL form parses the same as its bare query
      if let full = r["url"]?.string {
        #expect(ShareLink.parse(full).map(describe) == got.map(describe), "\(tag)")
      }
    }
    #expect(envelopes >= 4 && legacies >= 8 && nils >= 6 && fetches >= 4)
  }

  @Test func swiftBuiltFormsAgreeWithJS() throws {
    let rows = try #require(fixture()["urls"]?.array)
    let base = try #require(fixture()["base"]?.string)
    var built: [(payload: JSONValue, url: String)] = []
    for r in rows where r["label"]?.string == "full" {
      let payload = r["payload"]!
      let f = ShareLink.forms(payload: payload, base: base)
      #expect(f.cid == r["cid"]!.string!)
      #expect(payload.canonicalJS == r["canonical"]!.string!)
      let short = rows.first { $0["label"]?.string == "short" && $0["cid"] == r["cid"] }!
      #expect(f.short == short["url"]!.string!)
      // The deflate stream may differ from CompressionStream's; what must hold is that
      // both decode to the same canonical text and yield the same envelope.
      #expect(try ShareCodec.b64URLToGunzip(r["z"]!.string!) == payload.canonicalJS)
      guard case .envelope(let s)? = ShareLink.parse(f.full) else {
        Issue.record("own URL does not parse")
        continue
      }
      #expect(s.toJSON().jsStringified == r["share"]!.jsStringified)
      built.append((payload, f.full))
    }
    #expect(built.count == 4)
    saveSwiftShareURLs(built)
  }

  @Test func fragmentAndBareQueryExtensions() throws {
    let rows = try #require(fixture()["urls"]?.array)
    let r = rows.first { $0["label"]?.string == "full" }!
    let cid = r["cid"]!.string!
    let z = r["z"]!.string!
    for form in [
      "https://x.test/p#cid=\(cid)&z=\(z)", "cid=\(cid)&z=\(z)", "?cid=\(cid)&z=\(z)#frag",
    ] {
      guard case .envelope(let s)? = ShareLink.parse(form) else {
        Issue.record("no envelope: \(form.prefix(40))")
        continue
      }
      #expect(s.cid == cid)
    }
    // the query wins over a fragment, as location.search does
    guard case .legacy(let v)? = ShareLink.parse("https://x.test/?g=house#g=jazz") else {
      Issue.record("expected legacy")
      return
    }
    #expect(v["genre"] == .string("house"))
  }

  @Test func shortLinkKeepsTheLegacyFallback() throws {
    guard case .needsFetch(let cid, let legacy)? = ShareLink.parse("?cid=zabc&g=house&s=3") else {
      Issue.record("expected needsFetch")
      return
    }
    #expect(cid == "zabc")
    #expect(legacy?["genre"] == .string("house"))
    #expect(legacy?["params"]?["seed"] == .number(3))
  }

  @Test func legacyLinkMakesAComposerShare() throws {
    guard case .legacy(let v)? = ShareLink.parse("?g=jazz&s=12&structure=minimal") else {
      Issue.record("expected legacy")
      return
    }
    let share = Share(legacy: v)
    #expect(share.genre == "jazz")
    #expect(share.params.keys == ["seed", "structure"])
    let want = compose(genre: "jazz", overrides: .object(share.params))
    #expect(share.project()?.modelCID == want.modelCID)
  }

  @Test func fetchedPayloadIsReHashedByDecode() throws {
    let rows = try #require(fixture()["urls"]?.array)
    let r = rows.first { $0["label"]?.string == "full" }!
    let ok = try Share.decode(json: r["canonical"]!.string!, cid: r["cid"]!.string!)
    #expect(ok.genre == "techno")
    #expect(throws: ShareError.self) {
      try Share.decode(json: #"{"genre":"techno","seed":43}"#, cid: r["cid"]!.string!)
    }
  }
}

/// `TrackSpec.payload` against `specPayloads` (scripts/beats-share-url.mjs, real JS): the app
/// writes traits where `shareFromPayload` reads them, and still reads the old form back.
struct TrackSpecPayloadTests {
  @Test func beatsComposesTheSpecsPayloadWithItsTraits() throws {
    let rows = try #require(fixture()["specPayloads"]?.array)
    #expect(rows.count >= 4)
    for r in rows {
      let payload = r["payload"]!
      let tag = String(payload.jsStringified.prefix(60))
      let spec = try #require(TrackSpec(share: Share(payload: payload)), "\(tag)")
      #expect(spec.extra["traits"] == nil && !spec.extra.entries.isEmpty, "\(tag)")
      // Swift writes exactly the envelope JS was given…
      #expect(spec.payload.canonicalJS == payload.canonicalJS, "\(tag)")
      // …which JS reads to these params, and composes to the project the deck composes.
      let cid = r["cid"]!.string!
      #expect(BeatsCID.shareCID(spec.payload) == cid, "\(tag)")
      #expect(
        Share(payload: spec.payload, cid: cid).toJSON().jsStringified == r["share"]!.jsStringified,
        "\(tag)")
      #expect(
        compose(genre: spec.genre, overrides: spec.overrides).modelCID == r["modelCID"]!.string!,
        "\(tag)")
      // The old form (top-level traits): beats composes it without them…
      let old = r["oldPayload"]!
      #expect(Share(payload: old).params == r["oldParams"]!.object!, "\(tag)")
      #expect(r["oldModelCID"]!.string! != r["modelCID"]!.string!, "\(tag)")
      // …and the app reads both forms back to the same spec (layers in the payload's order).
      #expect(TrackSpec(payload: old)?.payload.canonicalJS == payload.canonicalJS, "\(tag)")
      #expect(TrackSpec(payload: old)?.extra == spec.extra, "\(tag)")
      #expect(TrackSpec(payload: spec.payload) == spec, "\(tag)")
    }
  }

  @Test func oldAndNewSessionPayloadsRoundTrip() throws {
    let spec = TrackSpec(
      genre: "techno", seed: 42, structure: "standard", cohesion: "v2",
      extra: JSONObject([("bpm", .number(126)), ("ghost-notes", .number(0.3))]),
      layers: JSONObject([("tempo", .number(130))]))
    // As sessions recorded before this change wrote it: traits at the top level.
    let old = try JSONValue.parse(
      #"{"genre":"techno","seed":42,"structure":"standard","cohesion":"v2","bpm":126,"ghost-notes":0.3,"tempo":130}"#
    )
    let new = try JSONValue.parse(
      #"{"genre":"techno","seed":42,"structure":"standard","cohesion":"v2","traits":{"bpm":126,"ghost-notes":0.3},"tempo":130}"#
    )
    #expect(spec.payload == new)
    for form in [old, new] {
      #expect(TrackSpec(payload: form) == spec)
      let source = JSONValue.object(
        JSONObject([("kind", .string("net")), ("share", form)]))
      #expect(DeckSourceDescriptor(json: source) == .net(spec))
      let action = JSONValue.object(
        JSONObject([("op", .string("queueNext")), ("deck", .string("A")), ("share", form)]))
      #expect(DeckAction(json: action) == .queueNext(deck: "A", spec: spec))
    }
    // A spec with no extras writes what it always did.
    let plain = TrackSpec(genre: "jazz", seed: 3)
    #expect(plain.payload.jsStringified == #"{"genre":"jazz","seed":3,"cohesion":"v2"}"#)
    // Keys `overrides` sets itself are not traits.
    let shadow = TrackSpec(
      genre: "jazz", seed: 3, structure: "minimal",
      extra: JSONObject([("seed", .number(9)), ("structure", .string("x")), ("bpm", .number(99))]))
    #expect(shadow.payload["traits"] == .object(JSONObject([("bpm", .number(99))])))
  }
}

struct RawNetsEnvelopeTests {
  @Test func rawNetsProjectMatchesWhatTheBrowserLoads() throws {
    let rows = try #require(fixture()["rawNets"]?.array)
    #expect(rows.count >= 6)
    var built = 0
    var arrange = 0
    for r in rows {
      let tag = String(r["payload"]!.jsStringified.prefix(60))
      guard case .envelope(let share)? = ShareLink.parse(r["search"]!.string!) else {
        Issue.record("no envelope: \(tag)")
        continue
      }
      #expect(share.cid == r["cid"]!.string!)
      #expect(share.toJSON().jsStringified == r["share"]!.jsStringified, "\(tag)")
      #expect(share.needsArrange == (r["needsArrange"]?.bool ?? false), "\(tag)")
      if share.needsArrange {
        // Arranged (no digest here: share-urls.json records the boot project before arrange;
        // the arranged one is proven by arrange.json, BeatsArrangeTests).
        #expect(share.project() != nil, "\(tag)")
        arrange += 1
        continue
      }
      let want = try #require(r["project"], "\(tag)")
      let p = try #require(share.project(), "\(tag)")
      #expect(p.name == want["name"]!.string!)
      #expect(p.tempo == want["tempo"]!.double!)
      #expect(p.canonicalJSON.utf8.count == Int(want["canonicalBytes"]!.double!), "\(tag)")
      #expect(p.modelCID == want["modelCID"]!.string!, "\(tag)")
      #expect(sha(p.toJSON().jsStringified) == want["docSha"]!.string!, "\(tag)")
      built += 1
    }
    #expect(built == 5 && arrange == 1)
  }

  @Test func rawNetsOfAComposedProjectReproduceItsModelCID() throws {
    // compose -> projectToJSON -> raw-nets envelope -> share URL -> decode -> same model CID.
    let composed = compose(
      genre: "techno",
      overrides: .object(JSONObject([("seed", .number(42)), ("cohesion", .string("v2"))])))
    let nets = try #require(composed.toJSON()["nets"])
    var payload = JSONObject()
    payload["genre"] = .string("techno")
    payload["name"] = .string(composed.name)
    payload["tempo"] = .number(composed.tempo)
    payload["swing"] = .number(composed.swing)
    payload["humanize"] = .number(composed.humanize)
    payload["nets"] = nets
    let f = ShareLink.forms(payload: .object(payload), base: "https://beats.bitwrap.io/")
    guard case .envelope(let share)? = ShareLink.parse(f.full) else {
      Issue.record("no envelope")
      return
    }
    #expect(share.cid == f.cid)
    let back = try #require(share.project())
    #expect(back.modelCID == composed.modelCID)
  }

  @Test func derivedNameFollowsTheCIDThenTheSeed() throws {
    let fromCID = Share(payload: try JSONValue.parse(#"{"genre":"house","nets":{}}"#), cid: "zabc")
    var h: Int32 = 5381
    for u in "zabc".utf16 { h = (h &* 33) ^ Int32(u) }
    #expect(
      fromCID.derivedName == generateTrackName(genre: "house", seed: Double(UInt32(bitPattern: h))))
    let fromSeed = Share(payload: try JSONValue.parse(#"{"seed":7,"nets":{}}"#))
    #expect(fromSeed.derivedName == generateTrackName(genre: "custom", seed: 7))
    let zero = Share(payload: try JSONValue.parse(#"{"genre":"g","nets":{}}"#))
    #expect(zero.derivedName == generateTrackName(genre: "g", seed: 1))
  }
}
