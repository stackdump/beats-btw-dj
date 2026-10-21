import Testing

@testable import DJCore

struct PianoRollTests {
  func roll(_ json: String) throws -> JSONValue { try JSONValue.parse(json) }

  func project(_ env: JSONValue) throws -> Project {
    try #require(Share(payload: env).rawNetsProject())
  }

  @Test func aRollBecomesOneRingPerPartWithTheNotesOnTheirSteps() throws {
    let env = try PianoRoll.envelope(
      roll(
        """
        {"name":"T","tempo":96,"parts":{"kick":{"notes":[[0],[8]]},
         "bass":{"instrument":"acid","notes":[[0,36,4,90],[16,43]]}}}
        """))
    #expect(env["name"]?.string == "T" && env["tempo"]?.double == 96)
    let p = try project(env)
    #expect(p.tempo == 96)
    // 17 + 2 steps → two bars: both rings are 32 long
    let kick = try #require(p.nets["kick"])
    let bass = try #require(p.nets["bass"])
    #expect(kick.places.count == 32 && bass.places.count == 32 && kick.transitions.count == 32)
    #expect(kick.track.channel == 10 && bass.track.channel == 6)
    #expect(bass.track.instrument == "acid")
    // the transition leaving step i carries the note that starts there
    #expect(kick.bindings["t0"]?.note == 36 && kick.bindings["t8"]?.note == 36)  // GM kick
    #expect(kick.bindings["t4"] == nil)
    #expect(bass.bindings["t0"]?.note == 36 && bass.bindings["t0"]?.durationSteps == 4)
    #expect(bass.bindings["t0"]?.velocity == 90)
    #expect(bass.bindings["t16"]?.note == 43 && bass.bindings["t16"]?.durationSteps == 2)
    // one token, in step 0
    #expect(bass.places["p0"]?.initial == [1] && bass.places["p1"]?.initial == [0])
    // the ring closes: the last transition returns to p0
    #expect(
      bass.arcs.contains { $0.source == "t31" && $0.target == "p0" }
        && bass.arcs.contains { $0.source == "p5" && $0.target == "t5" })
  }

  @Test func notesOnTheSameStepSpillIntoSiblingNetsOfTheSameRole() throws {
    let env = try PianoRoll.envelope(
      roll(
        """
        {"steps":16,"parts":{"harmony":{"notes":[
          {"step":0,"note":60,"dur":16},{"step":0,"note":64,"dur":16},{"step":0,"note":67,"dur":16}]}}}
        """))
    let p = try project(env)
    #expect(Set(p.nets.keys) == ["harmony", "harmony-b", "harmony-c"])
    #expect(
      Set(["harmony", "harmony-b", "harmony-c"].compactMap { p.nets[$0]?.bindings["t0"]?.note })
        == [60, 64, 67])
    #expect(p.nets["harmony-b"]?.riffGroup == "harmony")
    #expect(p.nets["harmony-b"]?.track.channel == 7)
  }

  @Test func theEnvelopeLoadsAsARawNetsShare() throws {
    let env = try PianoRoll.envelope(roll(#"{"parts":{"melody":{"notes":[[0,72]]}}}"#))
    let source = try DeckSourceDescriptor.share(payload: env)
    guard case .rawNets = source else {
      Issue.record("expected a raw-nets source")
      return
    }
  }

  @Test func badRollsSayWhatToFix() {
    func message(_ json: String) -> String {
      do {
        _ = try PianoRoll.envelope(JSONValue.parse(json))
        return ""
      } catch { return "\(error)" }
    }
    #expect(message("{}").contains("`parts`"))
    #expect(message(#"{"parts":{"bass":{}}}"#).contains("needs `notes`"))
    #expect(message(#"{"parts":{"bass":{"notes":[[0,200]]}}}"#).contains("0…127"))
    #expect(message(#"{"parts":{"bass":{"notes":[[-1,40]]}}}"#).contains("`step`"))
    #expect(message(#"{"steps":16,"parts":{"bass":{"notes":[[16,40]]}}}"#).contains("past `steps`"))
    #expect(message(#"{"tempo":5,"parts":{"kick":{"notes":[[0]]}}}"#).contains("`tempo`"))
    #expect(message(#"{"steps":5000,"parts":{"kick":{"notes":[[0]]}}}"#).contains("`steps`"))
  }

  @Test func theToolIsListedAndMapsToTheControlMethod() throws {
    let tools = MCPBridge.tools
    let tool = try #require(tools.first { $0["name"]?.string == "dj_compose" })
    #expect(tool["inputSchema"]?["required"] == .array([.string("deck"), .string("parts")]))
    #expect(MCPBridge.methods["dj_compose"] == "composeRoll")
    #expect(MCPBridge.instructions.contains("dj_compose"))
  }
}
