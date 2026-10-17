import Foundation

// Where a LOOP-record clip came from, kept with it (the library index, dj_state, the tile's ⓘ):
// what the deck was playing and how it was set when LOOP went down, so a loop can be traced
// back to its track and recreated. Crops and sequences say what they were made from.
//
// It is plain JSON (`JSONValue`), written once and never read back by the engine: nothing in
// it changes a clip's audio or its id.

extension Deck {
  /// What the deck holds, as a session would name it, whatever its transport (a session's
  /// `sourceDescriptor()` refuses a deck that is not at rest). A sample's content id is left
  /// for `LoopProvenance.finish` (hashing a whole track is not for the press).
  var playingSource: DeckSourceDescriptor? {
    switch mode {
    case .net:
      if let spec = currentSpec { return .net(spec) }
      if let payload = currentRawNets { return .rawNets(payload: payload) }
      return nil
    case .sample:
      guard loaded != nil else { return nil }
      return .sample(
        id: isDemo ? DeckSourceDescriptor.demoID : "", title: title, grid: beatGrid)
    }
  }
}

enum LoopProvenance {
  /// The deck as LOOP went down on it, at beat `startBeat` (the take's first downbeat).
  static func capture(_ d: Deck, startBeat: Double, build: String) -> JSONObject {
    var o = JSONObject([
      ("deck", .string(d.name)),
      ("recorded", .string(iso.string(from: Date()))),
      ("build", .string(build)),
      ("title", .string(d.title)),
      ("mode", .string(d.mode == .net ? "net" : "sample")),
      ("startBeat", .number(startBeat)),
      ("bar", .int(Int((startBeat / 4).rounded(.down)) + 1)),
    ])
    if let src = d.playingSource {
      o["source"] = src.json
      if let cid = src.favoriteCID { o["shareCID"] = .string(cid) }
    }
    var tempo = JSONObject([("pitch", .number(d.pitch))])
    if let b = d.baseBPM { tempo["baseBPM"] = .number(b) }
    if let b = d.effectiveBPM { tempo["bpm"] = .number(b) }
    o["tempo"] = .object(tempo)
    o["params"] = d.currentParams.json
    if d.mode == .net {
      if let i = d.currentSectionIndex {
        o["section"] = .object(
          JSONObject([("index", .int(i)), ("name", .string(d.sections[i].name))]))
      }
      let off = d.roles.filter { !d.isRoleOn($0) }
      if !off.isEmpty { o["rolesOff"] = .array(off.map { .string($0) }) }
      if !d.stemsMuted.isEmpty {
        o["stemsMuted"] = .array(d.stemsMuted.keys.sorted().map { .string($0) })
      }
      // the sounds it played from (a palette with its asset version, a sampled kit)
      if let p = d.palette { o["palette"] = .string(p) }
      if let k = d.kit { o["kit"] = .string(k) }
      let macros = d.wave.activeMacros.map { "\($0)" } + d.wave.activeMasterMacros.map(\.id)
      if !macros.isEmpty { o["macros"] = .array(macros.map { .string($0) }) }
    }
    return o
  }

  /// Fill in what is known at the end: the take's length and tempo, and a sample's content id
  /// (`buffer` is what was loaded).
  static func finish(_ o: JSONObject, bars: Int, bpm: Double, sample buffer: SampleBuffer?)
    -> JSONValue
  {
    var o = o
    o["bars"] = .int(bars)
    o["bpm"] = .number(bpm)
    if let buffer, case .object(var src)? = o["source"], src["kind"] == .string("sample"),
      src["id"] == .string("")
    {
      src["id"] = .string(buffer.contentID)
      o["source"] = .object(src)
    }
    return .object(o)
  }

  /// A crop of `parent`: its beats `from..<to`.
  static func crop(_ parent: LoopClip, from: Int, to: Int) -> JSONValue {
    var o = JSONObject([
      ("op", .string("crop")), ("from", .string(parent.id)),
      ("beats", .array([.int(from), .int(to)])),
    ])
    if let p = parent.provenance { o["parent"] = p }
    return .object(o)
  }

  /// A sequence of `steps` (each with its clip's own provenance, so it outlives the clips).
  static func sequence(_ steps: [(SequenceStep, LoopClip)]) -> JSONValue {
    .object(
      JSONObject([
        ("op", .string("sequence")),
        ("recorded", .string(iso.string(from: Date()))),
        (
          "steps",
          .array(
            steps.map { s, c in
              var o = JSONObject([
                ("clip", .string(c.id)), ("title", .string(c.title)),
                ("repeats", .int(s.repeats)),
              ])
              if let p = c.provenance { o["provenance"] = p }
              return .object(o)
            })
        ),
      ]))
  }

  nonisolated(unsafe) static let iso = ISO8601DateFormatter()
}
