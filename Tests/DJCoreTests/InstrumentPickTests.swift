import Testing

@testable import DJCore

struct InstrumentPickTests {
  let catalog = VoiceCatalog.shared

  @Test func aRoleBeatsListsNothingForStillHasInstruments() {
    let harmony = Deck.fallbackOptions("harmony")
    #expect(harmony.first == "am-pad" || harmony.first == "dark-pad" || harmony.first == "pad")
    #expect(harmony.contains("strings") && harmony.contains("choir") && !harmony.contains("acid"))
    #expect(!Deck.fallbackOptions("lead").contains("sub-bass"), "no basses for a lead")
  }

  @Test func aUsersInstrumentIsMarkedPickedAndTheCIDStaysBeats() {
    var p = TrackSpec(genre: "techno", seed: 42, structure: "minimal").project()
    let before = p.modelCID
    let melody = p.nets.values.first { $0.track.group == "melody" }!.track.channel
    #expect(p.nets.values.allSatisfy { !$0.track.picked }, "the composer's choices")
    p.applyShareOverrides(
      JSONObject([
        (
          "tracks",
          .object(
            JSONObject([
              ("\(melody)", .object(JSONObject([("instrument", .string("wobble-lead"))])))
            ]))
        )
      ]))
    let picked = p.nets.values.filter { $0.track.channel == melody && $0.role != "control" }
    #expect(
      !picked.isEmpty
        && picked.allSatisfy { $0.track.picked && $0.track.instrument == "wobble-lead" })
    #expect(p.modelCID == before, "the model CID is the song's structure, not its instruments")
    var q = p
    for id in q.nets.keys { q.nets[id]!.track.picked = false }
    #expect(q.modelCID == p.modelCID, "the mark itself is not in the CID")
  }

  @Test func aPickedInstrumentChoosesASoundByItsName() throws {
    let pool = catalog.pool("synth.lead")
    try #require(!pool.isEmpty, "needs Logic / GarageBand synth leads installed")
    // unpicked: every lead name plays the category's one pick, as tracks always have
    let a = catalog.sources(instrument: "sync-lead", role: "melody", seed: 7)
    let b = catalog.sources(instrument: "hoover", role: "melody", seed: 7)
    #expect(a?.first == b?.first)
    // picked: a sound whose name fits comes first when there is one
    for name in ["wobble-lead", "chiptune", "tape-lead"] {
      guard let fit = pool.first(where: { VoiceCatalog.matches($0.name, name) }) else { continue }
      let s = catalog.sources(instrument: name, role: "melody", seed: 7, picked: true)
      #expect(s?.first == fit.sources.first, "\(name) → \(fit.name)")
    }
    // and different picked names reach different sounds
    let names = ["sync-lead", "hoover", "supersaw", "lead", "duo-lead", "big-saw", "trance-lead"]
    let firsts = Set(
      names.compactMap {
        catalog.sources(instrument: $0, role: "melody", seed: 7, picked: true)?.first.map {
          "\($0)"
        }
      })
    #expect(firsts.count >= 4, "\(firsts.count) different sounds for \(names.count) names")
  }
}
