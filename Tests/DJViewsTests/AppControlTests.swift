import DJCore
import Testing

@testable import DJViews

/// The control socket's methods, driven straight into an offline engine.
@MainActor
struct AppControlTests {
  func model() throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj)
    m.start()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  @Test func stateDescribesBothDecks() async throws {
    let s = try await call(try model(), "state")
    #expect(s["decks"]?["A"]?["mode"]?.string == "sample")
    #expect(s["decks"]?["B"]?["playing"]?.bool == false)
    #expect(s["crossfader"]?.double == 0.5)
    #expect(s["build"]?["id"]?.string == BuildInfo.current.id)
  }

  @Test func performGoesThroughTheEngine() async throws {
    let m = try model()
    let a = try await call(m, "perform", #"{"action":{"op":"play","deck":"A","on":true}}"#)
    #expect(a["playing"]?.bool == true)
    #expect(m.engine?["A"]?.playing == true)
    _ = try await call(m, "perform", #"{"action":{"op":"crossfader","value":0.1}}"#)
    #expect(m.engine?.crossfader == 0.1)
  }

  @Test func performIsRecordedLikeAButton() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let rec = try SessionRecorder.start(on: dj)
    _ = try await call(
      m, "perform", #"{"action":{"op":"param","deck":"B","name":"filter","value":0.2}}"#)
    #expect(
      rec.finish().events.map(\.kind) == [.action(.param(deck: "B", name: "filter", value: 0.2))])
  }

  @Test func badRequestsSayWhatIsWrong() async throws {
    let m = try model()
    for (params, words) in [
      (#"{"action":{"op":"play","deck":"C","on":true}}"#, "no deck"),
      (#"{"action":{"op":"spin","deck":"A"}}"#, "known `op`"),
      (#"{"action":{"op":"macro","deck":"A","macro":"drop"}}"#, "needs a net deck"),
      (#"{"action":{"op":"load","deck":"A","source":{"kind":"none"}}}"#, "dj_generate"),
    ] {
      await #expect {
        try await call(m, "perform", params)
      } throws: { "\($0)".contains(words) }
    }
    await #expect(throws: (any Error).self) { try await call(m, "nope") }
  }

  @Test func generateLoadsALiveNetAndMacrosThenWork() async throws {
    let m = try model()
    let b = try await call(
      m, "generate", #"{"deck":"B","genre":"techno","seed":42,"structure":"minimal"}"#)
    #expect(b["mode"]?.string == "net")
    #expect((b["sections"]?.array?.count ?? 0) > 0)
    #expect(b["roles"]?["kick"] != nil)
    _ = try await call(m, "perform", #"{"action":{"op":"macro","deck":"B","macro":"drop"}}"#)
    await #expect(throws: (any Error).self) {
      try await call(m, "perform", #"{"action":{"op":"macro","deck":"B","macro":"wobble"}}"#)
    }
    await #expect(throws: (any Error).self) {
      try await call(m, "generate", #"{"deck":"B","genre":"polka","seed":1}"#)
    }
  }

  /// `loadShare` (dj_load_share): share links and payloads from the JS fixtures go on a deck
  /// through `perform`, recorded as the load a replay needs.
  @Test func loadShareLoadsComposedAndRawNetsSharesAndRecordsThem() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let urls = try #require(try beatsFixture("share-urls")["urls"]?.array)
    let full = try #require(
      urls.first { $0["payload"]?["genre"]?.string == "house" && $0["z"] != nil })
    let raw = try #require(
      try beatsFixture("share-urls")["rawNets"]?.array?.first {
        $0["payload"]?["name"]?.string == "Hand Made"
      })
    let envelope = try #require(
      try beatsFixture("envelopes")["envelopes"]?.array?.first {
        $0["payload"]?["traits"]?["modal-interchange"] != nil && $0["project"] != nil
      })
    let rec = try SessionRecorder.start(on: dj)

    // a full share URL: composed
    let b = try await m.control(
      "loadShare",
      .object(JSONObject([("deck", .string("B")), ("link", full["url"]!)])))
    #expect(b["mode"]?.string == "net")
    #expect(b["share"]?["kind"]?.string == "net" && b["share"]?["genre"]?.string == "house")
    let houseSpec = try #require(TrackSpec(share: Share(payload: full["payload"]!)))
    #expect(dj["B"]?.currentSpec == houseSpec)

    // a raw-nets share link (its query alone)
    let a = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("A")), ("link", raw["search"]!)])))
    #expect(a["share"]?["kind"]?.string == "rawNets")
    #expect(a["share"]?["cid"]?.string == raw["cid"]!.string!)
    #expect(a["title"]?.string == "Hand Made")
    #expect(dj["A"]?.netProject?.modelCID == raw["project"]?["modelCID"]?.string)

    // an envelope payload, as JSON text and as an object
    let text = envelope["payload"]!.jsStringified
    let e = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("B")), ("link", .string(text))])))
    #expect(e["share"]?["kind"]?.string == "net")
    let envSpec = try #require(dj["B"]?.currentSpec)
    #expect(envSpec.layers.entries.isEmpty)
    #expect(envSpec.project().modelCID == envelope["project"]?["modelCID"]?.string)
    _ = try await m.control(
      "loadShare", .object(JSONObject([("deck", .string("B")), ("link", envelope["payload"]!)])))
    #expect(dj["B"]?.currentSpec == envSpec)

    let loads = rec.finish().events.map(\.kind)
    #expect(
      loads == [
        .action(.load(deck: "B", source: .net(houseSpec))),
        .action(.load(deck: "A", source: .rawNets(payload: raw["payload"]!))),
        .action(.load(deck: "B", source: .net(envSpec))),
        .action(.load(deck: "B", source: .net(envSpec))),
      ])
  }

  /// Load ▸ "Share link from clipboard" calls `AppModel.loadShare(deck, text)` with the
  /// pasteboard's string: a good link lands on the deck (recorded), a bad one only says why.
  @Test func theClipboardMenuItemLoadsAShareOrSaysWhy() async throws {
    let m = try model()
    let dj = try #require(m.engine)
    let raw = try #require(
      try beatsFixture("share-urls")["rawNets"]?.array?.first {
        $0["payload"]?["name"]?.string == "Hand Made"
      })
    let rec = try SessionRecorder.start(on: dj)
    m.loadShare("A", "  " + raw["search"]!.string! + "\n")  // pasted text, with whitespace
    for _ in 0..<2000 where dj["A"]?.mode != .net { try await Task.sleep(for: .milliseconds(5)) }
    #expect(dj["A"]?.mode == .net && dj["A"]?.title == "Hand Made")
    #expect(
      rec.finish().events.map(\.kind) == [
        .action(.load(deck: "A", source: .rawNets(payload: raw["payload"]!)))
      ])
    m.loadShare("B", "not a link")
    #expect(m.status.hasPrefix("share: not a beats share"))
    m.loadShare("B", "")  // an empty clipboard
    #expect(m.status.hasPrefix("share: "))
    #expect(dj["B"]?.mode == .sample, "nothing was loaded")
  }

  @Test func loadShareSaysWhatIsWrong() async throws {
    let m = try model()
    let urls = try #require(try beatsFixture("share-urls")["urls"]?.array)
    let short = try #require(urls.first { $0["needsFetch"]?.bool == true })
    let tampered = try #require(urls.first { $0["label"]?.string?.hasPrefix("tampered") == true })
    for (params, words) in [
      (#"{"deck":"A","link":"\#(short["url"]!.string!)"}"#, "short link"),
      (#"{"deck":"A","link":"\#(tampered["search"]!.string!)"}"#, "not a beats share"),
      (#"{"deck":"A","link":"{\"genre\":\"polka\",\"seed\":1}"}"#, "unknown genre"),
      (#"{"deck":"A"}"#, "`link` is required"),
      (#"{"deck":"C","link":"?g=house"}"#, "no deck"),
    ] {
      await #expect {
        try await call(m, "loadShare", params)
      } throws: { "\($0)".contains(words) }
    }
    #expect(m.engine?["A"]?.mode == .sample, "nothing was loaded")
  }

  @Test func catalogListsWhatTheToolsAccept() async throws {
    let c = try await call(try model(), "catalog")
    #expect(c["genres"]?.array?.contains(.string("techno")) == true)
    #expect(c["macros"]?.array?.contains { $0["id"]?.string == "drop" } == true)
    #expect((c["apcPads"]?.array?.count ?? 0) > 0)
  }

  @Test func padsPressTheOnScreenAPC() async throws {
    let m = try model()
    let s = try await call(m, "pad", #"{"group":"pads","index":0}"#)
    #expect(s["padsOnScreen"]?.bool == true)
    await #expect(throws: (any Error).self) {
      try await call(m, "pad", #"{"group":"pads","index":99}"#)
    }
  }

  @Test func catalogSaysWhatEachInstrumentSoundsLike() async throws {
    let c = try await call(try model(), "catalog")
    let sounds = Dictionary(
      uniqueKeysWithValues: (c["instruments"]?.array ?? []).compactMap { e in
        e["name"]?.string.map { ($0, e["sound"]?.string ?? "") }
      })
    // each instrument names its category and what this Mac has for it
    #expect(sounds["acoustic-guitar"]?.hasPrefix("guitar.acoustic: ") == true)
    #expect(sounds["supersaw"]?.hasSuffix("or table:saw") == true)
    #expect(sounds["distorted-guitar"]?.hasSuffix("or pluck") == true)
    #expect(c["voices"]?["bass.electric"]?.array?.isEmpty == false)

    #expect(sounds["drums-808"] == "drum kit")
  }

  @Test func auditionRendersAnInstrumentWithoutTouchingTheDecks() async throws {
    let m = try model()
    let before = try await call(m, "state")
    let a = try await call(
      m, "audition", #"{"instrument":"electric-guitar","notes":[40,45,50],"play":false}"#)
    #expect(a["sound"]?.string?.hasPrefix("guitar.electric") == true)
    let plays = a["plays"]?.string ?? ""
    #expect(
      plays.hasPrefix("exs:") || plays.hasPrefix("sf2:") || plays.hasPrefix("gm:"),
      "played \(plays)")
    #expect((a["rmsDB"]?.double ?? -200) > -40)
    #expect(a["path"]?.string?.hasSuffix("electric-guitar.wav") == true)
    #expect(try await call(m, "state") == before)
    await #expect(throws: (any Error).self) {
      try await call(m, "audition", #"{"instrument":"kazoo","play":false}"#)
    }
    await #expect(throws: (any Error).self) {
      try await call(m, "audition", #"{"instrument":"bass","sound":"tuba","play":false}"#)
    }
  }
}
