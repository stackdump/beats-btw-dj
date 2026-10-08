// Port of beats' share/url.js `shareFromPayload` and the model-relevant part of
// share/apply.js: a share-v1 envelope → `{ genre, params, overrides, … }` → project.
//
// What the browser does with it (petri-note.js `_bootGenerate`): sends
// `generate(genre, params)` to the worker, which runs `compose(genre, params)`.
// `overrides` is layered on afterwards by the UI. Notably `tempo` / `swing` /
// `humanize` in `overrides` are NOT applied to a composed project — they only
// feed the raw-`nets` path and the history list — so `Share.project()` doesn't
// either. Raw-`nets` envelopes need arrangeWithOpts and are a later slice.

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

  /// `shareFromPayload(payload, cid)`
  public init(payload p: JSONValue, cid: String? = nil) {
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

  /// The project the composer path produces: `compose(genre, params)` then the
  /// model-level overrides. nil for raw-`nets` envelopes (not ported yet) and for a
  /// payload with no genre (the JS throws there).
  public func project() -> Project? {
    guard nets == nil, let genre else { return nil }
    var proj = compose(genre: genre, overrides: .object(params))
    if let overrides { proj.applyShareOverrides(overrides) }
    return proj
  }
}

public enum ShareError: Error { case cidMismatch }

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
