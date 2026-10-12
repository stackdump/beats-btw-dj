import Testing

@testable import DJCore

// Oracle: beats' real macro code (catalog.js, effects.js, runtime.js, feel/axes.js,
// controllers.js, tone-engine.js's master setters) and Tone 15.1.22's own Param timeline, run by
// scripts/beats-macro-fx.mjs into Fixtures/beats/macro-fx.json. Every case is replayed through
// `FxAutomation` (the slider / tempo dispatches) and `MasterParams` (the Tone-level calls and
// the parameter values Tone read back mid-run).

private let fixture: JSONValue? = try? JSONValue.parse(try beatsFixtureText("macro-fx"))

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
  a == b || abs(a - b) <= tol * max(1, abs(a), abs(b))
}

/// What one replay produced.
private struct Replay {
  var fx: [(t: Double, key: String, value: Int)] = []
  var tempo: [(t: Double, bpm: Double)] = []
  var ops: [MasterParamOp] = []
  var probes: [(t: Double, param: String, value: Double)] = []
  var automation: FxAutomation
}

/// Replays a fixture case: the steps at their times (steps of one instant together, before the
/// instant's events), every dispatch into `MasterParams`, the probes read as the run passes them.
private func replay(_ c: JSONValue) -> Replay {
  let bpm = c["bpm"]!.double!
  let a = FxAutomation(tempo: bpm, genreBpm: c["genreBpm"]!.double!)
  if let p = c["puck"]?.array { a.setPuck(p[0].double!, p[1].double!) }
  var r = Replay(automation: a)
  var params = MasterParams(sampleRate: 48_000)
  var pending = (c["probes"]?.array ?? []).map { ($0[0]!.double!, $0[1]!.string!) }
  var next = 0
  func readProbes(before t: Double, inclusive: Bool) {
    while next < pending.count, inclusive ? pending[next].0 <= t : pending[next].0 < t {
      let (pt, name) = pending[next]
      r.probes.append((pt, name, params.value(MasterParamID(rawValue: name)!, at: pt)))
      next += 1
    }
  }
  let emit: (FxAutomationEvent) -> Void = { e in
    switch e {
    case .fx(let t, let key, let value):
      readProbes(before: t, inclusive: false)
      r.fx.append((t, key.id, value))
      params.apply(key, value, at: t) { r.ops.append($0) }
    case .tempo(let t, let b):
      r.tempo.append((t, b))
    }
  }
  pending.sort { $0.0 < $1.0 }
  let steps = c["steps"]!.array!
  var i = 0
  while i < steps.count {
    let t = steps[i][0]!.double!
    a.advance(until: t, emit)
    a.setNow(t)
    while i < steps.count, steps[i][0]!.double! == t {
      let s = steps[i]
      switch s[1]!.string! {
      case "fire":
        let d = s[3].flatMap { $0.double }.map { Int($0) }
        a.fire(MasterMacro(id: s[2]!.string!)!, duration: d, emit)
      case "panic": a.panic(emit)
      case "set": a.setSlider(MasterFxKey(id: s[2]!.string!)!, s[3]!.double!)
      default: Issue.record("unknown step \(s)")
      }
      i += 1
    }
  }
  a.advance(until: .infinity, emit)
  readProbes(before: .infinity, inclusive: true)
  return r
}

struct MasterFxParityTests {
  @Test func fixtureIsThere() throws {
    let f = try #require(fixture)
    #expect((f["cases"]?.array?.count ?? 0) > 600)
    #expect(f["meta"]?["tone"]?["version"]?.string == "15.1.22")
  }

  /// The Swift catalog is beats' catalog, minus the slider moves that never reach wave audio.
  @Test func catalogMatchesBeats() throws {
    let f = try #require(fixture)
    let dropped: Set<String> = ["reverb-wet", "reverb-size", "reverb-damp"]
    let entries = try #require(f["meta"]?["catalog"]?.array)
    #expect(entries.count == MasterMacro.allCases.count)
    for e in entries {
      let id = e["id"]!.string!
      let m = try #require(MasterMacro(id: id), "\(id) is ported")
      #expect(m.label == e["label"]!.string!)
      #expect(m.group == e["group"]!.string!)
      #expect(e["durationUnit"]?.string == "bar")
      #expect(m.defaultDuration == Int(e["defaultDuration"]!.double!))
      #expect(m.durationOptions == e["durationOpts"]!.array!.map { Int($0.double!) })
      let ops = (e["ops"]?.array ?? []).filter { !dropped.contains($0["fxKey"]!.string!) }
        .map {
          MasterMacro.Op(key: MasterFxKey(id: $0["fxKey"]!.string!)!, to: $0["toValue"]!.double!)
        }
      let tail = e["tailFrac"]?.double ?? 0.6
      switch (e["kind"]!.string!, m.kind) {
      case ("fx-sweep", .sweep(let o)): #expect(o == ops, "\(id)")
      case ("fx-hold", .hold(let o, let t)):
        #expect(o == ops, "\(id)")
        #expect(t == tail, "\(id)")
      case ("compound", .compound):
        let steps = e["steps"]!.array!.map { ($0["macroId"]!.string!, $0["offsetMs"]!.double!) }
        #expect(steps.map(\.0) == ["tape-stop", "octave-down"])
        #expect(steps.map(\.1) == [0, 60])
      case ("feel-snap", .feelSnap(let x, let y)), ("feel-sweep", .feelSweep(let x, let y)):
        #expect([x, y] == e["target"]!.array!.map { $0.double! }, "\(id)")
      case ("genre-reset", .genreReset): break
      default: Issue.record("\(id): kind \(e["kind"]!) vs \(m.kind)")
      }
    }
  }

  /// Every case: the same slider dispatches at the same times (1e-9), the same tempo writes,
  /// the same end state.
  @Test func dispatchesMatchBeats() throws {
    let f = try #require(fixture)
    var failures = 0
    for c in f["cases"]!.array! {
      let name = c["name"]!.string!
      let r = replay(c)
      var want: [(t: Double, key: String, value: Int)] = []
      var wantTempo: [(t: Double, bpm: Double)] = []
      for e in c["log"]!.array! {
        if e[1]!.string! == "fx" {
          want.append((e[0]!.double!, e[2]!.string!, Int(e[3]!.double!)))
        } else {
          wantTempo.append((e[0]!.double!, e[2]!.double!))
        }
      }
      // within one instant the order of different sliders is not observable: compare sorted
      let order:
        ((t: Double, key: String, value: Int), (t: Double, key: String, value: Int)) -> Bool = {
          $0.t != $1.t ? $0.t < $1.t : $0.key < $1.key
        }
      let got = r.fx.sorted(by: order)
      want.sort(by: order)
      var ok = got.count == want.count
      if ok {
        for (g, w) in zip(got, want) where !(near(g.t, w.t) && g.key == w.key && g.value == w.value)
        {
          ok = false
          break
        }
      }
      ok =
        ok && r.tempo.count == wantTempo.count
        && zip(r.tempo, wantTempo).allSatisfy { near($0.t, $1.t) && $0.bpm == $1.bpm }
      let sliders = c["sliders"]!
      for k in MasterFxKey.allCases where r.automation.slider(k) != Int(sliders[k.id]!.double!) {
        ok = false
      }
      if r.automation.tempo != c["tempo"]!.double! { ok = false }
      if r.automation.isBusy { ok = false }
      if !ok {
        failures += 1
        if failures <= 5 {
          Issue.record(
            """
            \(name):
              got  \(got.prefix(40).map { "\($0.t) \($0.key)=\($0.value)" })
              want \(want.prefix(40).map { "\($0.t) \($0.key)=\($0.value)" })
              tempo got \(r.tempo.prefix(20)) want \(wantTempo.prefix(20))
            """)
        }
      }
    }
    #expect(failures == 0, "\(failures) cases differ")
  }

  /// The cases that carry them: the same Tone-level calls, and Tone's values read back mid-run.
  @Test func toneCallsAndValuesMatchBeats() throws {
    let f = try #require(fixture)
    var failures = 0
    var probes = 0
    var worst = 0.0
    for c in f["cases"]!.array! where c["ops"] != nil {
      let name = c["name"]!.string!
      let r = replay(c)
      // calls on different parameters at one instant are independent: compare per parameter,
      // in order (a stable sort by time then parameter)
      let want = c["ops"]!.array!.enumerated().sorted {
        let (a, b) = ($0.element, $1.element)
        if a[0]!.double! != b[0]!.double! { return a[0]!.double! < b[0]!.double! }
        if a[1]!.string! != b[1]!.string! { return a[1]!.string! < b[1]!.string! }
        return $0.offset < $1.offset
      }.map(\.element)
      let gotOps = r.ops.enumerated().sorted {
        let (a, b) = ($0.element, $1.element)
        if a.time != b.time { return a.time < b.time }
        if a.param != b.param { return a.param.rawValue < b.param.rawValue }
        return $0.offset < $1.offset
      }.map(\.element)
      var ok = gotOps.count == want.count
      if ok {
        for (g, w) in zip(gotOps, want) {
          let kind = w[2]!.string!
          let same =
            near(g.time, w[0]!.double!) && g.param.rawValue == w[1]!.string!
            && g.kind.rawValue == kind && near(g.a, w[3]!.double!)
            && (kind != "ramp" || near(g.b, w[4]!.double!))
          if !same {
            ok = false
            break
          }
        }
      }
      let wantProbes = c["probes"]!.array!.sorted { $0[0]!.double! < $1[0]!.double! }
      if r.probes.count != wantProbes.count { ok = false }
      // same times: compare as multisets per time (names sorted)
      let gotSorted = r.probes.sorted { $0.t != $1.t ? $0.t < $1.t : $0.param < $1.param }
      let wantSorted = wantProbes.map { ($0[0]!.double!, $0[1]!.string!, $0[2]!.double!) }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
      for (g, w) in zip(gotSorted, wantSorted) {
        probes += 1
        let err = abs(g.value - w.2) / max(1, abs(w.2))
        worst = max(worst, err)
        if !(g.t == w.0 && g.param == w.1 && near(g.value, w.2)) { ok = false }
      }
      if !ok {
        failures += 1
        if failures <= 5 {
          let firstBad = zip(gotSorted, wantSorted).first {
            !($0.t == $1.0 && $0.param == $1.1 && near($0.value, $1.2))
          }
          Issue.record(
            """
            \(name): ops \(r.ops.count) vs \(want.count); first bad probe \(String(describing: firstBad))
              got ops  \(r.ops.prefix(8).map { "\($0.time) \($0.param.rawValue) \($0.kind) \($0.a) \($0.b)" })
              want ops \(want.prefix(8))
            """)
        }
      }
    }
    #expect(
      failures == 0, "\(failures) cases differ (\(probes) probes, worst relative error \(worst))")
    #expect(probes > 20_000)
  }
}
