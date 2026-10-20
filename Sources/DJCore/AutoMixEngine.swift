import Foundation

// Auto-mix on the engine (AutoMix.swift has the rule and the state; docs/AUTOMIX.md the design).
// `serviceAutoMix` runs on the main thread right after `serviceWander`, at the same housekeeping
// ticks live (`ControllerHub.tick`) and in a replay (`OfflineConductor.step`), so every derived
// step is a pure function of the engine's state at a tick. It only uses commands that already
// exist: a prepared project (`wave.load`), play, tempo, align, and the strips' volume (the
// crossfader). Nothing new runs on the audio thread.

/// What a poke does to auto-mix (`DJEngine.noteAutoMixTouch`).
enum AutoMixTouch: Sendable {
  /// Playing the mix (knobs, mutes, macros, FX, keys): never pauses it.
  case expression
  /// Steering a deck (cue, loops, sync, sections, sound changes, the jog): pauses it.
  case steer
  /// The transport (play / stop): pauses it; during a hand-off, ends it.
  case transport
  /// What a deck holds changed (a load, Generate, next track): on the idle deck between
  /// hand-offs it is a cue (the next incoming, as-is); otherwise as `transport`.
  case load
}

extension DeckAction {
  /// What this poke is to auto-mix (§5 of docs/AUTOMIX.md): the deck it touches and whether it
  /// steers (pauses) or only plays the mix. nil for actions about neither deck (the loop row,
  /// the mixer, auto-mix's own) and for the engine's own records (`.grid`, `.autoMixDefer`).
  var autoMixTouch: (deck: String, kind: AutoMixTouch)? {
    switch self {
    case .play(let d, _): (d, .transport)
    case .load(let d, _), .clip(let d, _), .nextTrack(let d): (d, .load)
    case .cue(let d), .hotCue(let d, _), .loop(let d, _), .section(let d, _), .sync(let d, _),
      .follow(let d, _), .rewind(let d), .setKit(let d, _), .setPalette(let d, _),
      .setRoleVoice(let d, _, _), .mixOut(let d, _), .mixIn(let d, _):
      (d, .steer)
    default: nil
    }
  }
}

extension DJEngine {
  // MARK: the pokes

  /// Auto-mix on or off with its settings, the whole value at once (`DeckAction.autoMix`).
  /// Off during a hand-off stops driving it where it is (the crossfader stays put; a mix-out or
  /// mix-in already applied plays out as by hand). Settings changed while on apply from the
  /// next hand-off (one in flight keeps its length).
  public func setAutoMix(on: Bool, bars: Int, every: Int) {
    let was = autoMix.settings
    autoMix.settings = AutoMixSettings(on: on, bars: bars, every: every)
    if !on {
      if autoMix.run != nil { endRun(log: false) }
      autoMix.kept = nil
      autoMix.cued = nil
      autoMix.paused = false
      autoMix.quietBars = 0
      autoMix.playing = nil
      autoMix.lastBar = nil
      autoMix.startBar = nil
      autoMix.handoffBar = nil
      autoMix.nowRequested = false
      autoMix.idle = nil
      autoMix.phase = .off
      return
    }
    if !was.on {
      autoMix.playing = nil
      autoMix.lastBar = nil
      autoMix.startBar = nil
      autoMix.cued = nil
      autoMix.kept = nil
    }
    autoMix.handoffBar = nil  // worked out again with the new settings
  }

  /// Hand off at the next phrase boundary at least `AutoMix.nowPrepBars` away
  /// (`DeckAction.autoMixNow`). Ignored while a hand-off runs or auto-mix is off; resumes a
  /// paused countdown.
  public func autoMixNow() {
    guard autoMix.settings.on, autoMix.run == nil else { return }
    autoMix.nowRequested = true
    autoMix.paused = false
    autoMix.quietBars = 0
    autoMix.handoffBar = nil
  }

  /// Hand-off `handoff`'s incoming track was not composed by its mix-out point: it moves one
  /// phrase later, its plan kept (`DeckAction.autoMixDefer`, recorded by the engine live; a
  /// replay applies it at the same frame).
  func deferAutoMix(handoff n: Int) {
    guard var run = autoMix.run, run.plan.n == n, !run.mixOutLoaded else { return }
    run.handoffBar += AutoMix.phraseBars
    autoMix.run = run
    autoMixAhead.drop()
    guard !deterministic else { return }
    if run.outIsNet, let out = decks[run.out] { requestMixOutAhead(out, run) }
    // a compose that never landed (superseded, or lost) is asked for again
    if !run.incomingReady, let inc = decks[run.inc] { loadIncoming(inc, run) }
  }

  /// A poke reached `deck` (nil: deck-less). Called from `applyAction` (UI, socket, MCP and a
  /// replay's actions) and the controllers' handlers (recorded MIDI, replayed through the
  /// router), never by auto-mix's own moves.
  func noteAutoMixTouch(_ deck: String?, _ kind: AutoMixTouch) {
    guard autoMix.settings.on, kind != .expression else { return }
    // only decks A and B; with nothing playing yet there is nothing to pause (the first play
    // starts the set)
    if let deck, deck != "A" && deck != "B" { return }
    if let run = autoMix.run {
      if !run.mixOutLoaded {
        // before the point of no return (the mix-out, a bar before the hand-off): a load on
        // the incoming deck replaces what was prepared (a cue), anything else cancels the start
        // and keeps the plan for later
        let cue = kind == .load && deck == run.inc
        cancelRun(keepPlan: !cue)
        if cue { autoMix.cued = run.inc }
        pauseAutoMix()
      } else if kind == .transport || kind == .load {
        // from the mix-out on: the transport or a load on either deck ends it, nothing undone
        endRun(log: false)
        pauseAutoMix()
      }
      return
    }
    if kind == .load, let deck, deck != autoMix.playing, decks[deck] != nil {
      autoMix.cued = deck
      return
    }
    guard autoMix.playing != nil else { return }
    pauseAutoMix()
  }

  private func pauseAutoMix() {
    autoMix.paused = true
    autoMix.quietBars = 0
    autoMix.handoffBar = nil
    autoMix.nowRequested = false
  }

  // MARK: the walk

  /// Auto-mix's housekeeping (~100×/s, after `serviceWander`).
  public func serviceAutoMix() {
    guard autoMix.settings.on else {
      autoMix.phase = .off
      return
    }
    if autoMix.run != nil {
      serviceRun()
    } else {
      serviceCountdown()
    }
    updateAutoMixPhase()
  }

  private func updateAutoMixPhase() {
    if !autoMix.settings.on {
      autoMix.phase = .off
    } else if let run = autoMix.run {
      let started = (decks[run.inc]?.wave.tick ?? 0) > 0 && run.armed
      autoMix.phase = !run.armed ? .preparing : (started ? .mixing : .armed)
    } else if autoMix.idle != nil {
      autoMix.phase = .idle
    } else {
      autoMix.phase = autoMix.paused ? .paused : .playing
    }
  }

  /// The bar a deck is in on the clock auto-mix counts by: a net's song clock (`wave.tick / 16`,
  /// as Wander's), a sample deck's beat grid; nil for a sample with no grid.
  func autoMixBar(_ d: Deck) -> Int? {
    switch d.mode {
    case .net: return d.netProject == nil ? nil : d.wave.tick / 16
    case .sample: return d.beatGrid == nil ? nil : d.beatState?.bar
    }
  }

  private func setAutoMixIdle(_ why: String) {
    autoMix.idle = why
    autoMix.handoffBar = nil
  }

  /// Between hand-offs: which deck plays, the pause, the countdown, the prep point.
  private func serviceCountdown() {
    guard let a = decks["A"], let b = decks["B"] else {
      return setAutoMixIdle("auto-mix needs decks A and B")
    }
    let on = [a, b].filter(\.playing)
    if on.isEmpty {
      autoMix.playing = nil
      autoMix.lastBar = nil
      autoMix.startBar = nil
      return setAutoMixIdle("start a deck")
    }
    let out: Deck
    if on.count == 2 {
      // the louder by crossfader and fader is "playing": wait for the other to stop
      let ga = crossfadeGain("A") * a.volume
      let gb = crossfadeGain("B") * b.volume
      out = ga == gb ? (decks[autoMix.playing ?? "A"] ?? a) : (ga > gb ? a : b)
      if autoMix.playing != out.name { autoMix.playing = out.name }
      return setAutoMixIdle("\((out === a ? b : a).name) is playing too")
    }
    out = on[0]
    let inc = out === a ? b : a
    if autoMix.playing != out.name {
      autoMix.playing = out.name
      autoMix.lastBar = nil
      autoMix.startBar = nil
      autoMix.handoffBar = nil
    }
    guard let bar = autoMixBar(out) else {
      return setAutoMixIdle("\(out.name) plays a sample with no beat grid: cue a net by hand")
    }
    let newBar = autoMix.lastBar != nil && bar != autoMix.lastBar
    autoMix.lastBar = bar
    if autoMix.startBar == nil { autoMix.startBar = bar }
    if autoMix.paused {
      if newBar { autoMix.quietBars += 1 }
      guard autoMix.quietBars >= AutoMix.quietBars else {
        autoMix.idle = nil
        autoMix.handoffBar = nil
        return
      }
      autoMix.paused = false
      autoMix.quietBars = 0
      autoMix.startBar = bar
    }
    // what will come in: a deck the user cued, else a draw from the playing deck
    let cued = autoMix.cued == inc.name && inc.mode == .net && inc.netProject != nil
    if autoMix.cued == inc.name && !cued { autoMix.cued = nil }
    if !cued {
      if inc.mode == .sample && inc.loaded != nil && !inc.isDemo {
        return setAutoMixIdle(
          "\(inc.name) holds a sample: cue a net there or turn auto-mix off")
      }
      guard out.mode == .net, out.currentSpec != nil, let c = autoMixContext(out: out, inc: inc)
      else {
        return setAutoMixIdle(
          out.mode == .sample
            ? "\(out.name) plays a sample: cue the next deck by hand"
            : "\(out.name) plays a shared net: cue the next deck by hand")
      }
      guard AutoMix.canDraw(c) else {
        return setAutoMixIdle("every move is locked: cue the next deck by hand")
      }
    }
    autoMix.idle = nil
    let prep = autoMix.nowRequested ? AutoMix.nowPrepBars : AutoMix.prepBars
    // worked out once per countdown (a pause, Mix now, new settings or another deck clear it);
    // a bar already passed (a stall) is worked out again
    var h = autoMix.handoffBar ?? -1
    if h < bar {
      h = autoMixHandoffBar(out, bar: bar, prep: prep, cuedSample: out.mode == .sample)
      autoMix.handoffBar = h
    }
    if bar >= h - prep { beginRun(out: out, inc: inc, handoffBar: h, prep: prep, cued: cued) }
  }

  /// The next hand-off bar on `out`'s clock, at least `prep` + 1 bars after `bar`: a song's
  /// outro (`every` 0; without one, the last phrase boundary that leaves the hand-off's bars
  /// before the end), else the first phrase boundary `every` phrases after the deck came in
  /// (a loop: `AutoMix.loopPhrases`). Mix now, and a cue under a sample deck: the first phrase
  /// boundary from there.
  func autoMixHandoffBar(_ out: Deck, bar: Int, prep: Int, cuedSample: Bool = false) -> Int {
    let earliest = bar + prep + 1
    if autoMix.nowRequested || cuedSample { return autoMixPhrase(out, from: earliest) }
    let secs = out.sections
    if autoMix.settings.every == 0, !secs.isEmpty {
      if let outro = secs.last(where: { $0.name == "outro" }), outro.startTick / 16 >= earliest {
        return outro.startTick / 16
      }
      let end = (secs.last.map { $0.startTick + $0.steps } ?? 0) / 16
      let latest = end - autoMix.settings.bars
      if latest >= earliest {
        var b = latest
        while b >= earliest && !isAutoMixPhrase(out, b) { b -= 1 }
        if b >= earliest { return b }
      }
      return autoMixPhrase(out, from: earliest)
    }
    let every = autoMix.settings.every == 0 ? AutoMix.loopPhrases : autoMix.settings.every
    return autoMixPhrase(
      out, from: max(earliest, (autoMix.startBar ?? bar) + every * AutoMix.phraseBars))
  }

  /// A phrase boundary: a multiple of 8 bars, or a section's first bar.
  func isAutoMixPhrase(_ d: Deck, _ bar: Int) -> Bool {
    bar % AutoMix.phraseBars == 0 || d.sections.contains { $0.startTick == bar * 16 }
  }

  private func autoMixPhrase(_ d: Deck, from bar: Int) -> Int {
    var b = max(0, bar)
    while !isAutoMixPhrase(d, b) { b += 1 }
    return b
  }

  /// What the draw reads (§3.1): the outgoing deck's configuration — where it is heading if a
  /// swap is still composing — with both decks' locks and the mix's tempo.
  func autoMixContext(out: Deck, inc: Deck) -> WanderContext? {
    guard var c = out.wanderContext(lockedActions: lockedActions) else { return nil }
    if let s = out.seedTarget { c.spec = s }
    c.locks = out.wander.locks.union(inc.wander.locks)
    c.anchorBPM = out.wander.anchorBPM ?? inc.wander.anchorBPM
    if c.locked("tempo"), c.anchorBPM == nil { c.anchorBPM = Wander.bpm(of: c.spec) }
    c.key = out.wander.key ?? inc.wander.key
    if c.locked("key"), c.key == nil { c.key = out.wanderKey }
    c.mixBPM = out.effectiveBPM
    return c
  }

  // MARK: a hand-off

  /// The prep point: take the cue or draw, copy the disabled roles, hold both walks, compose
  /// the incoming track with its mix-in baked in, and (live) prepare the mix-out.
  private func beginRun(out: Deck, inc: Deck, handoffBar h: Int, prep: Int, cued: Bool) {
    var plan: AutoMixPlan
    var reuse = false
    let bars = autoMix.settings.bars
    if cued {
      plan = AutoMixPlan(
        n: autoMix.handoffs, spec: inc.currentSpec, kind: "cued", detail: "cued: \(inc.title)",
        from: nil)
    } else {
      guard let c = autoMixContext(out: out, inc: inc) else { return }
      let from = BeatsCID.shareCID(c.spec.payload)
      if let k = autoMix.kept, k.from == from, k.spec != nil, inc.currentSpec == k.spec,
        inc.mixInEndTick == bars * 16, inc.wave.tick == 0, !inc.playing
      {
        plan = k
        reuse = true
      } else {
        guard let p = AutoMix.plan(c, n: autoMix.handoffs, key: out.wanderKey) else {
          return setAutoMixIdle("every move is locked: cue the next deck by hand")
        }
        plan = p
      }
    }
    if !reuse { autoMix.handoffs += 1 }
    autoMix.kept = nil
    autoMix.cued = nil
    autoMix.nowRequested = false
    // one walk: the incoming deck leaves out what the outgoing deck leaves out
    for r in inc.disabledRoles.subtracting(out.disabledRoles).sorted() {
      inc.setRoleDisabled(r, false)
    }
    for r in out.disabledRoles.subtracting(inc.disabledRoles).sorted() {
      inc.setRoleDisabled(r, true)
    }
    out.wanderHeld = true
    inc.wanderHeld = true
    out.lookAhead.drop()
    inc.lookAhead.drop()
    var run = AutoMixRun(
      plan: plan, out: out.name, inc: inc.name, handoffBar: h, prep: prep, bars: bars,
      outIsNet: out.mode == .net, xEnd: out.name == "A" ? 1 : 0)
    run.incomingReady = reuse
    autoMix.run = run
    if !reuse { loadIncoming(inc, run) }
    if !deterministic, run.outIsNet { requestMixOutAhead(out, run) }
  }

  /// Put the incoming track on the idle deck, stopped, at tick 0, its melodic lanes resting for
  /// the hand-off's bars: one prepare (`WaveOptions.extraRest`). Inline in `deterministic`
  /// replay, else off the main thread.
  private func loadIncoming(_ inc: Deck, _ run: AutoMixRun) {
    let rest = RestSchedule.mixIn(fromTick: 0, bars: autoMixCrossfadeOnly ? 0 : run.bars)
    inc.generation += 1
    let mine = inc.generation
    let n = run.plan.n
    let ref = AutoMixEngineRef(engine: self, deck: inc)
    if !run.plan.cued, let spec = run.plan.spec {
      var opts = inc.waveOptions
      opts.extraRest = rest
      let sr = inc.wave.sampleRate
      if deterministic {
        inc.loadNet(PreparedTrack(spec: spec, sampleRate: sr, opts: opts))
        return incomingLoaded(inc, n: n, mine: mine, rest: rest)
      }
      let o = OptionsBox(opts: opts)
      let stalls = autoMixComposeStalls
      autoMixComposeStalls = false  // one compose only
      Task.detached(priority: .userInitiated) {
        let track = PreparedTrack(spec: spec, sampleRate: sr, opts: o.opts)
        await MainActor.run {
          guard !stalls, let dj = ref.engine, let d = ref.deck, dj.incomingWanted(d, n: n, mine: mine)
          else { return }
          d.loadNet(track)
          dj.incomingLoaded(d, n: n, mine: mine, rest: rest)
        }
      }
      return
    }
    // a cue: the track it holds, from its top, rebuilt with the mix-in
    guard let move = inc.moveRequest(toTick: 0, tail: nil, rest: rest) else { return }
    if deterministic {
      inc.wave.load(move.prepare())
      inc.applyNetTempo()
      return incomingLoaded(inc, n: n, mine: mine, rest: rest)
    }
    Task.detached(priority: .userInitiated) {
      let p = move.prepare()
      await MainActor.run {
        guard let dj = ref.engine, let d = ref.deck, dj.incomingWanted(d, n: n, mine: mine) else {
          return
        }
        d.wave.load(p)
        d.applyNetTempo()
        dj.incomingLoaded(d, n: n, mine: mine, rest: rest)
      }
    }
  }

  /// Is hand-off `n` still waiting for this compose on `inc`?
  func incomingWanted(_ inc: Deck, n: Int, mine: Int) -> Bool {
    autoMix.run?.plan.n == n && mine == inc.generation && !inc.playing
  }

  func incomingLoaded(_ inc: Deck, n: Int, mine: Int, rest: RestSchedule.Entry) {
    guard var r = autoMix.run, incomingWanted(inc, n: n, mine: mine) else { return }
    inc.mixInEndTick = rest.to
    r.incomingReady = true
    autoMix.run = r
  }

  /// Live: the mix-out `mixOut(bars:)` would prepare in bar H − 1, prepared now.
  private func requestMixOutAhead(_ out: Deck, _ run: AutoMixRun) {
    let point = out.mixOutPoint(atBar: run.handoffBar, bars: run.bars)
    guard let move = out.moveRequest(toTick: point.tick, tail: point.tail, rest: nil) else {
      return
    }
    autoMixAhead.request(move)
    if var r = autoMix.run {
      r.outGeneration = out.wave.latest?.generation
      autoMix.run = r
    }
  }

  /// A hand-off from its prep point to its end.
  private func serviceRun() {
    guard var run = autoMix.run, let out = decks[run.out], let inc = decks[run.inc] else {
      autoMix.run = nil
      return
    }
    let h = run.handoffBar
    // the mix-out point: bar H − 1 of the outgoing deck (the point of no return)
    if !run.mixOutLoaded, let bar = autoMixBar(out), bar >= h - 1 {
      guard run.incomingReady else {
        // live only: the compose is late; the hand-off moves a phrase on, and that is recorded
        let a = DeckAction.autoMixDefer(handoff: run.plan.n)
        recorder?.record(a)
        journal?.record(.action(a))
        deferAutoMix(handoff: run.plan.n)
        return
      }
      if run.outIsNet && !autoMixCrossfadeOnly {
        run.mixOutTick = loadMixOut(out, run)
        out.autoMixingOut = true
      }
      run.mixOutLoaded = true
      autoMix.run = run
    }
    guard run.mixOutLoaded else { return }
    // the start, half a beat to a beat and a half before the hand-off bar
    if !run.armed {
      if let pending = autoMixPendingArm {
        pending.countdown -= 1
        if pending.countdown <= 0 {
          autoMixPendingArm = nil
          startIncoming(inc, out: out, &run, aligning: pending.ticks)
        }
        autoMix.run = run
        return
      }
      guard let ticks = armFrames(out: out, inc: inc, run) else { return }
      if autoMixArmDelay > 0 {
        autoMixPendingArm = PendingArm(ticks: ticks, countdown: autoMixArmDelay)
        return
      }
      startIncoming(inc, out: out, &run, aligning: ticks)
      autoMix.run = run
      return
    }
    // the incoming deck's clock: tick 0 lands on the hand-off bar
    guard inc.wave.tick > 0 || !inc.playing else { return }
    let k = inc.wave.tick > 0 ? min(run.bars, (inc.wave.tick - 1) / 16) : 0
    if !run.corrected { correctStart(out: out, inc: inc, &run) }
    if run.c0 == nil {
      run.c0 = crossfader
      run.lastFader = crossfader
    }
    // the crossfader, one step per bar (equal power: the engine's law)
    if !run.faderTaken, let c0 = run.c0 {
      if let last = run.lastFader, abs(crossfader - last) > 1e-9 {
        run.faderTaken = true
      } else {
        let x = c0 + (run.xEnd - c0) * Double(k) / Double(max(1, run.bars))
        if crossfader != x {
          crossfader = x
          owners["crossfader"] = "automix"
        }
        run.lastFader = x
      }
    }
    autoMix.run = run
    if k >= run.bars || !inc.playing { finishRun(out: out, inc: inc, run) }
  }

  /// Hand the mix-out to the outgoing deck in bar H − 1 (it takes over on H): the one prepared
  /// ahead if nothing was loaded on the deck since, else `mixOut` itself (inline in a replay; a
  /// late relocation live). Returns where the mix-out project starts.
  private func loadMixOut(_ out: Deck, _ run: AutoMixRun) -> Int {
    let point = out.mixOutPoint(atBar: run.handoffBar, bars: run.bars)
    if !deterministic, let p = autoMixAhead.take(), out.wave.latest?.generation == run.outGeneration,
      p.startTick == point.tick, p.tail == point.tail
    {
      out.wave.load(p)
      out.applyNetTempo()
    } else {
      autoMixAhead.drop()
      out.mixOut(bars: run.bars)
    }
    return point.tick
  }

  /// When the start is due (from beat 3.5 of bar H − 1): the align that puts the incoming
  /// deck's first tick on the outgoing deck's hand-off bar line, worked out from both decks'
  /// clocks at the end of the same block (`renderedFrames`); nil while not due (or the reading
  /// straddles a block).
  private func armFrames(out: Deck, inc: Deck, _ run: AutoMixRun) -> Double? {
    guard inc.netProject != nil, let inBPM = inc.effectiveBPM else { return nil }
    let e = out.renderedFrames
    guard inc.renderedFrames == e else { return nil }
    let sr = sampleRate
    let h = run.handoffBar
    let frames: Double
    if run.outIsNet {
      let t = out.wave.tick
      let late = t >= h * 16
      guard late || t >= h * 16 - 2 else { return nil }
      if late { return 0 }  // missed: start now, the correction puts it in place
      let tempo = out.wave.tempo
      guard tempo > 0 else { return nil }
      let spt = sr * 60 / (tempo * 4)
      let p = out.wave.tickPhase * spt
      // doTicks to the one that plays step 16H: a swap still pending takes a tick of its own
      let pending = out.wave.activeGeneration != out.wave.latest?.generation
      var j = h * 16 - t
      if pending, let c = run.mixOutTick { j = (h * 16 - 1 - t) + 1 + (h * 16 - c) }
      frames = ((Double(j + 1) * spt - p - 1).rounded(.up))
    } else {
      guard let s = out.beatState, s.bpm > 0 else { return nil }
      let beatsLeft = Double(h * 4) - s.beat
      guard beatsLeft <= 1.5 else { return nil }
      if beatsLeft <= 0 { return 0 }
      frames = (beatsLeft * sr * 60 / s.bpm).rounded()
    }
    guard renderedFrames(out, inc) == e, frames >= 1 else { return nil }
    _ = inBPM
    return frames
  }

  private func renderedFrames(_ a: Deck, _ b: Deck) -> Int? {
    let x = a.renderedFrames
    return b.renderedFrames == x ? x : nil
  }

  /// Start the incoming deck: tempo synced to the outgoing deck (and following it for the
  /// hand-off), playing, its first tick held back `frames` samples from the next block.
  private func startIncoming(_ inc: Deck, out: Deck, _ run: inout AutoMixRun, aligning frames: Double) {
    run.prevLeader = inc.leader?.name
    let r = inc.sync(to: out, align: .tempoOnly)
    run.mult = r?.multiplier ?? 1
    inc.setPlaying(true)
    if frames >= 1, let bpm = inc.effectiveBPM {
      let spt = sampleRate * 60 / (bpm * 4)
      inc.wave.align(ticks: -(frames - 0.5) / spt)
    }
    inc.leader = out
    run.armed = true
  }

  /// In the hand-off's first bar: both decks' clocks, read at the end of one block, say how far
  /// the incoming deck's first tick missed the bar line (a live start can land a block late);
  /// one align takes it out before the crossfader brings it up. Within a sample: left alone.
  private func correctStart(out: Deck, inc: Deck, _ run: inout AutoMixRun) {
    guard run.outIsNet, run.mult == 1 else {
      run.corrected = true
      return
    }
    let h = run.handoffBar * 16
    guard renderedFrames(out, inc) != nil, inc.wave.tick >= 1, out.wave.tick > h,
      out.wave.isPlaying
    else { return }
    let posOut = Double(out.wave.tick - 1) + out.wave.tickPhase - Double(h)
    let posIn = Double(inc.wave.tick - 1) + inc.wave.tickPhase
    guard renderedFrames(out, inc) != nil else { return }
    let tempo = out.wave.tempo
    let spt = tempo > 0 ? sampleRate * 60 / (tempo * 4) : 0
    let err = posIn - posOut
    if abs(err * spt) >= 1 { inc.wave.align(ticks: -err) }
    run.corrected = true
  }

  /// The hand-off's last bar line: the crossfader at its end, the old deck stopped (its tail
  /// normally stopped it on this bar line), the walks released, the decks' roles swapped.
  private func finishRun(out: Deck, inc: Deck, _ run: AutoMixRun) {
    if !run.faderTaken {
      crossfader = run.xEnd
      owners["crossfader"] = "automix"
    }
    if out.playing { out.setPlaying(false) }
    let entry = AutoMixHandoff(
      n: run.plan.n, from: run.out, to: run.inc, bar: run.handoffBar, kind: run.plan.kind,
      move: run.plan.detail, spec: run.plan.spec ?? inc.currentSpec)
    endRun(log: false)
    autoMix.log.append(entry)
    if autoMix.log.count > AutoMixState.logLimit {
      autoMix.log.removeFirst(autoMix.log.count - AutoMixState.logLimit)
    }
    // the incoming deck plays now; it came fully in on its bar `bars`
    autoMix.playing = inc.playing ? inc.name : nil
    autoMix.startBar = run.bars
    autoMix.lastBar = nil
    autoMix.handoffBar = nil
  }

  /// Let go of a hand-off where it is: the walks released, the incoming deck's leader back, the
  /// mix-out guard off (what was done stays done, as by hand).
  private func endRun(log: Bool) {
    guard let run = autoMix.run else { return }
    autoMixAhead.drop()
    autoMixPendingArm = nil
    if let out = decks[run.out] {
      out.wanderHeld = false
      out.autoMixingOut = false
    }
    if let inc = decks[run.inc] {
      inc.wanderHeld = false
      if run.armed { inc.leader = run.prevLeader.flatMap { decks[$0] } }
    }
    autoMix.run = nil
  }

  /// A steering poke before the mix-out point: the start is called off. The incoming deck keeps
  /// what was prepared (stopped); the plan is kept for the next prep point unless `keepPlan` is
  /// false (or the outgoing configuration changes meanwhile).
  private func cancelRun(keepPlan: Bool) {
    guard let run = autoMix.run else { return }
    if let inc = decks[run.inc], run.armed, inc.playing { inc.setPlaying(false) }
    autoMix.kept = keepPlan && !run.plan.cued && run.incomingReady ? run.plan : nil
    endRun(log: false)
  }

  /// Stand auto-mix where `state` says (a session's start, a journal checkpoint, a rewind): a
  /// hand-off in flight is let go first; one in `state` is taken up where it was (its walks held
  /// again; what the decks were loaded with comes from the checkpoint's sources, so a mix-in or
  /// mix-out already applied is not in them: the hand-off still ends on its bar line).
  func restoreAutoMix(_ state: AutoMixState) {
    if autoMix.run != nil { endRun(log: false) }
    var s = state
    s.log = autoMix.log
    s.phase = s.settings.on ? (s.run != nil ? .preparing : .playing) : .off
    autoMix = s
    if let run = s.run {
      decks[run.out]?.wanderHeld = true
      decks[run.inc]?.wanderHeld = true
      if run.mixOutLoaded, run.outIsNet { decks[run.out]?.autoMixingOut = true }
      if run.armed, let inc = decks[run.inc] { inc.leader = decks[run.out] }
    }
  }

  // MARK: dj_state

  /// `dj_state.autoMix`.
  public var autoMixJSON: JSONValue {
    let s = autoMix
    var o = JSONObject([
      ("on", .bool(s.settings.on)), ("bars", .int(s.settings.bars)),
      ("every", .int(s.settings.every)), ("phase", .string(s.phase.rawValue)),
      ("handoffs", .int(s.handoffs)), ("paused", .bool(s.paused)), ("fader", .string(s.fader)),
      ("log", .array(s.log.reversed().prefix(12).map(\.json))),
    ])
    o["playing"] = s.playing.map { .string($0) } ?? .null
    o["incoming"] = s.incoming.map { .string($0) } ?? .null
    o["idle"] = s.idle.map { .string($0) } ?? .null
    if let next = s.next { o["next"] = next.json }
    if let run = s.run {
      o["handoffBar"] = .int(run.handoffBar)
      if let out = decks[run.out], let bar = autoMixBar(out), bar < run.handoffBar {
        o["handoffInBars"] = .int(run.handoffBar - bar)
      }
      if let inc = decks[run.inc], inc.wave.tick > 0 {
        o["mixBar"] = .int(min(run.bars, (inc.wave.tick - 1) / 16 + 1))
      }
    } else if let h = s.handoffBar, let p = s.playing, let d = decks[p], let bar = autoMixBar(d) {
      o["handoffBar"] = .int(h)
      o["handoffInBars"] = .int(max(0, h - bar))
    }
    if s.paused { o["resumesInBars"] = .int(max(1, AutoMix.quietBars - s.quietBars)) }
    return .object(o)
  }

  /// One line for the mixer's foot: "A playing · → B in 23 bars", "mixing A → B · bar 3/8".
  public var autoMixStatus: String {
    let s = autoMix
    guard s.settings.on else { return "auto-mix off" }
    if let why = s.idle { return "waiting: \(why)" }
    if s.paused {
      return "paused · resumes after \(AutoMix.quietBars) quiet bars "
        + "(\(max(1, AutoMix.quietBars - s.quietBars)) to go)"
    }
    if let run = s.run {
      let what = run.plan.spec.map { "\($0.genre) · seed \(Wander.seedText($0.seed))" } ?? "cued"
      switch s.phase {
      case .mixing:
        let bar = (decks[run.inc].map { max(1, ($0.wave.tick - 1) / 16 + 1) }) ?? 1
        return "mixing \(run.out) → \(run.inc) · bar \(min(run.bars, bar))/\(run.bars)"
      case .armed: return "\(run.inc): \(what) · starting"
      default:
        let ready = run.incomingReady ? "ready" : "composing"
        let left =
          (decks[run.out].flatMap(autoMixBar)).map { " · in \(max(0, run.handoffBar - $0)) bars" }
          ?? ""
        return "\(run.inc): \(what) (\(run.plan.kind)) · \(ready)\(left)"
      }
    }
    if let p = s.playing, let h = s.handoffBar, let d = decks[p], let bar = autoMixBar(d) {
      let other = p == "A" ? "B" : "A"
      return "\(p) playing · → \(other) in \(max(0, h - bar)) bars"
    }
    return "auto-mix on"
  }
}

private struct AutoMixEngineRef: @unchecked Sendable {
  weak var engine: DJEngine?
  weak var deck: Deck?
}

private struct OptionsBox: @unchecked Sendable {
  var opts: WaveOptions
}

/// A start worked out but held back (`DJEngine.autoMixArmDelay`, tests).
final class PendingArm {
  var ticks: Double
  var countdown: Int
  init(ticks: Double, countdown: Int) {
    self.ticks = ticks
    self.countdown = countdown
  }
}
