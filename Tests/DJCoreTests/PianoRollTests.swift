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
    #expect(tool["inputSchema"]?["required"] == .array([.string("parts")]))
    #expect(MCPBridge.methods["dj_compose"] == "composeRoll")
    #expect(MCPBridge.instructions.contains("dj_compose"))
  }
}

struct PianoRollPatternTests {
  func project(_ json: String) throws -> Project {
    try #require(Share(payload: PianoRoll.envelope(JSONValue.parse(json))).rawNetsProject())
  }

  @Test func aRepeatedPatternFillsTheRollFromWhereItStarts() throws {
    // one bar of four-on-the-floor kick, written once, from bar 5 on, in a 16-bar roll
    let p = try project(
      #"{"steps":256,"parts":{"kick":{"every":16,"from":64,"notes":[[0],[4],[8],[12]]}}}"#)
    let kick = try #require(p.nets["kick"])
    #expect(kick.places.count == 256)
    #expect(kick.bindings["t0"] == nil && kick.bindings["t60"] == nil)
    #expect(kick.bindings["t64"]?.note == 36 && kick.bindings["t68"]?.note == 36)
    #expect(kick.bindings["t252"]?.note == 36 && kick.bindings.count == 48)  // 12 bars × 4
  }

  @Test func segmentsAndUntilBuildAnArrangement() throws {
    // melody: bars 1-2 one pattern, bars 3-4 another; a part given as a list of segments
    let p = try project(
      """
      {"parts":{"melody":[
        {"every":16,"until":32,"notes":[[0,72,4]]},
        {"from":32,"until":64,"every":32,"notes":[[0,76,8],[16,79,8]]}]}}
      """)
    let m = try #require(p.nets["melody"])
    #expect(m.places.count == 64)  // from the longest `until`
    #expect(m.bindings["t0"]?.note == 72 && m.bindings["t16"]?.note == 72)
    #expect(m.bindings["t32"]?.note == 76 && m.bindings["t48"]?.note == 79)
    #expect(m.bindings.count == 4)
  }

  @Test func aRepeatNeedsAnEndAndNotesStayInsideIt() throws {
    func message(_ json: String) -> String {
      do {
        _ = try PianoRoll.envelope(JSONValue.parse(json))
        return ""
      } catch { return "\(error)" }
    }
    #expect(message(#"{"parts":{"kick":{"every":16,"notes":[[0]]}}}"#).contains("`until`"))
    #expect(
      message(#"{"parts":{"kick":{"every":0,"until":16,"notes":[[0]]}}}"#).contains("`every`"))
    // a pattern note past `until` is simply not played; a plain note past `steps` is an error
    #expect(
      message(#"{"steps":16,"parts":{"kick":{"every":8,"until":12,"notes":[[0],[6]]}}}"#) == "")
    #expect(
      message(#"{"steps":16,"parts":{"kick":{"from":8,"notes":[[10]]}}}"#).contains("past `steps`"))
  }
}

struct DJComposeSkillTests {
  /// The skill's worked example stays a valid roll: 16 bars, every role the right size.
  @Test func theSkillExampleBuildsAPlayableRoll() throws {
    let params = try JSONValue.parse(skillExampleText())
    let p = try #require(Share(payload: PianoRoll.envelope(params)).rawNetsProject())
    #expect(p.tempo == 124)
    #expect(p.nets["kick"]?.places.count == 256 && p.nets["kick"]?.bindings.count == 64)
    #expect(p.nets["clap"]?.bindings["t4"] == nil && p.nets["clap"]?.bindings["t68"]?.note == 39)
    #expect(
      p.nets["bass"]?.bindings["t66"]?.note == 45 && p.nets["bass"]?.bindings["t242"]?.note == 43)
    #expect(Set(p.nets.keys).isSuperset(of: ["harmony", "harmony-b", "harmony-c", "melody"]))
    #expect(
      p.nets["melody"]?.bindings["t128"]?.note == 72 && p.nets["melody"]?.bindings["t127"] == nil)
    #expect(p.nets["harmony"]?.track.instrument == "warm-pad")
  }
}

struct DJAgentDefinitionTests {
  /// Every dj-vevr-se tool the agent is given exists, and it can do the whole job.
  @Test func theAgentsToolsAreRealAndSufficient() throws {
    let text = djAgentText()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.first == "---" && lines.contains { $0.hasPrefix("name: dj") })
    let tools = try #require(lines.first { $0.hasPrefix("tools:") })
      .dropFirst("tools:".count).split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
    let mcp = tools.filter { $0.hasPrefix("mcp__dj-vevr-se__") }.map {
      String($0.dropFirst("mcp__dj-vevr-se__".count))
    }
    for t in mcp { #expect(MCPBridge.methods[t] != nil, "\(t) is not an MCP tool") }
    for needed in [
      "dj_state", "dj_perform", "dj_set", "dj_compose", "dj_inspired", "dj_compositions",
    ] {
      #expect(mcp.contains(needed), "the DJ needs \(needed)")
    }
    // what the DJ must not have: nothing that publishes, edits settings, or runs a shell
    #expect(!tools.contains("Bash") && !tools.contains("Write") && !tools.contains("Edit"))
    #expect(!mcp.contains("dj_settings"))
    #expect(text.contains("dj-compose") && text.contains("Never publish"))
  }
}
