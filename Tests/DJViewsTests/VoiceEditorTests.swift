import DJCore
import Testing

@testable import DJViews

/// The sound panel: what it sends and shows (ImageRenderer can't draw its AppKit sliders, so
/// these assert the model), and its control-socket face.
@MainActor
struct VoiceEditorTests {
  func model() async throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites(), voices: temporaryVoiceVariations())
    m.start()
    _ = try await m.control(
      "generate", try JSONValue.parse(#"{"deck":"A","genre":"techno","seed":42,"structure":"minimal"}"#))
    m.poll()
    return m
  }

  @Test func theSliderSendsALiveTweakAndResetPutsTheVoiceBack() async throws {
    let m = try await model()
    let s = try #require(m.decks["A"])
    let melody = try #require(s.voices.first { $0.role.contains("melody") })
    let cv = try #require(s.channelVoices[melody.channel])
    #expect(cv.instrument == melody.instrument && cv.tonal)
    let rec = try SessionRecorder.start(on: try #require(m.engine))
    m.setVoiceTweak("A", channel: melody.channel, VoiceTweak(gainDB: 3, lowpass: 1200))
    #expect(m.decks["A"]?.voiceSettings[melody.channel]?.tweak.lowpass == 1200)
    #expect(m.engine?["A"]?.voiceTweak(melody.channel).gainDB == 3)
    m.setVoiceTweak("A", channel: melody.channel, VoiceTweak())
    #expect(m.decks["A"]?.voiceSettings[melody.channel] == nil)
    let events = rec.finish().events
    #expect(events.count == 2, "each tweak is a recorded action")
    // the panel's labels carry units, and its sliders map back to the values
    #expect(VoiceParam.lowpass.label(0) == "Brightness off")
    #expect(VoiceParam.lowpass.label(2400) == "Brightness 2.4 kHz")
    #expect(VoiceParam.attack.label(0.012) == "Attack 12 ms")
    #expect(VoiceParam.gainDB.label(3) == "Level +3.0 dB")
    for p in VoiceParam.allCases {
      for x in [0.0, 0.25, 0.5, 1.0] {
        #expect(abs(p.position(p.value(x)) - x) < 1e-9 || (p == .lowpass && x == 0), "\(p) \(x)")
      }
    }
  }

  @Test func aSavedVariationIsAChipThatPlaysIt() async throws {
    let m = try await model()
    let melody = try #require(m.decks["A"]?.voices.first { $0.role.contains("melody") })
    let ch = melody.channel
    let t = VoiceTweak(attack: 0.05, pitchFrom: 2, pitchTo: 1, pitchTime: 0.1)
    m.setVoiceTweak("A", channel: ch, t)
    m.saveVariation(
      melody.instrument, name: "short zap",
      try #require(m.decks["A"]?.voiceSettings[ch]))
    #expect(m.variations[melody.instrument]?.map(\.name) == ["short zap"])
    #expect(m.variationStore.list(melody.instrument).count == 1, "kept on disk")
    #expect(m.currentVariation(melody.instrument, m.decks["A"]?.voiceSettings[ch])?.name == "short zap")
    // back to the instrument, then one click on the chip
    m.setVoiceTweak("A", channel: ch, VoiceTweak())
    let v = try #require(m.variations[melody.instrument]?.first)
    #expect(await m.applyVariation("A", channel: ch, instrument: melody.instrument, v))
    #expect(m.decks["A"]?.voiceSettings[ch]?.tweak == t)
    m.renameVariation(melody.instrument, "short zap", to: "zap")
    #expect(m.variations[melody.instrument]?.map(\.name) == ["zap"])
    m.deleteVariation(melody.instrument, "zap")
    #expect(m.variations[melody.instrument] == nil)
  }

  @Test func theControlSocketTweaksAndStateShowsIt() async throws {
    let m = try await model()
    let state = try await m.control("state", .object(JSONObject()))
    let voices = try #require(state["decks"]?["A"]?["voices"]?.array)
    let melody = try #require(voices.first { $0["role"]?.string?.contains("melody") == true })
    let ch = try #require(melody["channel"]?.int)
    #expect(melody["tweak"] == .object(JSONObject()))
    let out = try await m.control(
      "perform",
      try JSONValue.parse(
        "{\"action\":{\"op\":\"voiceTweak\",\"deck\":\"A\",\"channel\":\(ch),\"params\":{\"gainDB\":-6}}}"))
    let after = try #require(out["voices"]?.array?.first { $0["channel"]?.int == ch })
    #expect(after["tweak"]?["gainDB"]?.double == -6)
    await #expect {
      try await m.control(
        "perform",
        try JSONValue.parse(#"{"action":{"op":"voiceSynth","deck":"A","channel":99,"on":true}}"#))
    } throws: { "\($0)".contains("nothing on channel 99") }
    await #expect {
      try await m.control(
        "perform",
        try JSONValue.parse(#"{"action":{"op":"voiceTweak","deck":"B","channel":1,"params":{}}}"#))
    } throws: { "\($0)".contains("needs a net deck") }
  }
}
