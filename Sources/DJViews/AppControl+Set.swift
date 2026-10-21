import DJCore
import Foundation

/// A set being played: which set, the deck its current track is on, where it is, and what the
/// last hand-off is doing. Runtime only (the set file keeps the cursor).
struct SetRun {
  var name: String
  var deck: String
  var cursor: Int
  var phase = "idle"  // idle | loading | fading | done | failed
  var progress = ""
  var warnings: [String] = []
  var task: Task<Void, Never>?
  /// `dj_set auto`: hand off to the next track by itself, `leadBars` bars before the fade is due.
  var auto = false
  var leadBars = 1
  /// After each hand-off turn Wander on for the incoming deck and off for the outgoing one.
  var wander = false
  /// The playing track's length in bars, looked up once per track (nil: not yet / unknown).
  var currentBars: Int?
}

extension AppModel {
  // MARK: staging (`load: false`) and keeping

  /// Save what `dj_compose` / `dj_inspired` / `dj_import` made, and add it to a set when the
  /// request names one (`set`, optional `slot`, `mixOutBar`, `fadeBars`). Never fails the call.
  func keepComposition(
    method: String, p: JSONValue, deck: String, envelope: JSONValue, importSummary: JSONValue?
  ) -> JSONObject {
    var o = JSONObject()
    var req = p.object ?? JSONObject()
    if let importSummary { req["import"] = importSummary }
    do {
      let kept = try compositionStore.save(
        kind: method == "importScore"
          ? "import" : (p["inspiredBy"]?.string?.isEmpty == false ? "inspired" : "compose"),
        deck: deck, envelope: envelope, request: .object(req))
      o["saved"] = .string(kept.url.path)
      if let setName = p["set"]?.string, !setName.isEmpty {
        let id = kept.url.deletingPathExtension().lastPathComponent
        var set = (try? setStore.load(setName)) ?? DJSet(name: setName, created: Self.isoNow())
        var item = SetItem(
          composition: id, slot: p["slot"]?.int, mixOutBar: p["mixOutBar"]?.int,
          fadeBars: p["fadeBars"]?.int)
        if let slot = item.slot, let at = set.items.firstIndex(where: { $0.slot == slot }) {
          set.items[at] = item
        } else if !set.items.contains(where: { $0.composition == id }) {
          if item.slot == nil {
            item.slot = set.plan.indices.first { i in !set.items.contains { $0.slot == i } }
          }
          set.items.append(item)
          set.items.sort { ($0.slot ?? Int.max) < ($1.slot ?? Int.max) }
        }
        try setStore.save(set)
        o["set"] = .object(
          JSONObject([("name", .string(set.name)), ("items", .int(set.items.count))]))
      }
    } catch { o["saved"] = .string("not saved: \(error)") }
    return o
  }

  static func isoNow() -> String {
    let f = ISO8601DateFormatter()
    return f.string(from: Date())
  }

  // MARK: dj_set

  func controlSet(_ p: JSONValue) async throws -> JSONValue {
    let action = p["action"]?.string ?? "list"
    func name() throws -> String {
      guard let n = p["set"]?.string, !n.isEmpty else {
        throw ControlRequestError.bad("`set` (the set's name) is required")
      }
      return n
    }
    func load(_ n: String) throws -> DJSet {
      do { return try setStore.load(n) } catch { throw ControlRequestError.bad("\(error)") }
    }
    func entries() -> [String: CompositionStore.Entry] {
      Dictionary(compositionStore.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
    func info(_ e: CompositionStore.Entry) -> CompositionInfo {
      CompositionInfo(
        id: e.id, name: e.name, energy: e.energy, key: e.key, tempo: e.tempo, bars: e.bars)
    }
    func resolve(_ q: String) throws -> CompositionStore.Entry {
      do { return try compositionStore.envelope(matching: q).entry } catch {
        throw ControlRequestError.bad("\(error)")
      }
    }

    switch action {
    case "list":
      return .object(
        JSONObject([
          ("directory", .string(setStore.directory.path)),
          (
            "sets",
            .array(
              setStore.list().map { s in
                .object(
                  JSONObject([
                    ("name", .string(s.name)), ("slots", .int(s.plan.count)),
                    ("tracks", .int(s.items.count)), ("cursor", .int(s.cursor)),
                    ("created", .string(s.created)),
                  ]))
              })
          ),
        ]))

    case "show":
      return setJSON(try load(try name()), entries: entries())

    case "plan":
      let n = try name()
      var set = (try? setStore.load(n)) ?? DJSet(name: n, created: Self.isoNow())
      if let slots = p["slots"]?.array {
        set.plan = slots.map {
          SetPlanSlot(
            label: $0["label"]?.string ?? "slot", energy: $0["energy"]?.double ?? 0.5,
            bpm: $0["bpm"]?.double, key: $0["key"]?.string, bars: $0["bars"]?.int)
        }
      } else if let count = p["count"]?.int {
        var range: ClosedRange<Double>?
        if let r = p["bpm"]?.array, r.count == 2, let a = r[0].double, let b = r[1].double, a <= b {
          range = a...b
        }
        set.plan = SetPlanner.curve(shape: p["shape"]?.string ?? "arc", count: count, bpm: range)
      } else {
        throw ControlRequestError.bad(
          "plan needs `slots` [{label, energy 0-1, bpm?, key?, bars?}] or `count` (+ `shape` arc|rise|plateau, `bpm` [low, high])"
        )
      }
      if let f = p["fadeBars"]?.int { set.fadeBars = min(32, max(1, f)) }
      if p["keepItems"]?.bool != true {
        set.items = []
        set.cursor = 0
      }
      try setStore.save(set)
      return setJSON(set, entries: entries())

    case "add":
      let n = try name()
      var set = (try? setStore.load(n)) ?? DJSet(name: n, created: Self.isoNow())
      let e = try resolve(p["id"]?.string ?? "")
      var item = SetItem(
        composition: e.id, slot: p["slot"]?.int, mixOutBar: p["mixOutBar"]?.int,
        fadeBars: p["fadeBars"]?.int)
      if let slot = item.slot, !set.plan.indices.contains(slot) {
        throw ControlRequestError.bad("slot \(slot) is not in the plan (\(set.plan.count) slots)")
      }
      set.items.removeAll { $0.composition == e.id || (item.slot != nil && $0.slot == item.slot) }
      if item.slot == nil {
        item.slot = set.plan.indices.first { i in !set.items.contains { $0.slot == i } }
      }
      set.items.append(item)
      set.items.sort { ($0.slot ?? Int.max) < ($1.slot ?? Int.max) }
      try setStore.save(set)
      return setJSON(set, entries: entries())

    case "remove":
      let n = try name()
      var set = try load(n)
      if let i = p["index"]?.int, set.items.indices.contains(i) {
        set.items.remove(at: i)
      } else if let q = p["id"]?.string {
        let e = try resolve(q)
        set.items.removeAll { $0.composition == e.id }
      } else {
        throw ControlRequestError.bad("remove needs `index` or `id`")
      }
      set.cursor = min(set.cursor, max(0, set.items.count - 1))
      try setStore.save(set)
      return setJSON(set, entries: entries())

    case "sequence":
      // Fill the plan from what's saved: energy first, then tempo, then key distance.
      let n = try name()
      var set = try load(n)
      guard !set.plan.isEmpty else {
        throw ControlRequestError.bad("`\(n)` has no plan yet: dj_set plan first")
      }
      let all = entries()
      let pool: [CompositionInfo] =
        p["from"]?.string == "set"
        ? set.items.compactMap { all[$0.composition] }.map(info) : all.values.map(info)
      let r = SetPlanner.sequence(plan: set.plan, pool: pool, kept: set.items)
      set.items = r.items
      set.cursor = 0
      try setStore.save(set)
      var o = setJSON(set, entries: all).object ?? JSONObject()
      o["gaps"] = .array(
        r.gaps.map { g in
          var j = JSONObject([
            ("slot", .int(g.slot)), ("label", .string(g.label)), ("energy", .number(g.energy)),
          ])
          if let b = g.bpm { j["bpm"] = .number(b) }
          if let k = g.key { j["key"] = .string(k) }
          if let b = g.bars { j["bars"] = .int(b) }
          if let c = g.closest { j["closest"] = .string(c) }
          j["compose"] = .string(
            "dj_compose / dj_inspired with load false, set \"\(n)\", slot \(g.slot), energy \(g.energy)"
              + (g.bpm.map { ", tempo \(Int($0))" } ?? "") + (g.key.map { ", key \($0)" } ?? ""))
          return .object(j)
        })
      o["tempoJumps"] = .array(
        r.tempoJumps.map {
          .object(
            JSONObject([
              ("from", .int($0.from)), ("to", .int($0.to)),
              ("ratio", .number(($0.ratio * 100).rounded() / 100)),
            ]))
        })
      return .object(o)

    case "start":
      let n = try name()
      var set = try load(n)
      guard let first = set.items.first else {
        throw ControlRequestError.bad("`\(n)` has no tracks (dj_set add / sequence)")
      }
      let deck = p["deck"]?.string ?? "A"
      _ = try requireDeck(deck)
      setRun?.task?.cancel()
      let env: JSONValue
      do { env = try compositionStore.envelope(matching: first.composition).envelope } catch {
        throw ControlRequestError.bad("\(error)")
      }
      guard await prepareAndLoad(deck, try .share(payload: env)) else {
        throw ControlRequestError.bad(status)
      }
      if p["play"]?.bool == true { engine?.perform(.play(deck: deck, on: true)) }
      set.cursor = 0
      try setStore.save(set)
      setRun = SetRun(name: set.name, deck: deck, cursor: 0)
      poll()
      return setStatus(set)

    case "mix":
      let n = try name()
      let set = try load(n)
      let task = try beginSetMix(set, fadeBars: p["fadeBars"]?.int)
      if p["wait"]?.bool == true { await task.value }
      return setStatus(set)

    case "auto":
      let n = try name()
      let set = try load(n)
      guard var run = setRun, run.name == set.name else {
        throw ControlRequestError.bad("`\(n)` isn't running: dj_set start first")
      }
      if let on = p["on"]?.bool { run.auto = on }
      if let lead = p["leadBars"]?.int { run.leadBars = min(8, max(0, lead)) }
      if let w = p["wander"]?.bool { run.wander = w }
      setRun = run
      return setStatus(set)

    case "status":
      let n = try name()
      return setStatus(try load(n))

    case "abort":
      guard var run = setRun else { throw ControlRequestError.bad("no set is running") }
      run.task?.cancel()
      run.phase = "idle"
      run.progress = "aborted"
      run.task = nil
      setRun = run
      return .object(JSONObject([("aborted", .bool(true))]))

    default:
      throw ControlRequestError.bad(
        "unknown action \(action): list, show, plan, add, remove, sequence, start, mix, auto, status, abort"
      )
    }
  }

  // MARK: starting a hand-off, by hand or on its own

  /// Begin the hand-off from the deck the set is on to the next track (`dj_set mix`, and the auto
  /// runner). The task runs `runSetMix`; the caller may await it.
  @discardableResult
  func beginSetMix(_ set: DJSet, fadeBars override: Int?) throws -> Task<Void, Never> {
    guard var run = setRun, run.name == set.name else {
      throw ControlRequestError.bad("`\(set.name)` isn't running: dj_set start first")
    }
    guard run.task == nil || run.phase != "fading" && run.phase != "loading" else {
      throw ControlRequestError.bad("a hand-off is already running (dj_set status / abort)")
    }
    let next = run.cursor + 1
    guard set.items.indices.contains(next) else {
      throw ControlRequestError.bad("`\(set.name)` is on its last track")
    }
    let out = run.deck
    let inn = out == "A" ? "B" : "A"
    guard engine?[out]?.beatState != nil, engine?[out]?.playing == true else {
      throw ControlRequestError.bad("deck \(out) isn't playing: dj_perform play first")
    }
    let current = set.items[run.cursor]
    let fade = min(32, max(1, override ?? current.fadeBars ?? set.fadeBars))
    run.phase = "loading"
    run.progress = "loading \(set.items[next].composition)"
    run.warnings = []
    let task = Task { @MainActor in
      await self.runSetMix(set: set.name, out: out, inn: inn, next: next, fadeBars: fade)
    }
    run.task = task
    setRun = run
    return task
  }

  /// The auto runner (`AppModel.poll`): while a set is running with `auto` on and its deck is
  /// playing, begin the hand-off `leadBars` before the fade is due (`SetAuto`). `bar` overrides the
  /// deck's clock reading (1-based), for tests.
  func serviceSetAuto(bar override: Int? = nil) {
    // a few checks a second is plenty (poll runs every frame); a test's explicit bar always runs
    if override == nil {
      let now = uptime()
      guard now - setAutoCheckedAt >= 0.25 else { return }
      setAutoCheckedAt = now
    }
    guard let run = setRun, run.auto, run.phase != "loading", run.phase != "fading",
      let d = engine?[run.deck], d.playing,
      let bar = override ?? d.beatState.map({ $0.bar + 1 }),
      let set = try? setStore.load(run.name), set.items.indices.contains(run.cursor + 1)
    else { return }
    let item = set.items[run.cursor]
    if setRun?.currentBars == nil {
      setRun?.currentBars = compositionStore.list().first { $0.id == item.composition }?.bars
    }
    let fade = item.fadeBars ?? set.fadeBars
    guard let start = SetAuto.startBar(bars: setRun?.currentBars, item: item, fadeBars: fade),
      SetAuto.due(bar: bar, startBar: start, leadBars: run.leadBars),
      // not again on the loop round: only from the start bar up to the track's end
      bar <= (setRun?.currentBars ?? .max)
    else { return }
    _ = try? beginSetMix(set, fadeBars: nil)
  }

  // MARK: the hand-off

  /// The same hand-off every time: load the next track on the idle deck with its bass EQ pulled
  /// down, start it, tempo-match and bar-align it to the outgoing deck (`Deck.sync`), crossfade
  /// over `fadeBars` bars with the bass handed over at the midpoint, then stop the outgoing deck.
  /// Every step goes through `DJEngine.perform`, so it records like the performer's own hands.
  func runSetMix(set name: String, out: String, inn: String, next: Int, fadeBars: Int) async {
    guard let dj = engine, var set = try? setStore.load(name) else { return }
    func note(_ phase: String, _ progress: String = "") {
      setRun?.phase = phase
      setRun?.progress = progress
    }
    let item = set.items[next]
    guard let env = try? compositionStore.envelope(matching: item.composition).envelope,
      let source = try? DeckSourceDescriptor.share(payload: env)
    else { return note("failed", "can't read \(item.composition)") }
    guard await prepareAndLoad(inn, source) else { return note("failed", status) }
    if Task.isCancelled { return note("idle", "aborted") }

    dj.perform(.param(deck: inn, name: "eqLow", value: 0.12))  // its bass waits for the swap
    let from = min(1, max(0, dj.crossfader))
    let to = inn == "B" ? 1.0 : 0.0
    dj.perform(.play(deck: inn, on: true))
    dj.perform(.sync(deck: inn, align: "bar"))
    if let a = dj[out]?.effectiveBPM, let b = dj[inn]?.effectiveBPM, abs(a / b - 1) > 0.01 {
      setRun?.warnings.append(
        "tempo gap: \(Int(a)) vs \(Int(b)) BPM (the fader range can't match them)")
    }

    let barSeconds = 240 / max(40, dj[out]?.effectiveBPM ?? 120)
    let steps = fadeBars * 4
    for i in 1...steps {
      if Task.isCancelled { return note("idle", "aborted") }
      note("fading", "\(i)/\(steps)")
      dj.perform(.crossfader(from + (to - from) * Double(i) / Double(steps)))
      if i == steps / 2 {  // bass handover
        dj.perform(.param(deck: inn, name: "eqLow", value: 0.5))
        dj.perform(.param(deck: out, name: "eqLow", value: 0.12))
      }
      await setSleep(barSeconds / 4)
    }
    dj.perform(.play(deck: out, on: false))
    dj.perform(.param(deck: out, name: "eqLow", value: 0.5))
    set.cursor = next
    try? setStore.save(set)
    setRun?.deck = inn
    setRun?.cursor = next
    setRun?.currentBars = nil
    if setRun?.wander == true {  // the walk follows the music: on for the incoming deck
      dj.perform(.wander(deck: out, on: false))
      dj.perform(.wander(deck: inn, on: true))
    }
    note("done", "on deck \(inn): \(next + 1)/\(set.items.count)")
    poll()
    wakeAgentAfterHandoff(set: set, deck: inn, index: next)
  }

  /// Tell the agent a hand-off finished (when wakes are on): what plays now, when the next hand-off
  /// is due, how many tracks remain, so it can restock, re-plan or just say `ok`.
  func wakeAgentAfterHandoff(set: DJSet, deck: String, index: Int) {
    guard let agent = agentIfCreated, agent.wakeOnEvents else { return }
    let names = Dictionary(
      compositionStore.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let title = names[set.items[index].composition]?.name ?? set.items[index].composition
    let left = set.items.count - 1 - index
    var text =
      "[app event] hand-off complete in set \"\(set.name)\": deck \(deck) now plays \"\(title)\" "
      + "(track \(index + 1) of \(set.items.count)"
    if let bpm = engine?[deck]?.effectiveBPM { text += ", \(Int(bpm)) BPM" }
    text += "). "
    if left > 0 {
      if let bars = names[set.items[index].composition]?.bars, let bpm = engine?[deck]?.effectiveBPM
      {
        let start = SetAuto.startBar(
          bars: bars, item: set.items[index], fadeBars: set.items[index].fadeBars ?? set.fadeBars)
        if let start {
          text +=
            "The next hand-off begins at bar \(start) (about \(Int(Double(start - 1) * 240 / bpm)) s). "
        }
      }
      text += "\(left) track\(left == 1 ? "" : "s") left. "
    } else {
      text += "This is the last track. "
    }
    text += "Check dj_set status; restock, re-plan or adjust only if it helps, else reply `ok`."
    agent.wake(text)
  }

  // MARK: JSON

  func setJSON(_ set: DJSet, entries: [String: CompositionStore.Entry]) -> JSONValue {
    var o = JSONObject([
      ("name", .string(set.name)), ("fadeBars", .int(set.fadeBars)), ("cursor", .int(set.cursor)),
    ])
    o["plan"] = .array(
      set.plan.enumerated().map { i, s in
        var j = JSONObject([
          ("slot", .int(i)), ("label", .string(s.label)), ("energy", .number(s.energy)),
        ])
        if let b = s.bpm { j["bpm"] = .number(b) }
        if let k = s.key { j["key"] = .string(k) }
        if let b = s.bars { j["bars"] = .int(b) }
        return .object(j)
      })
    o["tracks"] = .array(
      set.items.enumerated().map { i, it in
        var j = JSONObject([("index", .int(i)), ("id", .string(it.composition))])
        if let s = it.slot { j["slot"] = .int(s) }
        if let e = entries[it.composition] {
          j["name"] = .string(e.name)
          if let t = e.tempo { j["tempo"] = .number(t) }
          if let x = e.energy { j["energy"] = .number(x) }
          if let k = e.key { j["key"] = .string(k) }
          if let b = e.bars { j["bars"] = .int(b) }
        } else {
          j["missing"] = .bool(true)
        }
        if let b = it.mixOutBar { j["mixOutBar"] = .int(b) }
        if let f = it.fadeBars { j["fadeBars"] = .int(f) }
        return .object(j)
      })
    o["empty"] = .array(
      set.plan.indices.filter { i in !set.items.contains { $0.slot == i } }.map { .int($0) })
    return .object(o)
  }

  func setStatus(_ set: DJSet) -> JSONValue {
    var o =
      setJSON(
        set,
        entries: Dictionary(
          compositionStore.list().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      ).object ?? JSONObject()
    if let run = setRun, run.name == set.name {
      var r = JSONObject([
        ("deck", .string(run.deck)), ("cursor", .int(run.cursor)), ("phase", .string(run.phase)),
        ("progress", .string(run.progress)), ("auto", .bool(run.auto)),
        ("wander", .bool(run.wander)), ("leadBars", .int(run.leadBars)),
        ("warnings", .array(run.warnings.map { .string($0) })),
      ])
      if run.auto, set.items.indices.contains(run.cursor),
        let start = SetAuto.startBar(
          bars: run.currentBars
            ?? compositionStore.list().first {
              $0.id == set.items[run.cursor].composition
            }?.bars, item: set.items[run.cursor],
          fadeBars: set.items[run.cursor].fadeBars ?? set.fadeBars)
      {
        r["nextMixAtBar"] = .int(start)
      }
      if let d = engine?[run.deck], let bs = d.beatState {
        r["bar"] = .int(bs.bar + 1)
        if let b = set.items.indices.contains(run.cursor) ? run.cursor : nil,
          let bars = compositionStore.list().first(where: { $0.id == set.items[b].composition })?
            .bars
        {
          r["barsInTrack"] = .int(bars)
        }
      }
      o["running"] = .object(r)
    }
    return .object(o)
  }
}
