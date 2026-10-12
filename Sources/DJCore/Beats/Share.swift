// Port of beats' share/url.js `shareFromPayload` and the model-relevant part of
// share/apply.js: a share-v1 envelope → `{ genre, params, overrides, … }` → project.
//
// What the browser does with it (petri-note.js `_bootGenerate`): sends
// `generate(genre, params)` to the worker, which runs `compose(genre, params)`.
// `overrides` is layered on afterwards by the UI. Notably `tempo` / `swing` /
// `humanize` in `overrides` are NOT applied to a composed project — they only
// feed the raw-`nets` path and the history list — so `Share.project()` doesn't
// either. Raw-`nets` envelopes load literally and, with a `structure`, are expanded by
// `arrangeWithOpts` (ShareURL.swift); composed ones get the overlay directives (`fadeIn`,
// `drumBreak`, `feelCurve`, `counterMelody`) after the overrides. URL / gzip decoding is
// ShareURL.swift + ShareCodec.swift.

public struct Share {
  public var genre: String?
  public var name: String?
  /// Passed straight to `compose` as its overrides: seed, structure, cohesion, macroCurve,
  /// then every trait key, in that insertion order.
  public var params: JSONObject
  /// Post-generation UI/project layers: tracks, fx, feel, autoDj, macrosDisabled,
  /// initialMutes, tempo, swing, humanize, note. nil when the payload had none.
  public var overrides: JSONObject?
  public var nets: JSONValue?
  public var structure: JSONValue?
  public var arrangeSeed: Double?
  public var velocityDeltas: JSONValue?
  public var maxVariants: Double?
  public var fadeIn: [JSONValue]?
  public var drumBreak: Double?
  public var sections: [JSONValue]?
  public var feelCurve: [JSONValue]?
  public var macroCurve: [JSONValue]?
  public var counterMelody: [JSONValue]?
  public var cid: String?
  public var parents: [JSONValue]?
  /// The envelope as given (not part of `shareFromPayload`'s result; a raw-`nets` deck
  /// carries it, `DeckSourceDescriptor.rawNets`).
  public var payload: JSONValue

  /// `shareFromPayload(payload, cid)`
  public init(payload p: JSONValue, cid: String? = nil) {
    payload = p
    var params = JSONObject()
    if let seed = p["seed"], case .number = seed { params["seed"] = seed }
    if let s = p["structure"], s.isTruthy { params["structure"] = s }
    if let c = p["cohesion"]?.string, c == "v1" || c == "v2" {
      params["cohesion"] = .string(c)
    } else {
      // Sealed envelopes without the field predate cohesion v2: pin legacy explicitly.
      params["cohesion"] = .string("v1")
    }
    if let mc = p["macroCurve"], mc.array != nil { params["macroCurve"] = mc }
    // Object.assign(params, traits): objects copy their entries; arrays copy by index.
    switch p["traits"] {
    case .object(let t)?: for (k, v) in t.entries { params[k] = v }
    case .array(let a)?: for (i, v) in a.enumerated() { params[String(i)] = v }
    default: break
    }

    var ov = JSONObject()
    for key in ["tracks", "fx", "feel", "autoDj", "macrosDisabled", "initialMutes"] {
      if let v = p[key], v.isTruthy { ov[key] = v }
    }
    for key in ["tempo", "swing", "humanize"] {
      if let v = p[key], case .number = v { ov[key] = v }
    }
    if let n = p["note"], case .string = n { ov["note"] = n }

    func number(_ k: String) -> Double? { p[k]?.double }
    func list(_ k: String) -> [JSONValue]? { p[k]?.array }
    func truthy(_ k: String) -> JSONValue? { p[k].flatMap { $0.isTruthy ? $0 : nil } }

    genre = p["genre"]?.string
    name = p["name"].flatMap { $0.isTruthy ? $0.string : nil }
    self.params = params
    overrides = ov.entries.isEmpty ? nil : ov
    nets = truthy("nets")
    structure = truthy("structure")
    arrangeSeed = number("arrangeSeed")
    velocityDeltas = truthy("velocityDeltas")
    maxVariants = number("maxVariants")
    fadeIn = list("fadeIn")
    drumBreak = number("drumBreak")
    sections = list("sections")
    feelCurve = list("feelCurve")
    macroCurve = list("macroCurve")
    counterMelody = list("counterMelody")
    self.cid = cid.flatMap { $0.isEmpty ? nil : $0 }
    parents = list("parents")
  }

  /// The object `shareFromPayload` returns, as JSON (`undefined` fields omitted).
  public func toJSON() -> JSONValue {
    func v(_ x: JSONValue?) -> JSONValue { x ?? .null }
    func a(_ x: [JSONValue]?) -> JSONValue { x.map { .array($0) } ?? .null }
    var o = JSONObject()
    if let genre { o["genre"] = .string(genre) }
    o["name"] = name.map { .string($0) } ?? .null
    o["params"] = .object(params)
    o["overrides"] = overrides.map { .object($0) } ?? .null
    o["nets"] = v(nets)
    o["structure"] = v(structure)
    o["arrangeSeed"] = arrangeSeed.map { .number($0) } ?? .null
    o["velocityDeltas"] = v(velocityDeltas)
    o["maxVariants"] = maxVariants.map { .number($0) } ?? .null
    o["fadeIn"] = a(fadeIn)
    o["drumBreak"] = drumBreak.map { .number($0) } ?? .null
    o["sections"] = a(sections)
    o["feelCurve"] = a(feelCurve)
    o["macroCurve"] = a(macroCurve)
    o["counterMelody"] = a(counterMelody)
    o["cid"] = cid.map { .string($0) } ?? .null
    o["parents"] = a(parents)
    return .object(o)
  }

  /// Decode envelope JSON text. When `cid` is given the payload is re-hashed and must
  /// match it — the browser refuses mismatches ("never trust what the server returns").
  public static func decode(json text: String, cid: String? = nil) throws -> Share {
    let payload = try JSONValue.parse(text)
    if let cid, BeatsCID.shareCID(payload) != cid { throw ShareError.cidMismatch }
    return Share(payload: payload, cid: cid)
  }

  /// The project the browser ends up with: for a raw-`nets` envelope `rawNetsProject()`;
  /// otherwise the composer path, `compose(genre, params)`, then the model-level overrides,
  /// then the arrange overlay (`overlayProject`). nil for a payload with no genre (the JS
  /// throws there).
  public func project() -> Project? {
    if nets != nil { return rawNetsProject() }
    guard let genre else { return nil }
    var proj = compose(genre: genre, overrides: .object(params))
    finishComposed(&proj)
    return proj
  }

  /// What the browser layers on a composed project, in its order: the model-level overrides
  /// (`_applyProjectSync`), then the arrange overlay (`overlayProject`). Shared with the decks
  /// (`TrackSpec.finish`).
  public func finishComposed(_ proj: inout Project) {
    if let overrides { proj.applyShareOverrides(overrides) }
    overlayProject(&proj)
  }

  /// The browser's `_pendingOverlay`: set when the envelope has `fadeIn` (an empty list
  /// counts), a non-zero `drumBreak`, `feelCurve` or `counterMelody`. (`macroCurve` rides in
  /// `params` and is applied by compose.)
  public var hasOverlay: Bool {
    fadeIn != nil || (drumBreak.map { $0 != 0 && !$0.isNaN } ?? false) || feelCurve != nil
      || counterMelody != nil
  }

  /// The overlay `arrangeWithOpts(…, { overlayOnly: true, … })` the browser runs on a composed
  /// project once the worker has produced it, after the overrides (`_applyProjectSync` applies
  /// them first). Runs on the parsed project, so `counterMelody` works — in the browser the
  /// overlay runs on plain JSON and a counter-melody throws (deliberate deviation: ROADMAP 2.8,
  /// GO-DIVERGENCE.md). A throw leaves the project as composed: the browser catches it and
  /// never sends the half-built project to the worker.
  public func overlayProject(_ proj: inout Project) {
    guard hasOverlay, nets == nil else { return }
    var opts = ArrangeOpts()
    opts.overlayOnly = true
    opts.fadeIn = fadeIn ?? []
    opts.drumBreak = drumBreak ?? 0
    opts.feelCurve = feelCurve ?? []
    opts.counterMelody = counterMelody ?? []
    var overlaid = proj
    let g = genre.flatMap { $0.isEmpty ? nil : $0 } ?? "wrapped"
    if (try? arrangeWithOpts(&overlaid, genre: g, size: "", opts: opts)) != nil { proj = overlaid }
  }
}

public enum ShareError: Error {
  case cidMismatch
  /// share URL / gzip decoding (ShareCodec)
  case badBase64, badGzip
}

extension Project {
  /// The parts of `applyShareOverrides` that change the project model: per-channel
  /// `tracks` (mix merge, instrument, instrumentSet) and `initialMutes`.
  public mutating func applyShareOverrides(_ ov: JSONObject) {
    if let tracks = ov["tracks"]?.object {
      for (ch, o) in tracks.entries {
        guard let chNum = parseIntPrefix(ch) else { continue }
        for id in nets.keys {
          guard var net = nets[id], net.role != "control", net.track.channel == chNum else {
            continue
          }
          if let mix = o["mix"], mix.isTruthy {
            var merged = net.track.mix?.object ?? JSONObject()
            for (k, v) in mix.object?.entries ?? [] { merged[k] = v }
            net.track.mix = .object(merged)
          }
          if let inst = o["instrument"]?.string, !inst.isEmpty { net.track.instrument = inst }
          if let set = o["instrumentSet"], set.isTruthy, let arr = set.array {
            net.track.instrumentSet = arr
          }
          nets[id] = net
        }
      }
    }
    if let muted = ov["initialMutes"]?.array { initialMutes = muted.compactMap(\.string) }
  }
}

/// JS `parseInt(s)` for the integer-ish channel keys envelopes use.
private func parseIntPrefix(_ s: String) -> Int? {
  var digits = ""
  var seenSign = false
  for c in s.drop(while: { $0 == " " }) {
    if digits.isEmpty && !seenSign && (c == "-" || c == "+") {
      seenSign = true
      digits.append(c)
    } else if c.isASCII && c.isNumber {
      digits.append(c)
    } else {
      break
    }
  }
  return Int(digits)
}
