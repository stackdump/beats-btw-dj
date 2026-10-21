import DJCore
import Foundation

/// One deck's layers as the runner holds them: the track's `loopLayers`, each loop resolved to a
/// library sound and (once prepared) a clip on the loop row.
struct LayerPlan {
  struct Resolved {
    var loop: StockLoop
    var spec: LoopLayerSpec
    var windows: [(start: Int, end: Int)]
    var clipID: String?
  }
  /// The `loopLayers` array this was built from (a changed track builds a new plan).
  var source: JSONValue
  var layers: [Resolved] = []
  var ready = false
  /// Windows already launched / stopped this pass, as "layer@start".
  var launched: Set<String> = []
  var stopped: Set<String> = []
  /// Layers looping now (by index).
  var active: Set<Int> = []
  var lastBar = 0
  var problems: [String] = []
}

extension AppModel {
  // MARK: attaching (compose / import)

  /// Resolve the loops a request's `layers` name against the library, and put them in the envelope as
  /// `loopLayers` with each loop's path and name: what is saved and loaded is unambiguous. An unknown
  /// or ambiguous loop is an error naming the candidates.
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
      case .failure(let e): throw ControlRequestError.bad(e.description)
      }
      resolved.append(s)
    }
    var o = envelope.object ?? JSONObject()
    o[LoopLayers.envelopeKey] = LoopLayers.json(resolved)
    return .object(o)
  }

  // MARK: the runner

  /// The layers' clock (`AppModel.poll`, ≤ 4×/s): for each deck playing a raw track with
  /// `loopLayers`, bring each loop in a bar early and take it out a bar early, so the loop bank's
  /// launch quantizing puts both on the bar lines. `bars` overrides a deck's clock (1-based; tests).
  func serviceLayers(bars override: [String: Int]? = nil) {
    guard let dj = engine else { return }
    if override == nil {
      let now = uptime()
      guard now - layersCheckedAt >= 0.25 else { return }
      layersCheckedAt = now
    }
    for name in dj.decks.keys.sorted() {
      guard let d = dj[name] else { continue }
      let src = d.mode == .net ? d.currentRawNets?[LoopLayers.envelopeKey] : nil
      guard let source = src, let arr = source.array, !arr.isEmpty else {
        if layerPlans[name] != nil { releaseLayers(name) }
        continue
      }
      guard var plan = layerPlans[name], plan.source == source else {
        releaseLayers(name)
        buildLayerPlan(name, source)
        continue
      }
      guard plan.ready else { continue }
      guard d.playing, let bar = override?[name] ?? d.beatState.map({ $0.bar + 1 }) else {
        if !plan.active.isEmpty { releaseLayers(name) }
        continue
      }
      if bar + 1 < plan.lastBar {  // the track went round again (or was seeked back)
        plan.launched = []
        plan.stopped = []
      }
      plan.lastBar = bar
      for (i, layer) in plan.layers.enumerated() {
        guard let id = layer.clipID else { continue }
        for w in layer.windows {
          let key = "\(i)@\(w.start)"
          let comeIn = max(1, w.start - 1)
          let goOut = w.end - 1
          if bar >= comeIn, bar < goOut, !plan.launched.contains(key) {
            dj.perform(.clipLoop(id: id, on: true))
            plan.launched.insert(key)
            plan.active.insert(i)
          }
          if bar >= goOut, plan.launched.contains(key), !plan.stopped.contains(key) {
            plan.stopped.insert(key)
            let stillOn = layer.windows.contains { o in
              let k = "\(i)@\(o.start)"
              return k != key && plan.launched.contains(k) && !plan.stopped.contains(k)
            }
            if !stillOn {
              dj.perform(.clipLoop(id: id, on: false))
              plan.active.remove(i)
            }
          }
        }
      }
      layerPlans[name] = plan
    }
  }

  /// Resolve the loops (the library must be loaded: the first call starts that and tries again) and
  /// put each on the row, with its gain and key lock, off the main thread's critical path.
  func buildLayerPlan(_ deck: String, _ source: JSONValue) {
    if stockLoops.isEmpty {
      Task { await loadStockLoops() }
      return
    }
    var plan = LayerPlan(source: source)
    do {
      for spec in try LoopLayers.parse(source) {
        guard case .success(let loop) = LoopLayers.resolve(spec.loop, in: stockLoops) else {
          plan.problems.append("\(spec.loop): not in the library")
          continue
        }
        plan.layers.append(
          .init(
            loop: loop, spec: spec, windows: LoopLayers.windows(spec, loopBeats: loop.beats),
            clipID: nil))
      }
    } catch { plan.problems.append("\(error)") }
    layerPlans[deck] = plan
    Task { @MainActor in
      for i in plan.layers.indices {
        guard let id = await self.addStockLoopToRow(plan.layers[i].loop) else {
          self.layerPlans[deck]?.problems.append(
            "\(plan.layers[i].loop.name): could not go on the row")
          continue
        }
        guard self.layerPlans[deck]?.source == source else { return }  // the track changed meanwhile
        self.layerPlans[deck]?.layers[i].clipID = id
        let s = plan.layers[i].spec
        self.engine?.perform(.clipGain(id: id, value: LoopLayers.gain(db: s.gainDB)))
        if s.keyLock { self.engine?.perform(.clipKeyLock(id: id, on: true)) }
      }
      if self.layerPlans[deck]?.source == source { self.layerPlans[deck]?.ready = true }
    }
  }

  /// Take the deck's layers out (the track ended, changed or stopped): the loops it left looping stop
  /// on the next launch line, and the plan is forgotten.
  func releaseLayers(_ deck: String) {
    guard let plan = layerPlans[deck] else { return }
    for i in plan.active {
      if let id = plan.layers[i].clipID { engine?.perform(.clipLoop(id: id, on: false)) }
    }
    layerPlans[deck] = nil
  }

  /// What `dj_state` shows for a deck's layers.
  func layersJSON(_ deck: String) -> JSONValue? {
    guard let plan = layerPlans[deck] else { return nil }
    var o = JSONObject([("ready", .bool(plan.ready))])
    o["layers"] = .array(
      plan.layers.enumerated().map { i, l in
        .object(
          JSONObject([
            ("loop", .string(l.loop.name)),
            (
              "bars", .string(l.windows.map { "\($0.start)–\($0.end - 1)" }.joined(separator: ", "))
            ),
            ("gain", .number(l.spec.gainDB)), ("looping", .bool(plan.active.contains(i))),
            ("onRow", .bool(l.clipID != nil)),
          ]))
      })
    if !plan.problems.isEmpty { o["problems"] = .array(plan.problems.map { .string($0) }) }
    return .object(o)
  }
}
