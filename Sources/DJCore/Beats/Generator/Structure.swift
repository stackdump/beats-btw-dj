import Foundation

// Port of generator/structure.js (song templates + control nets) and the
// feel/macro/fade helpers compose() uses from arrange.js.

public struct TemplateSection {
  public var name: String
  public var steps: Int
  public var active: OrderedFlags
  public var phrases: OrderedMap<[String]>
}

public struct SongTemplate {
  public var name: String
  public var sections: [TemplateSection]
  public var slotMap: OrderedMap<[[Int]]> = OrderedMap()
}

/// `defaultPhrases(name)` (theory.js / structure.js — identical).
public func defaultPhrases(_ name: String) -> [String] {
  switch name {
  case "intro", "outro": ["A", "A"]
  case "verse": ["A", "A", "B", "A"]
  case "chorus", "drop": ["A", "B", "A", "B"]
  case "bridge", "breakdown": ["C", "C"]
  case "buildup", "pre-chorus": ["A", "B"]
  case "solo": ["A", "B", "C", "A"]
  default: ["A", "A"]
  }
}

/// `genrePhrases(theory, section)`
func genrePhrases(_ theory: GenreTheory?, _ section: String) -> [String] {
  if let p = theory?.phrasePatterns?[section] { return p }
  return defaultPhrases(section)
}

func sectionSteps(_ name: String, _ size: String) -> Int {
  switch size {
  case "minimal":
    return (name == "intro" || name == "outro") ? 32 : 128
  case "extended":
    switch name {
    case "intro", "outro", "breakdown", "bridge", "buildup", "pre-chorus", "solo": return 128
    default: return 192
    }
  default:
    switch name {
    case "intro", "outro", "breakdown", "bridge", "pre-chorus", "solo": return 64
    default: return 192
    }
  }
}

func sectionWithPhrases(_ name: String, _ steps: Int, _ active: OrderedFlags) -> TemplateSection {
  var phrases = OrderedMap<[String]>()
  let pattern = defaultPhrases(name)
  for role in active.keys where role != "snare" { phrases[role] = pattern }
  return TemplateSection(name: name, steps: steps, active: active, phrases: phrases)
}

/// `generateStructure(genreName, size, rng)`
public func generateStructure(genre: String, size: String, rng: inout Mulberry32) -> SongTemplate {
  let tables = BeatsTables.shared
  let family = tables.family(of: genre)
  let blueprints =
    tables.blueprints(family: family, size: size)
    ?? tables.blueprints(family: 1, size: "standard") ?? [["verse", "chorus"]]
  let blueprint = blueprints[Int((rng.float64() * Double(blueprints.count)).rounded(.down))]
  let sections = blueprint.map { name in
    sectionWithPhrases(
      name, sectionSteps(name, size), tables.archetype(family: family, name: name) ?? OrderedFlags()
    )
  }
  return SongTemplate(name: size, sections: sections)
}

func extractSlotIndex(_ netId: String, _ riffGroup: String) -> Int {
  let suffix = Array(netId.utf16.dropFirst(riffGroup.utf16.count + 1))
  var idx = 0
  for c in suffix where c >= 48 && c <= 57 { idx = idx * 10 + Int(c - 48) }
  return idx
}

// MARK: - Accumulator control nets

struct StructureEvent {
  var tick: Int
  var binding: ControlBinding
}

func controlBinding(_ action: String, target: String, note: Int = 0) -> ControlBinding {
  ControlBinding(action: action, targetNet: target, targetNote: note)
}

private func controlTrack() -> Track { Track() }

func buildAccumulatorNet(_ events: [StructureEvent]) -> NetBundle {
  var bundle = NetBundle()
  bundle.track = controlTrack()
  bundle.role = "control"
  if events.isEmpty {
    bundle.places["p0"] = Place(initial: [1], x: 0, y: 0, label: nil)
    bundle.transitions["t0"] = Transition(x: 0, y: 0, label: nil)
    bundle.arcs.append(Arc(source: "p0", target: "t0", weight: [1], inhibit: false))
    bundle.arcs.append(Arc(source: "t0", target: "p0", weight: [1], inhibit: false))
    return bundle
  }
  // Array.prototype.sort is stable; Swift's sort is not guaranteed to be.
  let sorted = events.enumerated().sorted {
    $0.element.tick != $1.element.tick ? $0.element.tick < $1.element.tick : $0.offset < $1.offset
  }.map(\.element)

  func arc(_ s: String, _ t: String, inhibit: Bool = false) -> Arc {
    Arc(source: s, target: t, weight: [1], inhibit: inhibit)
  }
  let n = sorted.count
  var prevTick = 0
  for i in 0..<n {
    let ev = sorted[i]
    let gap = ev.tick - prevTick
    let pDelay = "p_delay_\(i)"
    let pGate = "p_gate_\(i)"
    let tDrain = "t_drain_\(i)"
    let tCtrl = "t_ctrl_\(i)"
    bundle.places[pDelay] = Place(initial: [Double(gap)], x: 0, y: 0, label: nil)
    bundle.places[pGate] = Place(initial: [i == 0 ? 1 : 0], x: 0, y: 0, label: nil)
    bundle.transitions[tDrain] = Transition(x: 0, y: 0, label: nil)
    bundle.arcs.append(arc(pDelay, tDrain))
    bundle.arcs.append(arc(pGate, tDrain))
    bundle.arcs.append(arc(tDrain, pGate))
    bundle.transitions[tCtrl] = Transition(x: 0, y: 0, label: nil)
    bundle.arcs.append(arc(pDelay, tCtrl, inhibit: true))
    bundle.arcs.append(arc(pGate, tCtrl))
    if i < n - 1 { bundle.arcs.append(arc(tCtrl, "p_gate_\(i + 1)")) }
    bundle.controlBindings[tCtrl] = ev.binding
    prevTick = ev.tick
  }
  return bundle
}

func roleControlNet(_ role: String, slotMap: [[Int]], template: SongTemplate) -> NetBundle {
  var events: [StructureEvent] = []
  var prevSlot = -1
  if let first = slotMap.first, !first.isEmpty { prevSlot = first[0] }
  var pos = 0
  for (si, sec) in template.sections.enumerated() {
    var phrases = sec.phrases[role] ?? []
    if phrases.isEmpty { phrases = ["A"] }
    let phraseLen = sec.steps / phrases.count
    for pi in 0..<phrases.count {
      let phraseStart = pos + pi * phraseLen
      if phraseStart == 0 { continue }
      var curSlot = -1
      if si < slotMap.count && pi < slotMap[si].count { curSlot = slotMap[si][pi] }
      if curSlot != prevSlot {
        if curSlot >= 0 {
          events.append(
            StructureEvent(
              tick: phraseStart,
              binding: controlBinding("activate-slot", target: "\(role)-\(curSlot)")))
        } else {
          events.append(
            StructureEvent(
              tick: phraseStart,
              binding: controlBinding("mute-track", target: "\(role)-\(prevSlot)")))
        }
        prevSlot = curSlot
      }
    }
    pos += sec.steps
  }
  return buildAccumulatorNet(events)
}

func linearControlNet(_ target: String, template: SongTemplate) -> NetBundle {
  var events: [StructureEvent] = []
  var wasActive = template.sections[0].active.contains(target)
  var pos = 0
  for si in 1..<max(template.sections.count, 1) {
    pos += template.sections[si - 1].steps
    let isActive = template.sections[si].active.contains(target)
    if isActive != wasActive {
      events.append(
        StructureEvent(
          tick: pos,
          binding: controlBinding(isActive ? "unmute-track" : "mute-track", target: target)
        ))
      wasActive = isActive
    }
  }
  return buildAccumulatorNet(events)
}

func linearStopNet(_ totalSteps: Int) -> NetBundle {
  buildAccumulatorNet([
    StructureEvent(tick: totalSteps, binding: controlBinding("stop-transport", target: ""))
  ])
}

func isStingerID(_ id: String) -> Bool {
  guard id.hasPrefix("hit"), id.utf8.count > 3 else { return false }
  return id.utf8.dropFirst(3).allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
}

/// `songStructure(proj, template, musicNets)` — adds struct-* nets, sets
/// `proj.structure`, returns the nets that start muted.
func songStructure(_ proj: inout Project, template: SongTemplate, musicNets: [String]) -> [String] {
  var totalSteps = 0
  for sec in template.sections { totalSteps += sec.steps }
  var initialMutes: [String] = []

  var slotRoles = Set<String>()
  for id in musicNets {
    if let g = proj.nets[id]?.riffGroup, !g.isEmpty { slotRoles.insert(g) }
  }
  var processed = Set<String>()
  for netId in musicNets {
    guard let nb = proj.nets[netId] else { continue }
    if !nb.riffGroup.isEmpty {
      let role = nb.riffGroup
      if processed.contains(role) { continue }
      processed.insert(role)
      let slotMap = template.slotMap[role] ?? []
      proj.nets["struct-\(role)"] = roleControlNet(role, slotMap: slotMap, template: template)
      var firstSlot = -1
      if let f = slotMap.first, !f.isEmpty { firstSlot = f[0] }
      for nId in musicNets {
        if let nb2 = proj.nets[nId], nb2.riffGroup == role {
          let slotIdx = extractSlotIndex(nId, role)
          if slotIdx != firstSlot || firstSlot < 0 { initialMutes.append(nId) }
        }
      }
    } else if !slotRoles.contains(netId) {
      // Stingers are one-shot accents: never driven by structure, always muted. (The JS
      // branch references names that are out of scope, but compose() adds stingers only
      // after songStructure, so it is unreachable there; both of its arms muted the net.)
      if nb.track.group == "stinger" || isStingerID(netId) {
        initialMutes.append(netId)
        continue
      }
      proj.nets["struct-\(netId)"] = linearControlNet(netId, template: template)
      if !template.sections[0].active.contains(netId) { initialMutes.append(netId) }
    }
  }
  proj.nets["struct-stop"] = linearStopNet(totalSteps)

  proj.structure = template.sections.map { sec in
    var s = Section(name: sec.name, steps: sec.steps)
    s.phrases = sec.phrases
    return s
  }
  return initialMutes
}

// MARK: - Arrange helpers (fade / break / feel / macro curves)

let boundaryStagger = 12

/// arrange.js `buildControlBundle`, in its parsed (`parseNetBundle`) form.
func buildControlBundle(
  steps: Int, ctrlAt: [Int: ControlBinding], sink: Bool = false, placePrefix: String = "p",
  transPrefix: String = "t"
) -> NetBundle {
  var nb = NetBundle()
  nb.role = "control"
  nb.track = Track()
  let (cx, cy, radius) = ringLayout(steps)
  let placeCount = sink ? steps + 1 : steps
  let angleDen = Double(sink ? steps + 1 : steps)
  for i in 0..<placeCount {
    let angle = Double(i) / angleDen * 2 * Double.pi
    nb.places["\(placePrefix)\(i)"] = Place(
      initial: [i == 0 ? 1 : 0], x: cx + radius * 0.7 * cos(angle),
      y: cy + radius * 0.7 * sin(angle), label: nil)
  }
  for i in 0..<steps {
    let tAngle = (Double(i) + 0.5) / angleDen * 2 * Double.pi
    let tid = "\(transPrefix)\(i)"
    nb.transitions[tid] = Transition(
      x: cx + radius * cos(tAngle), y: cy + radius * sin(tAngle), label: nil)
    if let c = ctrlAt[i] { nb.controlBindings[tid] = c }
    let prev = "\(placePrefix)\(i)"
    let next = sink ? "\(placePrefix)\(i + 1)" : "\(placePrefix)\((i + 1) % steps)"
    nb.arcs.append(Arc(source: prev, target: tid, weight: [1], inhibit: false))
    nb.arcs.append(Arc(source: tid, target: next, weight: [1], inhibit: false))
  }
  return nb
}

private func fadeControlNet(_ target: String, action: String, steps: Int, hitPos: Int) -> NetBundle
{
  let hit = hitPos >= steps ? steps - 1 : hitPos
  return buildControlBundle(steps: steps, ctrlAt: [hit: controlBinding(action, target: target)])
}

func fadeIn(_ proj: inout Project, targets: [String], steps: Int) -> [String] {
  let steps = steps < 8 ? 32 : steps
  var muted: [String] = []
  for (i, target) in targets.enumerated() {
    if proj.nets[target] == nil { continue }
    muted.append(target)
    let offset = (i + 1) * (steps / (targets.count + 1))
    proj.nets["fade-in-\(target)"] = fadeControlNet(
      target, action: "unmute-track", steps: steps, hitPos: offset)
  }
  return muted
}

func fadeOut(_ proj: inout Project, targets: [String], steps: Int) {
  let steps = steps < 8 ? 32 : steps
  for (i, target) in targets.enumerated() {
    if proj.nets[target] == nil { continue }
    let offset = steps - (targets.count - i) * (steps / (targets.count + 1))
    proj.nets["fade-out-\(target)"] = fadeControlNet(
      target, action: "mute-track", steps: steps, hitPos: offset)
  }
}

func drumBreak(_ proj: inout Project, targets: [String], cycleLen: Int, breakLen: Int) {
  let cycleLen = cycleLen < 16 ? 64 : cycleLen
  var breakLen = breakLen < 4 ? 8 : breakLen
  if breakLen >= cycleLen { breakLen = cycleLen / 4 }
  let mutePos = cycleLen / 2
  let sorted = targets.sorted(by: jsStringLess)
  let unmuteBase = (mutePos + breakLen) % cycleLen
  let headroom = (((mutePos - unmuteBase - 1) % cycleLen) + cycleLen) % cycleLen
  var maxStagger = boundaryStagger
  if maxStagger > headroom { maxStagger = headroom }
  if maxStagger < 1 { maxStagger = 1 }
  for (i, target) in sorted.enumerated() {
    if proj.nets[target] == nil { continue }
    let unmutePos = (mutePos + breakLen + (i % maxStagger)) % cycleLen
    var ctrlAt: [Int: ControlBinding] = [:]
    ctrlAt[mutePos] = controlBinding("mute-track", target: target)
    ctrlAt[unmutePos] = controlBinding("unmute-track", target: target)
    proj.nets["break-\(target)"] = buildControlBundle(steps: cycleLen, ctrlAt: ctrlAt)
  }
}

/// A feel-curve point: the section it lands on and the (x, y) puck position.
public struct FeelPoint {
  public var section: String
  public var x: Double
  public var y: Double
}

private func sectionStarts(_ tmpl: SongTemplate) -> (starts: [String: Int], total: Int) {
  var starts: [String: Int] = [:]
  var cum = 0
  for sec in tmpl.sections {
    if starts[sec.name] == nil { starts[sec.name] = cum }
    cum += sec.steps
  }
  return (starts, cum)
}

func injectFeelCurve(_ proj: inout Project, tmpl: SongTemplate, curve: [FeelPoint]) {
  let (starts, total) = sectionStarts(tmpl)
  if total == 0 { return }
  var points: [(tick: Int, control: ControlBinding)] = []
  for e in curve {
    guard let tick = starts[e.section] else { continue }
    var c = controlBinding("set-feel", target: "")
    c.macroParams = obj([("x", .number(e.x)), ("y", .number(e.y))])
    points.append((tick, c))
  }
  if points.isEmpty { return }
  var ctrlAt: [Int: ControlBinding] = [:]
  for p in points.enumerated().sorted(by: {
    $0.element.tick != $1.element.tick ? $0.element.tick < $1.element.tick : $0.offset < $1.offset
  }).map(\.element) { ctrlAt[p.tick] = p.control }
  proj.nets["feel-curve"] = buildControlBundle(
    steps: total, ctrlAt: ctrlAt, placePrefix: "fp", transPrefix: "ft")
}

/// `injectMacroCurve(proj, tmpl, curve)` — `curve` is the envelope's `macroCurve` array
/// of `{ section, macro, bars? }` objects.
func injectMacroCurve(_ proj: inout Project, tmpl: SongTemplate, curve: [JSONValue]) {
  injectCurve(&proj, tmpl: tmpl, curve: curve, net: "macro-curve", prefixes: ("mp", "mt")) { e in
    guard let m = e["macro"], m.isTruthy else { return nil }
    var c = controlBinding("fire-macro", target: "")
    if let name = m.string, !name.isEmpty { c.macro = name }
    if let bars = e["bars"]?.double, bars > 0 { c.macroBars = bars }
    return c
  }
}

/// `resolveCurvePoints` and the control bundle built from its points (feel / macro curves).
/// An entry whose `section` names an `Object.prototype` property resolves, in JS, to the
/// inherited function: the point is kept (so the net is built) but its tick never matches a
/// transition, so it adds no control. Sections with such names never get a start of their own.
func injectCurve(
  _ proj: inout Project, tmpl: SongTemplate, curve: [JSONValue], net: String,
  prefixes: (place: String, transition: String), value: (JSONValue) -> ControlBinding?
) {
  let (starts, total) = sectionStarts(tmpl)
  if total == 0 { return }
  var points: [(tick: Int?, control: ControlBinding)] = []
  for e in curve {
    guard let section = e["section"]?.string else { continue }
    let tick: Int?
    if objectProtoKeys.contains(section) {
      tick = nil
    } else if let t = starts[section] {
      tick = t
    } else {
      continue
    }
    guard let c = value(e) else { continue }
    points.append((tick, c))
  }
  if points.isEmpty { return }
  var ctrlAt: [Int: ControlBinding] = [:]
  let timed = points.enumerated().compactMap { p in
    p.element.tick.map { (p.offset, $0, p.element.control) }
  }
  for p in timed.sorted(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }) { ctrlAt[p.1] = p.2 }
  proj.nets[net] = buildControlBundle(
    steps: total, ctrlAt: ctrlAt, placePrefix: prefixes.place, transPrefix: prefixes.transition)
}
