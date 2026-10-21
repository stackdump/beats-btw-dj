import DJCore
import Foundation

/// What the runner holds for one deck: the clips its loops are on the row as, and what it has
/// launched this pass. The list it plays is the deck's own (`Deck.layerEntries`): a track's
/// `loopLayers` at load, then whatever Wander adds, swaps and removes.
struct LayerPlan {
  /// The deck's `layerEpoch` this was built for (a new track starts afresh).
  var epoch = -1
  /// Loop path → its clip on the loop row.
  var clipIDs: [String: String] = [:]
  var preparing: Set<String> = []
  /// Windows already launched / stopped this pass, as "path@start".
  var launched: Set<String> = []
  var stopped: Set<String> = []
  /// Loops looping now, by path.
  var active: Set<String> = []
  var lastBar = 0
  var problems: [String] = []
}

extension AppModel {
  // MARK: attaching (compose / import)

  /// Resolve the loops a request's `layers` name against the library, and put them in the envelope as
  /// `loopLayers` with each loop's path, name, length and category: what is saved and loaded is
  /// unambiguous and plays (and Wander-edits) without the library at hand. An unknown or ambiguous
  /// loop is an error naming the candidates.
  func attachLayers(to envelope: JSONValue, from p: JSONValue) async throws -> JSONValue {
    guard p["layers"] != nil || envelope[LoopLayers.envelopeKey] != nil else { return envelope }
    let specs: [LoopLayerSpec]
    do { specs = try LoopLayers.parse(p["layers"] ?? envelope[LoopLayers.envelopeKey]) } catch let e
      as PianoRollError
    {
      throw ControlRequestError.bad(e.description)
    }
    guard !specs.isEmpty else { return envelope }
    await loadStockLoops()
    let bpm = envelope["tempo"]?.double
    var resolved: [LoopLayerSpec] = []
    for var s in specs {
      switch LoopLayers.resolve(s.loop, in: stockLoops, near: bpm) {
      case .success(let l):
        s.loop = l.path
        s.name = l.name
        s.beats = l.beats
        s.category = l.category
      case .failure(let e): throw ControlRequestError.bad(e.description)
      }
      resolved.append(s)
    }
    var o = envelope.object ?? JSONObject()
    o[LoopLayers.envelopeKey] = LoopLayers.json(resolved)
    return .object(o)
  }

  // MARK: the runner

  /// The layers' clock (`AppModel.poll`, ≤ 4×/s). For each net deck: keep the pool Wander draws layer
  /// moves from fresh; put the loops its layer list names on the row; and, while it plays, bring each
  /// in a bar early and take it out a bar early, so the loop bank's launch quantizing puts both on the
  /// bar lines. `bars` overrides a deck's clock (1-based; tests).
  func serviceLayers(bars override: [String: Int]? = nil) {
    guard let dj = engine else { return }
    if override == nil {
      let now = uptime()
      guard now - layersCheckedAt >= 0.25 else { return }
      layersCheckedAt = now
    }
    for name in dj.decks.keys.sorted() {
      guard let d = dj[name], d.mode == .net else {
        if layerPlans[name] != nil { releaseLayers(name) }
        continue
      }
      refreshLayerPool(name, d)
      var plan = layerPlans[name] ?? LayerPlan()
      if plan.epoch != d.layerEpoch {  // a new track: what the last one had going stops
        stopLayers(&plan)
        plan.launched = []
        plan.stopped = []
        plan.problems = []
        plan.epoch = d.layerEpoch
      }
      let entries = d.layerEntries
      if !entries.isEmpty, stockLoops.isEmpty { Task { await loadStockLoops() } }
      for e in entries
      where plan.clipIDs[e.loop.path] == nil && !plan.preparing.contains(e.loop.path) {
        guard let stock = stockLoops.first(where: { $0.path == e.loop.path }) else { continue }
        plan.preparing.insert(e.loop.path)
        prepareLayerClip(deck: name, stock: stock, keyLock: e.keyLock)
      }
      guard d.playing, let bar = override?[name] ?? d.beatState.map({ $0.bar + 1 }) else {
        stopLayers(&plan)
        layerPlans[name] = plan
        continue
      }
      if bar + 1 < plan.lastBar {  // the track went round again (or was seeked back)
        plan.launched = []
        plan.stopped = []
      }
      plan.lastBar = bar
      for e in entries {
        guard let id = plan.clipIDs[e.loop.path] else { continue }
        let key = "\(e.loop.path)@\(e.start)"
        let comeIn = max(1, e.start - 1)
        let goOut = e.end - 1
        if bar >= comeIn, bar < goOut, !plan.launched.contains(key) {
          dj.perform(.clipGain(id: id, value: LoopLayers.gain(db: e.gainDB)))
          dj.perform(.clipLoop(id: id, on: true))
          plan.launched.insert(key)
          plan.active.insert(e.loop.path)
        }
        if bar >= goOut, plan.launched.contains(key), !plan.stopped.contains(key) {
          plan.stopped.insert(key)
        }
      }
      // a loop is out when none of its windows is still on (also one whose entry was taken away)
      for path in plan.active {
        let on = entries.contains { e in
          let k = "\(e.loop.path)@\(e.start)"
          return e.loop.path == path && plan.launched.contains(k) && !plan.stopped.contains(k)
        }
        if !on, let id = plan.clipIDs[path] {
          dj.perform(.clipLoop(id: id, on: false))
          plan.active.remove(path)
        }
      }
      layerPlans[name] = plan
    }
  }

  /// Put one library loop on the row (decoded off the main thread), with its key lock, then let the
  /// runner find it ready.
  func prepareLayerClip(deck: String, stock: StockLoop, keyLock: Bool) {
    Task { @MainActor in
      let id = await self.addStockLoopToRow(stock)
      self.layerPlans[deck]?.preparing.remove(stock.path)
      guard let id else {
        self.layerPlans[deck]?.problems.append("\(stock.name): could not go on the row")
        return
      }
      self.layerPlans[deck]?.clipIDs[stock.path] = id
      if keyLock { self.engine?.perform(.clipKeyLock(id: id, on: true)) }
    }
  }

  /// The candidates for Wander's layer moves on `deck`: library sounds that fit its tempo and key,
  /// rebuilt when either changes (or the library arrives).
  func refreshLayerPool(_ deck: String, _ d: Deck) {
    guard !stockLoops.isEmpty, let bpm = d.baseBPM else { return }
    let key = d.layerKey
    let stamp = "\(Int(bpm.rounded()))|\(key ?? "-")|\(stockLoops.count)"
    guard layerPoolStamps[deck] != stamp else { return }
    layerPoolStamps[deck] = stamp
    d.layerPool = LoopLayers.pool(library: stockLoops, bpm: bpm, key: key)
  }

  /// Stop what the plan has looping (on the next launch line).
  func stopLayers(_ plan: inout LayerPlan) {
    for path in plan.active {
      if let id = plan.clipIDs[path] { engine?.perform(.clipLoop(id: id, on: false)) }
    }
    plan.active = []
  }

  /// Take the deck's layers out (it left net mode): what it left looping stops.
  func releaseLayers(_ deck: String) {
    guard var plan = layerPlans[deck] else { return }
    stopLayers(&plan)
    layerPlans[deck] = nil
  }

  /// What `dj_state` shows for a deck's layers: the list it is performing (a track's, then Wander's
  /// edits), what is looping, and how many loops Wander could draw from.
  func layersJSON(_ deck: String) -> JSONValue? {
    guard let d = engine?[deck], d.mode == .net, !d.layerEntries.isEmpty || !d.layerPool.isEmpty
    else {
      return nil
    }
    let plan = layerPlans[deck] ?? LayerPlan()
    let onRow = d.layerEntries.allSatisfy { plan.clipIDs[$0.loop.path] != nil }
    var o = JSONObject([("ready", .bool(onRow)), ("pool", .int(d.layerPool.count))])
    o["layers"] = .array(
      d.layerEntries.map { e in
        .object(
          JSONObject([
            ("loop", .string(e.loop.name)), ("bars", .string("\(e.start)–\(e.end - 1)")),
            ("gain", .number(e.gainDB)),
            ("looping", .bool(plan.active.contains(e.loop.path))),
            ("onRow", .bool(plan.clipIDs[e.loop.path] != nil)),
          ]))
      })
    if !plan.problems.isEmpty { o["problems"] = .array(plan.problems.map { .string($0) }) }
    return .object(o)
  }
}
