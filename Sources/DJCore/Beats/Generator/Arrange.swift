import Foundation

// Port of generator/arrange.js beyond what compose() already uses (fade / break / feel /
// macro curves live in Structure.swift): `arrangeWithOpts` — the "arrangement DSL" that
// expands a raw-`nets` share into a song, and its overlay directives (fadeIn, drumBreak,
// feelCurve, macroCurve, counterMelody).
//
// The JS mutates whatever it is handed. Two facts about that matter and are modelled:
//  - `expandArrangeVariants` clones through JSON, and the counter-melody net is built as a
//    plain object, so after an arrange step some nets are no longer `NetBundle` instances.
//    `simulateMusicNotes` calls `nb.resetState()` on them and the JS throws. `ArrangeContext`
//    tracks which nets are in that state so Swift throws in exactly the same places.
//  - A share's `nets` reach arrange as unparsed wire JSON (`transitions[].midi`), where the
//    velocity tweak finds no `bindings` to tweak and `stampDurationSteps` only stamps
//    bindings whose JSON carries a finite `duration`. `ArrangeOpts.wireForm` reproduces both.

public enum ArrangeError: Error, Equatable {
  /// JS: `nb.resetState is not a function` — a cloned / synthesized net reached the simulator.
  case netNotParsed(String)
  /// JS: `(x).toFixed is not a function` — a non-numeric `density`.
  case badDensity
  /// Another JS TypeError at the same point: a `size` naming an `Object.prototype` property
  /// (`blueprint.map` of undefined), a `null` entry in `fadeIn` / `sections` / a curve /
  /// `counterMelody` (property read of null).
  case typeError(String)
}

/// The own property names of `Object.prototype` (V8). A lookup of one of these in a plain JS
/// object literal finds the inherited function (or, for `__proto__`, the prototype), not
/// `undefined`, and arrange.js behaves accordingly (`isObjectProtoKey` call sites).
let objectProtoKeys: Set<String> = [
  "constructor", "__defineGetter__", "__defineSetter__", "hasOwnProperty", "__lookupGetter__",
  "__lookupSetter__", "isPrototypeOf", "propertyIsEnumerable", "toString", "valueOf", "__proto__",
  "toLocaleString",
]

/// `opts` of `arrangeWithOpts`.
public struct ArrangeOpts {
  public var seed = 0.0
  public var velocityDeltas: JSONObject?
  public var maxVariants = 0.0
  /// Role names; JSON values because the JS reads them as it finds them (a `null` throws).
  public var fadeIn: [JSONValue] = []
  public var drumBreak = 0.0
  public var sections: [JSONValue] = []
  public var feelCurve: [JSONValue] = []
  public var macroCurve: [JSONValue] = []
  public var counterMelody: [JSONValue] = []
  public var overlayOnly = false
  /// The project handed in is the unparsed wire form (see the file comment).
  public var wireForm = false

  public init() {}

  /// From a JS opts object (the shape fixtures and share envelopes use).
  public init(json o: JSONValue) {
    if let s = o["seed"]?.double, s != 0, !s.isNaN { seed = s }
    if let d = o["velocityDeltas"], d.isTruthy { velocityDeltas = d.object ?? JSONObject() }
    if let m = o["maxVariants"]?.double, !m.isNaN { maxVariants = m }
    fadeIn = o["fadeIn"]?.array ?? []
    if let d = o["drumBreak"]?.double, !d.isNaN { drumBreak = d }
    sections = o["sections"]?.array ?? []
    feelCurve = o["feelCurve"]?.array ?? []
    macroCurve = o["macroCurve"]?.array ?? []
    counterMelody = o["counterMelody"]?.array ?? []
    overlayOnly = o["overlayOnly"]?.isTruthy ?? false
  }
}

// MARK: - Tables (arrange.js carries its own copy of the structure tables)

enum ArrangeTables {
  private static func bp(_ rows: String...) -> [[String]] {
    rows.map { $0.split(separator: " ").map(String.init) }
  }
  private static func flags(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

  /// genre → family, in declaration order.
  static let families: [(String, String)] = [
    ("edm", "edm"), ("techno", "edm"), ("house", "edm"), ("trance", "edm"), ("dnb", "edm"),
    ("dubstep", "edm"), ("speedcore", "edm"), ("garage", "edm"), ("trap", "edm"),
    ("country", "song"), ("blues", "song"), ("funk", "song"), ("reggae", "song"),
    ("synthwave", "song"), ("metal", "song"),
    ("jazz", "jazz"), ("bossa", "jazz"),
    ("ambient", "chill"), ("lofi", "chill"),
    ("wrapped", "edm"),
  ]

  /// family → size → candidate blueprints, in declaration order.
  static let blueprints: [(String, [(String, [[String]])])] = [
    (
      "edm",
      [
        (
          "minimal",
          bp("intro buildup drop outro", "intro drop breakdown drop")
        ),
        (
          "standard",
          bp(
            "intro buildup drop breakdown buildup drop outro",
            "intro verse buildup drop breakdown drop outro",
            "intro buildup drop verse drop outro")
        ),
        (
          "extended",
          bp(
            "intro buildup drop breakdown verse buildup drop bridge chorus outro",
            "intro verse buildup drop breakdown buildup drop chorus outro",
            "intro buildup drop verse breakdown buildup drop bridge drop outro",
            "intro verse pre-chorus drop breakdown verse buildup drop outro")
        ),
        (
          "ab",
          bp(
            "verse drop verse drop", "buildup drop buildup drop", "verse chorus verse chorus")
        ),
        (
          "drop",
          bp(
            "drop breakdown drop breakdown drop", "buildup drop breakdown drop",
            "drop verse drop verse drop")
        ),
        (
          "build",
          bp("buildup drop buildup drop buildup drop", "verse buildup drop buildup drop")
        ),
        (
          "jam",
          bp(
            "verse solo verse solo verse", "verse bridge verse solo verse",
            "drop solo drop bridge drop")
        ),
      ]
    ),
    (
      "song",
      [
        ("minimal", bp("intro verse chorus outro", "intro verse verse chorus")),
        (
          "standard",
          bp(
            "intro verse chorus verse chorus outro", "intro verse chorus bridge chorus outro",
            "intro verse pre-chorus chorus verse chorus outro")
        ),
        (
          "extended",
          bp(
            "intro verse chorus verse chorus bridge chorus outro",
            "intro verse pre-chorus chorus verse pre-chorus chorus bridge chorus outro",
            "intro verse chorus verse chorus breakdown verse chorus outro",
            "intro verse verse chorus bridge verse chorus chorus outro")
        ),
        (
          "ab",
          bp(
            "verse chorus verse chorus", "verse chorus bridge chorus",
            "verse pre-chorus chorus verse chorus")
        ),
        (
          "drop",
          bp("chorus verse chorus verse chorus", "chorus bridge chorus bridge chorus")
        ),
        (
          "build",
          bp(
            "verse pre-chorus chorus verse pre-chorus chorus",
            "verse buildup chorus verse buildup chorus")
        ),
        (
          "jam",
          bp(
            "verse solo verse solo verse", "verse bridge solo verse solo",
            "verse verse bridge solo verse")
        ),
      ]
    ),
    (
      "jazz",
      [
        ("minimal", bp("intro verse solo outro", "intro verse verse outro")),
        (
          "standard",
          bp(
            "intro verse solo verse outro", "intro verse verse bridge verse outro",
            "intro verse chorus solo chorus outro")
        ),
        (
          "extended",
          bp(
            "intro verse chorus solo verse chorus bridge chorus outro",
            "intro verse solo verse bridge solo verse outro",
            "intro verse verse solo bridge verse chorus outro")
        ),
        ("ab", bp("verse solo verse solo", "verse bridge verse solo")),
        ("drop", bp("verse solo verse solo verse", "solo verse bridge solo verse")),
        ("build", bp("verse verse solo verse solo solo")),
        (
          "jam",
          bp(
            "verse solo solo bridge solo verse", "solo bridge solo verse solo",
            "verse solo verse bridge solo solo")
        ),
      ]
    ),
    (
      "chill",
      [
        ("minimal", bp("intro verse verse outro", "intro verse bridge outro")),
        (
          "standard",
          bp(
            "intro verse bridge verse outro", "intro verse breakdown verse outro",
            "intro verse verse bridge verse outro")
        ),
        (
          "extended",
          bp(
            "intro verse chorus breakdown verse chorus outro",
            "intro verse bridge verse breakdown verse bridge outro",
            "intro verse verse bridge breakdown verse chorus outro")
        ),
        ("ab", bp("verse bridge verse bridge", "verse breakdown verse bridge")),
        (
          "drop",
          bp("verse breakdown verse breakdown verse", "verse bridge breakdown verse bridge")
        ),
        (
          "build",
          bp("verse verse bridge verse chorus", "breakdown verse bridge verse chorus")
        ),
        (
          "jam",
          bp(
            "verse bridge verse breakdown verse", "verse verse bridge breakdown verse bridge")
        ),
      ]
    ),
  ]

  static let archetypes: [(String, [String])] = [
    ("intro", flags("kick hihat bass")),
    ("verse", flags("kick snare hihat bass")),
    ("pre-chorus", flags("kick snare hihat bass arp")),
    ("chorus", flags("kick snare hihat bass melody harmony arp clap")),
    ("drop", flags("kick snare hihat bass melody harmony arp clap")),
    ("buildup", flags("kick snare hihat bass arp")),
    ("breakdown", flags("hihat bass melody")),
    ("bridge", flags("bass melody harmony")),
    ("solo", flags("kick hihat bass melody")),
    ("outro", flags("kick hihat melody")),
  ]

  static let archetypesByFamily: [(String, [(String, [String])])] = [
    ("edm", [("intro", flags("kick hihat")), ("breakdown", flags("hihat bass"))]),
    (
      "song",
      [("pre-chorus", flags("kick snare bass arp")), ("outro", flags("kick hihat bass melody"))]
    ),
    (
      "jazz",
      [
        ("intro", flags("hihat bass")), ("verse", flags("hihat bass melody")),
        ("chorus", flags("hihat bass melody harmony")), ("solo", flags("hihat bass melody")),
      ]
    ),
    (
      "chill",
      [
        ("intro", flags("bass")), ("verse", flags("hihat bass melody")),
        ("chorus", flags("hihat bass melody harmony arp")), ("bridge", flags("bass melody")),
        ("breakdown", flags("melody")), ("outro", flags("melody")),
      ]
    ),
  ]

  static func family(_ genre: String) -> String? { families.first { $0.0 == genre }?.1 }

  /// `FAMILIES[genre] || 'song'` as the two lookups that use it see it: the blueprint family
  /// and the family whose archetype overrides apply. A genre naming an `Object.prototype`
  /// property finds a function: no blueprints under its name (song's are used) and no
  /// archetype overrides.
  static func families(for genre: String) -> (blueprints: String, archetypes: String?) {
    if let f = family(genre) { return (f, f) }
    return objectProtoKeys.contains(genre) ? ("song", nil) : ("song", "song")
  }

  /// `archetypeFor(family, name)`
  static func archetype(_ family: String?, _ name: String) -> [String] {
    if let fam = archetypesByFamily.first(where: { $0.0 == family })?.1,
      let a = fam.first(where: { $0.0 == name })
    {
      return a.1
    }
    return archetypes.first { $0.0 == name }?.1 ?? []
  }

  static func candidates(family: String, size: String) -> [[String]] {
    func find(_ fam: String, _ size: String) -> [[String]]? {
      blueprints.first { $0.0 == fam }?.1.first { $0.0 == size }?.1
    }
    return find(family, size) ?? find("song", "standard")!
  }

  /// The tables as JSON in declaration order, for the fixture comparison.
  static var json: JSONValue {
    func flagObj(_ names: [String]) -> JSONValue {
      var o = JSONObject()
      for n in names { o[n] = .bool(true) }
      return .object(o)
    }
    var fam = JSONObject()
    for (g, f) in families { fam[g] = .string(f) }
    var bps = JSONObject()
    for (f, sizes) in blueprints {
      var so = JSONObject()
      for (size, rows) in sizes { so[size] = .array(rows.map { .array($0.map { .string($0) }) }) }
      bps[f] = .object(so)
    }
    var arch = JSONObject()
    for (n, a) in archetypes { arch[n] = flagObj(a) }
    var byFam = JSONObject()
    for (f, rows) in archetypesByFamily {
      var o = JSONObject()
      for (n, a) in rows { o[n] = flagObj(a) }
      byFam[f] = .object(o)
    }
    return .object(
      JSONObject([
        ("families", .object(fam)), ("blueprints", .object(bps)), ("archetypes", .object(arch)),
        ("archetypesByFamily", .object(byFam)),
      ]))
  }
}

// MARK: - Context

/// What the JS knows implicitly about its objects while an arrange runs.
struct ArrangeContext {
  /// Nets that are plain objects in JS (no NetBundle methods).
  var plain = Set<String>()
}

// MARK: - Predicates

private func isStingerNet(_ id: String, _ nb: NetBundle?) -> Bool {
  if nb?.track.group == "stinger" { return true }
  return isStingerID(id)
}

private func isDrumRoleName(_ id: String) -> Bool {
  for p in ["kick", "snare", "hat", "hihat", "clap", "cymbal", "tom", "drum", "perc"]
  where id.hasPrefix(p) { return true }
  return false
}

private func sortedMusicNetIDs(_ proj: Project) -> [String] {
  proj.nets.keys.filter { proj.nets[$0]?.role != "control" }.sorted(by: jsStringLess)
}

// MARK: - Templates

/// arrange.js `sectionWithPhrases` (unlike structure.js, `snare` keeps a phrase list).
private func arrangeSection(_ name: String, _ steps: Int, _ active: OrderedFlags) -> TemplateSection
{
  var phrases = OrderedMap<[String]>()
  let pattern = defaultPhrases(name)
  for role in active.keys {
    phrases[role] = role == "snare" ? [String](repeating: "A", count: pattern.count) : pattern
  }
  return TemplateSection(name: name, steps: steps, active: active, phrases: phrases)
}

private func generateArrangeStructure(
  genre: String, size: String, roles: [String], rng: inout Mulberry32
) throws -> SongTemplate {
  let (blueprintFamily, family) = ArrangeTables.families(for: genre)
  // `blueprintsBySize[size]` is an inherited function for these: `candidates[k]` is undefined
  // and `blueprint.map` throws.
  if objectProtoKeys.contains(size) { throw ArrangeError.typeError("blueprint.map of undefined") }
  let candidates = ArrangeTables.candidates(family: blueprintFamily, size: size)
  let blueprint = candidates[rng.nextInt(candidates.count)]
  let roleSet = Set(roles)
  let sections = blueprint.map { name -> TemplateSection in
    var active = OrderedFlags()
    let archetype = ArrangeTables.archetype(family, name)
    for k in archetype where roleSet.contains(k) { active.set(k) }
    for r in roles {
      if active.contains(r) { continue }
      if archetype.contains(r) { continue }
      if isStingerID(r) { continue }
      if name != "intro" && name != "outro" { active.set(r) }
    }
    return arrangeSection(name, sectionSteps(name, size), active)
  }
  return SongTemplate(name: size, sections: sections)
}

private func authorSectionsToTemplate(_ authored: [JSONValue], roles: [String]) throws
  -> SongTemplate
{
  let sections = try authored.map { a -> TemplateSection in
    if a == .null { throw ArrangeError.typeError("a.active of null") }
    var activeSet = Set<String>()
    switch a["active"] {
    case .array(let arr)?: for v in arr { if let s = v.string { activeSet.insert(s) } }
    default: break
    }
    var active = OrderedFlags()
    for r in roles where activeSet.contains(r) { active.set(r) }
    let steps = a["steps"]?.double.flatMap { $0 > 0 ? Int($0) : nil } ?? 128
    return arrangeSection(a["name"]?.string ?? "", steps, active)
  }
  return SongTemplate(name: "authored", sections: sections)
}

private func projectStructureToTemplate(_ proj: Project) -> SongTemplate? {
  if proj.structure.isEmpty { return nil }
  let sections = proj.structure.map {
    TemplateSection(name: $0.name, steps: $0.steps, active: OrderedFlags(), phrases: $0.phrases)
  }
  return SongTemplate(name: "overlay", sections: sections)
}

private func capVariantLetters(_ tmpl: inout SongTemplate, max: Double) {
  if max <= 0 { return }
  // `String.fromCharCode(65 + i)` for i < max; phrase letters are A–C, so the first 26 decide.
  var allowed = Set<String>()
  var i = 0
  while Double(i) < max && i < 26 {
    allowed.insert(String(UnicodeScalar(UInt8(65 + i))))
    i += 1
  }
  for si in 0..<tmpl.sections.count {
    for role in tmpl.sections[si].phrases.keys {
      tmpl.sections[si].phrases[role] = tmpl.sections[si].phrases[role]!.map {
        allowed.contains($0) ? $0 : "A"
      }
    }
  }
}

// MARK: - Variant cloning

/// `tweakVelocity` on a cloned bundle; the clone is re-parsed later (`getInt`: Math.round), so
/// a fractional delta lands rounded.
private func tweakVelocity(_ nb: inout NetBundle, _ delta: Double) {
  for id in nb.bindings.keys {
    var b = nb.bindings[id]!
    var v = Double(b.velocity) + delta
    if v < 1 { v = 1 }
    if v > 127 { v = 127 }
    b.velocity = Int(jsRound(v))
    nb.bindings[id] = b
  }
}

private func expandArrangeVariants(
  _ proj: inout Project, tmpl: inout SongTemplate, roles: [String], deltas: [String: Double],
  tweak: Bool, ctx: inout ArrangeContext
) {
  tmpl.slotMap = OrderedMap()
  var rolesInPhrases = Set<String>()
  for sec in tmpl.sections { for r in sec.phrases.keys { rolesInPhrases.insert(r) } }

  for role in roles {
    if !rolesInPhrases.contains(role) { continue }
    guard let baseBundle = proj.nets[role] else { continue }
    if isStingerNet(role, baseBundle) { continue }

    var slotMap = [[Int]](repeating: [], count: tmpl.sections.count)
    var slotIdx = 0
    var letterSlots: [String: Int] = [:]
    for (si, sec) in tmpl.sections.enumerated() {
      let phrases = sec.phrases[role] ?? ["A"]
      var sectionSlots = [Int](repeating: -1, count: phrases.count)
      if sec.active.contains(role) {
        for (pi, letter) in phrases.enumerated() {
          if let s = letterSlots[letter] {
            sectionSlots[pi] = s
          } else {
            letterSlots[letter] = slotIdx
            sectionSlots[pi] = slotIdx
            slotIdx += 1
          }
        }
      }
      slotMap[si] = sectionSlots
    }
    tmpl.slotMap[role] = slotMap

    if slotIdx <= 1 {
      proj.nets[role]!.riffGroup = role
      proj.nets[role]!.riffVariant = "A"
      continue
    }

    for letter in letterSlots.keys.sorted(by: jsStringLess) {
      let idx = letterSlots[letter]!
      let slotNetId = "\(role)-\(idx)"
      var clone = baseBundle
      clone.riffGroup = role
      clone.riffVariant = letter
      if tweak, let d = deltas[letter], d != 0, !d.isNaN { tweakVelocity(&clone, d) }
      proj.nets[slotNetId] = clone
      ctx.plain.insert(slotNetId)
    }
    proj.nets[role] = nil
    ctx.plain.remove(role)
  }
}

// MARK: - Section control nets (the ring-based arrange.js flavour)

private func arrangeRoleControlNet(
  _ role: String, slotMap: [[Int]], tmpl: SongTemplate, totalSteps: Int, stagger: Int
) -> NetBundle {
  var ctrlAt: [Int: ControlBinding] = [:]
  var prevSlot = (slotMap.count > 0 && slotMap[0].count > 0) ? slotMap[0][0] : -1
  var pos = 0
  for (si, sec) in tmpl.sections.enumerated() {
    let phrases = sec.phrases[role] ?? ["A"]
    let phraseLen = phrases.isEmpty ? 0 : sec.steps / phrases.count
    for pi in 0..<phrases.count {
      let phraseStart = pos + pi * phraseLen
      if phraseStart == 0 { continue }
      var curSlot = -1
      if si < slotMap.count && pi < slotMap[si].count { curSlot = slotMap[si][pi] }
      if curSlot != prevSlot {
        var bindPos = phraseStart
        if curSlot >= 0 && stagger > 0 {
          var maxOff = totalSteps - 1 - phraseStart
          if maxOff > phraseLen - 1 { maxOff = phraseLen - 1 }
          var off = stagger
          if off > maxOff { off = maxOff }
          if off < 0 { off = 0 }
          bindPos = phraseStart + off
        }
        if curSlot >= 0 {
          ctrlAt[bindPos] = controlBinding("activate-slot", target: "\(role)-\(curSlot)")
        } else {
          ctrlAt[bindPos] = controlBinding("mute-track", target: "\(role)-\(prevSlot)")
        }
        prevSlot = curSlot
      }
    }
    pos += sec.steps
  }
  return buildControlBundle(steps: totalSteps, ctrlAt: ctrlAt, sink: true)
}

private func arrangeLinearControlNet(
  _ target: String, tmpl: SongTemplate, totalSteps: Int, stagger: Int
) -> NetBundle {
  var ctrlAt: [Int: ControlBinding] = [:]
  var wasActive = tmpl.sections[0].active.contains(target)
  var pos = 0
  for si in 1..<max(1, tmpl.sections.count) {
    pos += tmpl.sections[si - 1].steps
    let isActive = tmpl.sections[si].active.contains(target)
    if isActive != wasActive {
      var bindPos = pos
      if isActive && stagger > 0 {
        let maxOff = tmpl.sections[si].steps - 1
        var off = stagger
        if off > maxOff { off = maxOff }
        if off < 0 { off = 0 }
        bindPos = pos + off
      }
      ctrlAt[bindPos] = controlBinding(isActive ? "unmute-track" : "mute-track", target: target)
      wasActive = isActive
    }
  }
  return buildControlBundle(steps: totalSteps, ctrlAt: ctrlAt, sink: true)
}

private func arrangeSongStructure(
  _ proj: inout Project, tmpl: SongTemplate, musicNets: [String]
) -> [String] {
  var totalSteps = 0
  for sec in tmpl.sections { totalSteps += sec.steps }
  var initialMutes: [String] = []
  var slotRoles = Set<String>()
  for id in musicNets {
    if let g = proj.nets[id]?.riffGroup, !g.isEmpty { slotRoles.insert(g) }
  }
  var staggerKeys: [String] = []
  var seen = Set<String>()
  for id in musicNets {
    guard let nb = proj.nets[id] else { continue }
    var key = id
    if !nb.riffGroup.isEmpty {
      key = nb.riffGroup
    } else if slotRoles.contains(id) {
      continue
    }
    if seen.contains(key) { continue }
    seen.insert(key)
    staggerKeys.append(key)
  }
  staggerKeys.sort(by: jsStringLess)
  var staggerOf: [String: Int] = [:]
  for (i, k) in staggerKeys.enumerated() { staggerOf[k] = i % boundaryStagger }

  var processed = Set<String>()
  for id in musicNets {
    guard let nb = proj.nets[id] else { continue }
    if !nb.riffGroup.isEmpty {
      let role = nb.riffGroup
      if processed.contains(role) { continue }
      processed.insert(role)
      let slotMap = tmpl.slotMap[role] ?? []
      proj.nets["struct-\(role)"] = arrangeRoleControlNet(
        role, slotMap: slotMap, tmpl: tmpl, totalSteps: totalSteps, stagger: staggerOf[role] ?? 0)
      var firstSlot = -1
      if slotMap.count > 0 && slotMap[0].count > 0 { firstSlot = slotMap[0][0] }
      for nId in musicNets {
        if let nb2 = proj.nets[nId], nb2.riffGroup == role {
          let slotIdx = extractSlotIndex(nId, role)
          if slotIdx != firstSlot || firstSlot < 0 { initialMutes.append(nId) }
        }
      }
    } else if !slotRoles.contains(id) {
      if isStingerNet(id, nb) {
        initialMutes.append(id)
        continue
      }
      proj.nets["struct-\(id)"] = arrangeLinearControlNet(
        id, tmpl: tmpl, totalSteps: totalSteps, stagger: staggerOf[id] ?? 0)
      if !tmpl.sections[0].active.contains(id) { initialMutes.append(id) }
    }
  }
  proj.nets["struct-stop"] = buildControlBundle(
    steps: totalSteps,
    ctrlAt: [totalSteps - 1: controlBinding("stop-transport", target: "")], sink: true)

  proj.structure = tmpl.sections.map { s in
    var out = Section(name: s.name, steps: s.steps)
    out.phrases = s.phrases
    return out
  }
  return initialMutes
}

// MARK: - Overlays

/// arrange.js `drumBreak` with the double arithmetic the overlay needs: `drumBreak: 0.3` bars
/// is 4.8 steps in JS, and a fractional position simply never matches a transition index.
private func drumBreakOverlay(
  _ proj: inout Project, targets: [String], cycleLen steps: Int, breakLen breakIn: Double
) {
  var cycle = Double(steps)
  if cycle < 16 { cycle = 64 }
  var breakLen = breakIn
  if breakLen < 4 { breakLen = 8 }
  if breakLen >= cycle { breakLen = (cycle / 4).rounded(.down) }
  let mutePos = (cycle / 2).rounded(.down)
  let sorted = targets.sorted(by: jsStringLess)
  let unmuteBase = (mutePos + breakLen).truncatingRemainder(dividingBy: cycle)
  let headroom = ((mutePos - unmuteBase - 1).truncatingRemainder(dividingBy: cycle) + cycle)
    .truncatingRemainder(dividingBy: cycle)
  var maxStagger = Double(boundaryStagger)
  if maxStagger > headroom { maxStagger = headroom }
  if maxStagger < 1 { maxStagger = 1 }
  for (i, target) in sorted.enumerated() {
    if proj.nets[target] == nil { continue }
    let unmutePos = (mutePos + breakLen + Double(i).truncatingRemainder(dividingBy: maxStagger))
      .truncatingRemainder(dividingBy: cycle)
    var ctrlAt: [Int: ControlBinding] = [:]
    ctrlAt[Int(mutePos)] = controlBinding("mute-track", target: target)
    if unmutePos == unmutePos.rounded(.down) {
      ctrlAt[Int(unmutePos)] = controlBinding("unmute-track", target: target)
    }
    proj.nets["break-\(target)"] = buildControlBundle(steps: Int(cycle), ctrlAt: ctrlAt)
  }
}

/// `injectFeelCurve` for the envelope's `[{section, x, y}]` entries (x / y pass through as-is).
private func injectFeelCurveEntries(_ proj: inout Project, tmpl: SongTemplate, curve: [JSONValue]) {
  injectCurve(&proj, tmpl: tmpl, curve: curve, net: "feel-curve", prefixes: ("fp", "ft")) { e in
    var c = controlBinding("set-feel", target: "")
    var mp = JSONObject()
    if let x = e["x"] { mp["x"] = x }
    if let y = e["y"] { mp["y"] = y }
    c.macroParams = .object(mp)
    return c
  }
}

/// A `null` curve / counter-melody entry: `entry.section` throws in JS once it is reached.
private func rejectNullEntries(_ entries: [JSONValue], _ what: String) throws {
  if entries.contains(.null) { throw ArrangeError.typeError("\(what) entry is null") }
}

/// JS `String(v)` for the values a counter-melody entry can carry (used only for seeding).
private func jsString(_ v: JSONValue?) -> String {
  guard let v else { return "undefined" }
  switch v {
  case .null: return "null"
  case .bool(let b): return b ? "true" : "false"
  case .number(let d): return jsNumberString(d)
  case .string(let s): return s
  case .array(let a):
    return a.map { x -> String in if case .null = x { return "" } else { return jsString(x) } }
      .joined(separator: ",")
  case .object: return "[object Object]"
  }
}

/// `String(entry.field || '')`
private func orEmpty(_ v: JSONValue?) -> String {
  guard let v, v.isTruthy else { return "" }
  return jsString(v)
}

private func injectCounterMelody(
  _ proj: inout Project, tmpl: SongTemplate, entries: [JSONValue], baseSeed: Double,
  ctx: inout ArrangeContext
) throws {
  var starts: [(tick: Int, name: String)] = []
  var totalSteps = 0
  for sec in tmpl.sections {
    starts.append((totalSteps, sec.name))
    totalSteps += sec.steps
  }
  if totalSteps == 0 { return }
  let tempo = proj.tempo > 0 ? proj.tempo : 120
  let msPerTick = 60000 / (tempo * Double(counterPPQ))

  for (idx, entry) in entries.enumerated() {
    if entry == .null { throw ArrangeError.typeError("entry.section of null") }
    guard let section = entry["section"]?.string, starts.contains(where: { $0.name == section })
    else { continue }

    var densityValue = 0.0
    if let d = entry["density"], d.isTruthy {
      guard let n = d.double else { throw ArrangeError.badDensity }
      densityValue = n
    }
    let seed = counterSeed([
      "counter-melody:\(jsNumberString(baseSeed)):\(idx)",
      orEmpty(entry["section"]), orEmpty(entry["mode"]), jsToFixed6(densityValue),
      orEmpty(entry["register"]), orEmpty(entry["of"]), orEmpty(entry["instrument"]),
    ])

    let of = entry["of"]
    var scope: String?
    if let of, of.isTruthy { scope = of.string ?? "\u{0}not-a-string" }
    let notes = try generateCounterMelody(
      proj, mode: entry["mode"]?.string.flatMap { $0.isEmpty ? nil : $0 },
      density: densityValue,
      register: entry["register"]?.string.flatMap { $0.isEmpty ? nil : $0 }, seed: seed,
      totalTicks: totalSteps, sourceNetID: scope, plain: ctx.plain)
    guard let notes, !notes.isEmpty else { continue }

    // `entry.instrument || counterMelodyDefaultInstrument(entry.register)`; a truthy
    // non-string instrument parses back to '' (getString).
    var instrument: String
    if let ins = entry["instrument"], ins.isTruthy {
      instrument = ins.string ?? ""
    } else {
      instrument = entry["register"]?.string == "below" ? "sub-bass" : "electric-piano"
    }

    // nextFreeCounterChannel
    var maxCh = 0
    for id in proj.nets.keys.sorted(by: jsStringLess) {
      guard let nb = proj.nets[id], nb.role != "control" else { continue }
      if nb.track.channel > maxCh { maxCh = nb.track.channel }
    }
    var channel = maxCh + 1
    if channel == 16 { channel = 17 }

    guard
      let nb = buildCounterMelodyNet(
        notes: notes, totalTicks: totalSteps, channel: channel, instrument: instrument,
        msPerTick: msPerTick)
    else { continue }

    let netID = "counter-melody-\(idx)"
    proj.nets[netID] = nb
    ctx.plain.insert(netID)
    proj.initialMutes.append(netID)

    var ctrlAt: [Int: ControlBinding] = [:]
    for s in starts {
      ctrlAt[s.tick] = controlBinding(
        s.name == section ? "unmute-track" : "mute-track", target: netID)
    }
    proj.nets["gate-counter-melody-\(idx)"] = buildControlBundle(
      steps: totalSteps, ctrlAt: ctrlAt, placePrefix: "gp\(idx)_", transPrefix: "gt\(idx)_")
  }
}

private func applyArrangeOverlays(
  _ proj: inout Project, tmpl: SongTemplate, allNets: [String], opts: ArrangeOpts,
  ctx: inout ArrangeContext
) throws {
  if !opts.fadeIn.isEmpty {
    var introSteps = 128
    if !tmpl.sections.isEmpty { introSteps = tmpl.sections[0].steps }
    var variantTargets: [String] = []
    for r in opts.fadeIn {
      // `id === role || (id.length > role.length && …)`: a null role throws on `.length`;
      // other non-strings never match.
      if r == .null && !allNets.isEmpty { throw ArrangeError.typeError("role.length of null") }
      guard let role = r.string else { continue }
      for id in allNets where id == role || id.hasPrefix(role + "-") {
        variantTargets.append(id)
      }
    }
    if !variantTargets.isEmpty {
      let added = fadeIn(&proj, targets: variantTargets, steps: introSteps)
      proj.initialMutes += added
    }
  }

  if opts.drumBreak > 0 {
    var drumTargets: [String] = []
    for id in allNets {
      guard let nb = proj.nets[id] else { continue }
      if isDrumRoleName(id) || isStingerNet(id, nb) { continue }
      drumTargets.append(id)
    }
    var totalSteps = 0
    for sec in tmpl.sections { totalSteps += sec.steps }
    if totalSteps > 0 {
      drumBreakOverlay(
        &proj, targets: drumTargets, cycleLen: totalSteps, breakLen: opts.drumBreak * 16)
    }
  }

  if !opts.feelCurve.isEmpty {
    if tmpl.sections.reduce(0, { $0 + $1.steps }) != 0 {
      try rejectNullEntries(opts.feelCurve, "feelCurve")
    }
    injectFeelCurveEntries(&proj, tmpl: tmpl, curve: opts.feelCurve)
  }
  if !opts.macroCurve.isEmpty {
    if tmpl.sections.reduce(0, { $0 + $1.steps }) != 0 {
      try rejectNullEntries(opts.macroCurve, "macroCurve")
    }
    injectMacroCurve(&proj, tmpl: tmpl, curve: opts.macroCurve)
  }
  if !opts.counterMelody.isEmpty {
    try injectCounterMelody(
      &proj, tmpl: tmpl, entries: opts.counterMelody, baseSeed: opts.seed, ctx: &ctx)
  }
}

// MARK: - Wire form

extension Project {
  /// A project built from an unparsed wire document (a share's raw `nets`, as the worker's
  /// `parseProject` sees it), remembering for each MIDI binding the raw ms the JS stamp would
  /// use: it only touches `transitions[].midi` (or sibling `bindings`) whose JSON carries a
  /// finite positive `duration` and no positive `durationSteps`, and it stamps from the raw
  /// (possibly fractional) ms, before the parse rounds it.
  init(wireJSON doc: JSONValue) {
    self.init(json: doc)
    for (id, nd) in doc["nets"]?.object?.entries ?? [] {
      guard nets[id] != nil else { continue }
      func stampable(_ m: JSONValue) -> Double? {
        if jsGreaterThanZero(m["durationSteps"]) { return nil }
        guard let d = m["duration"]?.double, d.isFinite, d > 0 else { return nil }
        return d
      }
      var ms: [String: Double] = [:]
      var fromMidi = Set<String>()
      for (tid, t) in nd["transitions"]?.object?.entries ?? [] {
        guard let m = t["midi"], m.object != nil || m.array != nil else { continue }
        fromMidi.insert(tid)
        if let d = stampable(m) { ms[tid] = d }
      }
      for (bid, m) in nd["bindings"]?.object?.entries ?? [] where !fromMidi.contains(bid) {
        if let d = stampable(m) { ms[bid] = d }
      }
      nets[id]!.wireDurationMs = ms
    }
  }
}

/// JS `v > 0` for a raw JSON value (ToNumber on strings and booleans).
private func jsGreaterThanZero(_ v: JSONValue?) -> Bool {
  switch v {
  case .number(let d)?: return d > 0
  case .bool(let b)?: return b
  case .string(let s)?:
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return (t.isEmpty ? 0 : Double(t) ?? .nan) > 0
  default: return false
  }
}

// MARK: - Entry point

/// The `size` a share's `structure` value arranges with. JS looks blueprints up by
/// `String(value)` and section lengths by `=== 'minimal'` / `'extended'`; a non-string value
/// is treated here as an unknown size (song standard blueprints, standard lengths), which is
/// what JS does for every non-string except arrays whose string form names a size.
func arrangeSize(_ structure: JSONValue) -> String { structure.string ?? "\u{0}" }

/// `arrangeWithOpts(proj, genre, size, opts)`. Mutates `proj`; on a throw the project is left
/// as far along as the JS got (and, as in the JS `finally`, durations are stamped).
public func arrangeWithOpts(
  _ proj: inout Project, genre: String, size: String, opts: ArrangeOpts
) throws {
  defer { proj.stampDurationSteps() }
  var ctx = ArrangeContext()
  if opts.wireForm { ctx.plain = Set(proj.nets.keys) }

  if opts.overlayOnly {
    guard let tmpl = projectStructureToTemplate(proj) else { return }
    try applyArrangeOverlays(
      &proj, tmpl: tmpl, allNets: sortedMusicNetIDs(proj), opts: opts, ctx: &ctx)
    return
  }

  var rng = Mulberry32(seed: opts.seed)
  let musicRoles = sortedMusicNetIDs(proj)

  var tmpl: SongTemplate
  if !opts.sections.isEmpty {
    tmpl = try authorSectionsToTemplate(opts.sections, roles: musicRoles)
  } else {
    tmpl = try generateArrangeStructure(
      genre: genre.isEmpty ? "wrapped" : genre, size: size.isEmpty ? "standard" : size,
      roles: musicRoles, rng: &rng)
  }
  if opts.maxVariants > 0 { capVariantLetters(&tmpl, max: opts.maxVariants) }

  var deltas: [String: Double] = ["A": 0, "B": 15, "C": -15, "D": -10]
  if let vd = opts.velocityDeltas {
    deltas = [:]
    for (k, v) in vd.entries { if let d = v.double { deltas[k] = d } }
  }
  expandArrangeVariants(
    &proj, tmpl: &tmpl, roles: musicRoles, deltas: deltas, tweak: !opts.wireForm, ctx: &ctx)

  let allNets = sortedMusicNetIDs(proj)
  let initialMutes = arrangeSongStructure(&proj, tmpl: tmpl, musicNets: allNets)
  var merged = OrderedFlags(proj.initialMutes)
  for id in initialMutes { merged.set(id) }
  proj.initialMutes = merged.keys

  try applyArrangeOverlays(&proj, tmpl: tmpl, allNets: allNets, opts: opts, ctx: &ctx)
}
