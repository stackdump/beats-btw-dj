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
}
