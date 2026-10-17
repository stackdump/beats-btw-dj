import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// The deck's sound section: the palette chooser and its fine-tune area, what they send and
/// show, the control socket's palettes, and the panel drawn (`DJ_SHOT_DIR=… make swift-shots
/// FILTER=SoundPanelView` writes the PNGs).
@MainActor
struct SoundPanelViewTests {
  func model() async throws -> AppModel {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    dj.deterministic = true
    dj["A"]!.loadDemo()
    dj["B"]!.loadDemo()
    try dj.start()
    let m = AppModel(engine: dj, favorites: temporaryFavorites())
    m.defaults = scratchDefaults()
    m.start()
    _ = try await call(
      m, "generate", #"{"deck":"A","genre":"house","seed":11,"structure":"standard"}"#)
    m.poll()
    return m
  }

  func call(_ m: AppModel, _ method: String, _ params: String = "{}") async throws -> JSONValue {
    try await m.control(method, try JSONValue.parse(params))
  }

  /// A palette card and a fine-tune choice are recorded pokes, and the panel's state follows.
  @Test func theChooserAndFineTuneArePokes() async throws {
    let m = try await model()
    let s = try #require(m.decks["A"])
    #expect(s.palette == nil, "a new track plays the default")
    #expect(PaletteCard.cards(current: s.palette).first(where: \.selected)?.id == "studio")
    #expect(!s.roleSounds.isEmpty)
    let rec = try SessionRecorder.start(on: try #require(m.engine))
    m.setPalette("A", "lofi")
    #expect(SoundPalette.named(m.decks["A"]?.palette)?.id == "lofi")
    let melody = try #require(m.decks["A"]?.roleSounds.first { $0.role == "melody" })
    #expect(melody.choices.first?.option == SoundPalette.named("lofi")?.pool("melody")?.first)
    m.setRoleVoice("A", "melody", "gm:73")
    let row = try #require(m.decks["A"]?.roleSounds.first { $0.role == "melody" })
    #expect(row.override == "gm:73" && row.playing == "Flute")
    m.setRoleVoice("A", "melody", nil)
    #expect(m.decks["A"]?.roleSounds.first { $0.role == "melody" }?.isOverridden == false)
    #expect(
      rec.finish().events.map(\.kind) == [
        .action(.setPalette(deck: "A", palette: "lofi")),
        .action(.setRoleVoice(deck: "A", role: "melody", voice: "gm:73")),
        .action(.setRoleVoice(deck: "A", role: "melody", voice: nil)),
      ])
  }

  /// The Generate panel's spec keeps the deck's sound, or takes the palette chosen there.
  @Test func generateCarriesTheDecksPaletteOrTheChosenOne() async throws {
    let m = try await model()
    m.setPalette("A", "jazz")
    m.setRoleVoice("A", "bass", "gm:33")
    let fresh = TrackSpec(genre: "techno", seed: 5, structure: "minimal")
    let kept = m.generateSpec("A", fresh, palette: nil)
    #expect(SoundPalette.named(kept.palette)?.id == "jazz")
    let chosen = m.generateSpec("A", fresh, palette: "club")
    #expect(chosen.palette == "club")
    #expect(chosen.project().soundNet("bass")?.track.sound.option == "gm:33", "overrides stay")
    #expect(m.generateSpec("A", fresh, palette: "studio").palette == nil)
    // the socket's generate does the same, and takes a palette
    let a = try await call(
      m, "generate",
      #"{"deck":"A","genre":"techno","seed":5,"structure":"minimal","palette":"ambient"}"#)
    #expect(a["palette"]?.string == "ambient")
    await #expect {
      try await call(m, "generate", #"{"deck":"A","genre":"techno","seed":5,"palette":"nope"}"#)
    } throws: { "\($0)".contains("dj_palettes") }
  }

  /// dj_palettes lists every palette with what plays here; dj_state shows each role's sound;
  /// dj_perform sets them and says what is wrong.
  @Test func theSocketListsAndSetsPalettes() async throws {
    let m = try await model()
    let list = try await call(m, "palettes", #"{"deck":"A"}"#)
    let ids = (list["palettes"]?.array ?? []).compactMap { $0["id"]?.string }
    #expect(ids == SoundPalette.all.map(\.id))
    #expect(list["palettes"]?.array?.first { $0["id"]?.string == "retro" }?["localOnly"] == .bool(true))
    #expect(list["palettes"]?.array?.first { $0["id"]?.string == "studio" }?["playing"] == .bool(true))
    #expect((list["sound"]?.array ?? []).contains { $0["role"]?.string == "melody" })
    let a = try await call(
      m, "perform", #"{"action":{"op":"setPalette","deck":"A","palette":"synthwave"}}"#)
    #expect(a["palette"]?.string == "synthwave")
    let b = try await call(
      m, "perform",
      #"{"action":{"op":"setRoleVoice","deck":"A","role":"bass","voice":"synth:acid"}}"#)
    let bass = (b["sound"]?.array ?? []).first { $0["role"]?.string == "bass" }
    #expect(bass?["override"]?.string == "synth:acid" && bass?["plays"]?.string == "acid")
    for (params, words) in [
      (#"{"action":{"op":"setPalette","deck":"A","palette":"polka"}}"#, "unknown palette"),
      (#"{"action":{"op":"setRoleVoice","deck":"A","role":"tuba","voice":"gm:58"}}"#, "no role"),
      (#"{"action":{"op":"setPalette","deck":"B","palette":"jazz"}}"#, "net deck"),
    ] {
      await #expect { try await call(m, "perform", params) } throws: { "\($0)".contains(words) }
    }
    #expect(try await call(m, "catalog")["palettes"]?.array?.count == SoundPalette.all.count)
  }

  /// The panel draws: the cards on top, fine-tune folded; unfolded, a row per role.
  @Test func thePanelDraws() async throws {
    let m = try await model()
    m.setPalette("A", "synthwave")
    m.setRoleVoice("A", "melody", "gm:81")
    let s = try #require(m.decks["A"])
    let panel = TrackPanel(name: "A", state: s, model: m, tint: DJStyle.deckA)
      .padding(8).background(Color(white: 0.12))
    savePNG(panel, width: 600, height: 420, name: "sound-palettes")
    let px = try #require(renderPixels(panel, width: 600, height: 420))
    // the selected card's accent (synthwave pink) is drawn
    var pink = 0
    for y in stride(from: 0, to: 420, by: 2) {
      for x in stride(from: 0, to: 600, by: 2) where px.near(x, y, (255, 45, 149), tol: 50) {
        pink += 1
      }
    }
    #expect(pink > 20, "the lit card's border")
    let fine = FineTune(name: "A", state: s, model: m, tint: DJStyle.deckA, editing: .constant(nil))
      .padding(8).background(Color(white: 0.12))
    savePNG(fine, width: 600, height: 900, name: "sound-finetune")
    #expect(renderPixels(fine, width: 600, height: 900) != nil)
  }
}
