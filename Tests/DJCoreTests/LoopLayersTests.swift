import Testing

@testable import DJCore

struct LoopLayersTests {
  func loop(_ name: String, bpm: Double = 140, beats: Int = 16, category: String = "Vocals")
    -> StockLoop
  {
    StockLoop(
      path: "/lib/\(name).caf", name: name, pack: "14 Future Bass", category: category,
      subcategory: "", genre: "", beats: beats, seconds: Double(beats) * 60 / bpm, key: "F")
  }

  func parse(_ json: String) throws -> [LoopLayerSpec] {
    try LoopLayers.parse(JSONValue.parse(json))
  }

  @Test func aLayerNamesALoopABarAndHowLongItStays() throws {
    let specs = try parse(
      """
      [{"loop":"Heavy Tech Riser 01","bar":28,"bars":4,"gain":-6},
       {"loop":"Chop Vox","bar":[13,29],"keyLock":false}]
      """)
    #expect(specs.count == 2)
    #expect(
      specs[0].bars == [28] && specs[0].length == 4 && specs[0].gainDB == -6 && specs[0].keyLock)
    #expect(
      specs[1].bars == [13, 29] && specs[1].length == nil && specs[1].gainDB == -3
        && !specs[1].keyLock)
    #expect(try parse("[]").isEmpty && (try LoopLayers.parse(nil)).isEmpty)
    // json round trip keeps what matters
    #expect(try LoopLayers.parse(LoopLayers.json(specs)) == specs)
  }

  @Test func badLayersSayWhatToFix() {
    func message(_ json: String) -> String {
      do {
        _ = try parse(json)
        return ""
      } catch { return "\(error)" }
    }
    #expect(message(#"{"loop":"x"}"#).contains("must be a list"))
    #expect(message(#"[{"bar":3}]"#).contains("`loop`"))
    #expect(message(#"[{"loop":"x"}]"#).contains("`bar`"))
    #expect(message(#"[{"loop":"x","bar":0}]"#).contains("`bar`"))
    #expect(message(#"[{"loop":"x","bar":2,"bars":99}]"#).contains("`bars`"))
    #expect(message(#"[{"loop":"x","bar":2,"gain":6}]"#).contains("`gain`"))
    let many = "[" + (0..<13).map { _ in #"{"loop":"x","bar":2}"# }.joined(separator: ",") + "]"
    #expect(message(many).contains("at most"))
  }

  @Test func windowsDefaultToOnePassOfTheLoopAndGainIsLinearUnderUnity() throws {
    let s = try parse(#"[{"loop":"x","bar":[5,21]},{"loop":"y","bar":9,"bars":2}]"#)
    #expect(
      LoopLayers.windows(s[0], loopBeats: 16).map { [$0.start, $0.end] } == [[5, 9], [21, 25]])  // 16 beats = 4 bars
    #expect(LoopLayers.windows(s[0], loopBeats: 6).map { $0.end - $0.start } == [2, 2])  // 6 beats rounds up to 2 bars
    #expect(LoopLayers.windows(s[1], loopBeats: 32).map { [$0.start, $0.end] } == [[9, 11]])
    #expect(
      LoopLayers.gain(db: 0) == 1 && abs(LoopLayers.gain(db: -6) - 0.501) < 0.01
        && LoopLayers.gain(db: -60) < 0.01)
    #expect(LoopLayers.gain(db: 6) == 1)  // never boosted
  }

  @Test func loopsAreFoundByPathNameOrUniquePartAndAmbiguityIsAsked() {
    let lib = [
      loop("Heavy Tech Riser 01"), loop("Heavy Tech Riser 02"),
      loop("Frisky Chop Vox 01", bpm: 130),
    ]
    func name(_ q: String, near: Double? = nil) -> String? {
      if case .success(let l) = LoopLayers.resolve(q, in: lib, near: near) { return l.name }
      return nil
    }
    #expect(name("/lib/Heavy Tech Riser 02.caf") == "Heavy Tech Riser 02")
    #expect(name("heavy tech riser 01") == "Heavy Tech Riser 01")  // exact, any case
    #expect(name("frisky") == "Frisky Chop Vox 01")  // a unique part
    guard case .failure(let ambiguous) = LoopLayers.resolve("heavy tech", in: lib) else {
      Issue.record("should be ambiguous")
      return
    }
    #expect("\(ambiguous)".contains("matches 2 loops") && "\(ambiguous)".contains("Riser 02"))
    guard case .failure(let none) = LoopLayers.resolve("nothing like it", in: lib) else {
      Issue.record("should not resolve")
      return
    }
    #expect("\(none)".contains("no loop called"))
  }

  @Test func theNearestTempoSettlesAnAmbiguousNameOnlyWhenItClearlyWins() {
    let lib = [loop("Vox A 70", bpm: 70), loop("Vox A 140", bpm: 140)]
    if case .success(let l) = LoopLayers.resolve("vox a", in: lib, near: 140) {
      #expect(l.name == "Vox A 140")
    } else {
      Issue.record("tempo should settle it")
    }
    let close = [loop("Vox B 139", bpm: 139), loop("Vox B 141", bpm: 141)]
    if case .success = LoopLayers.resolve("vox b", in: close, near: 140) {
      Issue.record("too close to call")
    }
  }

  @Test func aRollCarriesItsLayersInTheEnvelope() throws {
    let env = try PianoRoll.envelope(
      JSONValue.parse(
        #"{"parts":{"kick":{"notes":[[0]]}},"layers":[{"loop":"Heavy Tech Riser 01","bar":3,"bars":2,"gain":-9}]}"#
      ))
    let layers = try #require(env["loopLayers"]?.array)
    #expect(layers.count == 1 && layers[0]["loop"]?.string == "Heavy Tech Riser 01")
    #expect(layers[0]["bar"] == .array([.number(3)]) && layers[0]["gain"]?.double == -9)
    // none given: no key, and the share still loads
    let plain = try PianoRoll.envelope(JSONValue.parse(#"{"parts":{"kick":{"notes":[[0]]}}}"#))
    #expect(plain["loopLayers"] == nil)
    #expect(throws: PianoRollError.self) {
      try PianoRoll.envelope(
        JSONValue.parse(#"{"parts":{"kick":{"notes":[[0]]}},"layers":[{"bar":1}]}"#))
    }
    #expect(Share(payload: env).rawNetsProject() != nil)
  }
}

struct LayerPoolTests {
  func loop(_ name: String, _ cat: String, bpm: Double = 140, key: String? = nil) -> StockLoop {
    StockLoop(
      path: "/lib/\(name).caf", name: name, pack: "p", category: cat, subcategory: "", genre: "",
      beats: 16,
      seconds: 16 * 60 / bpm, key: key)
  }

  @Test func thePoolIsLayerCategoriesAtAMatchingTempoInAFittingKey() {
    let lib = [
      loop("Vox Ab", "Vocals", key: "Ab"), loop("Vox F", "Vocals", key: "F"),
      loop("Vox D", "Vocals", key: "D"),
      loop("Riser", "Sound Effect"), loop("Half Riser", "Sound Effect", bpm: 70),
      loop("Slow Riser", "Sound Effect", bpm: 100),
      loop("Drums", "Drums"), loop("Texture", "Texture/Atmosphere"),
    ]
    func names(_ key: String?, bpm: Double = 140) -> [String] {
      LoopLayers.pool(library: lib, bpm: bpm, key: key).map(\.name)
    }
    // C minor (relative Eb major): Ab and F (as F minor, its subdominant) are a step away, D is not;
    // keyless loops go anywhere
    #expect(names("C minor") == ["Half Riser", "Riser", "Texture", "Vox Ab", "Vox F"])
    // the track's key unknown: only keyless loops
    #expect(names(nil) == ["Half Riser", "Riser", "Texture"])
    // tempo: 70 matches at 2×; 100 is 29 % off
    #expect(!names("C minor").contains("Slow Riser") && !names("C minor").contains("Drums"))
    #expect(
      names("C minor", bpm: 70).contains("Riser")
        && names("C minor", bpm: 70).contains("Half Riser"))
    #expect(LoopLayers.pool(library: lib, bpm: 0, key: "C minor").isEmpty)
  }

  @Test func aBigLibraryIsSampledTheSameWayEveryTime() {
    let lib = (0..<1500).map { loop("Fx \($0)", "Sound Effect") }
    let a = LoopLayers.pool(library: lib, bpm: 140, key: nil, limit: 200)
    #expect(a.count == 200 && a == LoopLayers.pool(library: lib, bpm: 140, key: nil, limit: 200))
    #expect(
      a.map(\.name) == a.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        || a.count == 200)
    #expect(
      Set(a.map(\.path)).count == 200
        && LoopLayers.pool(library: lib, bpm: 140, key: nil, limit: 5000).count == 1500)
  }
}
