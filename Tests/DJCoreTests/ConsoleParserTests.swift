import Testing

@testable import DJCore

struct ConsoleParserTests {
  func tool(_ line: String) -> (String, String, JSONValue)? {
    if case .tool(let n, let m, let p) = ConsoleParser.parse(line) { return (n, m, p) }
    return nil
  }

  @Test func everyMCPToolIsAConsoleCommandWithItsHelp() {
    let catalog = MCPBridge.catalog
    #expect(catalog.count == MCPBridge.methods.count && catalog.count >= 25)
    for t in catalog {
      #expect(MCPBridge.methods[t.name] == t.method)
      #expect(!t.description.isEmpty && !t.summary.isEmpty)
      guard case .success(let again) = ConsoleParser.resolve(t.shortName) else {
        Issue.record("\(t.shortName) doesn't resolve")
        continue
      }
      #expect(again.name == t.name)
      #expect(ConsoleHelp.overview().contains(t.shortName))
      #expect(ConsoleHelp.detail(t.name).contains(t.name))
    }
  }

  @Test func toolsTakeShortOrFullNamesAndNoArguments() {
    for line in ["state", "dj_state", "STATE", "  state  "] {
      #expect(
        tool(line)?.0 == "dj_state" && tool(line)?.1 == "state"
          && tool(line)?.2 == .object(JSONObject()))
    }
  }

  @Test func bareWordsFillTheUsualFirstArgumentsAndKeyValuesReadAsJSON() throws {
    let a = try #require(tool("set show first-night"))
    #expect(a.2["action"]?.string == "show" && a.2["set"]?.string == "first-night")
    let b = try #require(
      tool("set action=plan set=fri count=6 shape=arc bpm=[124,150] keepItems=true"))
    #expect(b.2["count"]?.double == 6 && b.2["shape"]?.string == "arc")
    #expect(
      b.2["bpm"]?.array?.compactMap(\.double) == [124, 150] && b.2["keepItems"]?.bool == true)
    let c = try #require(tool("generate A techno 42 structure=standard"))
    #expect(
      c.2["deck"]?.string == "A" && c.2["genre"]?.string == "techno" && c.2["seed"]?.double == 42)
    #expect(c.2["structure"]?.string == "standard")
    // an explicit key wins over a bare word that would have gone to the same slot
    let d = try #require(tool("set action=mix first-night"))
    #expect(d.2["action"]?.string == "mix" && d.2["set"]?.string == "first-night")
  }

  @Test func performTakesItsFieldsLooseAndWrapsThemInTheAction() throws {
    let a = try #require(tool("perform op=crossfader value=0"))
    #expect(
      a.2["action"] == .object(JSONObject([("op", .string("crossfader")), ("value", .number(0))])))
    let b = try #require(tool("perform play A on=true"))
    let act = try #require(b.2["action"]?.object)
    #expect(act["op"]?.string == "play" && act["deck"]?.string == "A" && act["on"]?.bool == true)
  }

  @Test func aJSONObjectMergesAndQuotesGroup() throws {
    let a = try #require(
      tool(#"compose {"deck":"A","tempo":126,"parts":{"kick":{"notes":[[0],[4]]}}}"#))
    #expect(
      a.1 == "composeRoll" && a.2["deck"]?.string == "A"
        && a.2["parts"]?["kick"]?["notes"]?.array?.count == 2)
    let b = try #require(tool(#"load_share A "https://beats.bitwrap.io/?cid=x&z=y""#))
    #expect(b.2["link"]?.string == "https://beats.bitwrap.io/?cid=x&z=y")
    let c = try #require(
      tool(#"inspired inspiredBy="Daft Punk" name='A B' parts={"kick":{"notes":[[0]]}}"#))
    #expect(c.2["inspiredBy"]?.string == "Daft Punk" && c.2["name"]?.string == "A B")
    #expect(c.2["parts"]?["kick"] != nil)
  }

  @Test func rawBuiltinsAndTheAgentCommand() {
    #expect(
      ConsoleParser.parse("raw loadShare deck=A")
        == .raw(method: "loadShare", params: .object(JSONObject([("deck", .string("A"))]))))
    #expect(
      ConsoleParser.parse("help") == .help(nil) && ConsoleParser.parse("help set") == .help("set"))
    #expect(
      ConsoleParser.parse("tools") == .tools(nil) && ConsoleParser.parse("ls dub") == .tools("dub"))
    #expect(ConsoleParser.parse("clear") == .clear && ConsoleParser.parse("history") == .history)
    #expect(ConsoleParser.parse("") == .blank && ConsoleParser.parse("# note") == .blank)
    #expect(ConsoleParser.parse("agent") == .agent("status", ""))
    #expect(
      ConsoleParser.parse("agent say more energy, darker") == .agent("say", "more energy, darker"))
    #expect(ConsoleParser.parse("agent budget 5") == .agent("budget", "5"))
  }

  @Test func mistakesSayWhatToDo() {
    func error(_ line: String) -> String {
      if case .error(let m) = ConsoleParser.parse(line) { return m }
      return ""
    }
    #expect(error("frobnicate").contains("unknown command"))
    #expect(error("compos").contains("ambiguous"))
    #expect(error("state now").contains("no argument"))
    #expect(error("set show {oops").contains("unbalanced"))
    #expect(error(#"set "open"#).contains("unterminated"))
    #expect(error("raw").contains("method"))
  }

  @Test func completionOffersToolsThenTheToolsArguments() {
    #expect(
      ConsoleParser.complete("se").contains("set")
        && ConsoleParser.complete("se").contains("settings"))
    #expect(
      ConsoleParser.complete("").contains("help") && ConsoleParser.complete("").contains("state"))
    let args = ConsoleParser.complete("set ")
    #expect(args.contains("action=") && args.contains("set=") && args.contains("leadBars="))
    #expect(ConsoleParser.complete("set lead") == ["leadBars="])
    #expect(!ConsoleParser.complete("set action=show ").contains("action="))
    #expect(ConsoleParser.complete("set action=sh").isEmpty)
  }
}
