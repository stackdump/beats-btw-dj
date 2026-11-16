import DJRust
import Foundation

// The Wheel tab's half of djandroid's PlayerViewModel ("the wheel"): windwheel's tonewheel,
// compiled into djmobile and played through an input strip of the engine's. Re-winds (an
// instrument, a key, a sequence, brightness, the build knobs: a few hundred ms each) run in order
// on their own queue, so a deck call never waits behind one; a slider's dozens of moves are
// coalesced to the latest. A finger on the drawing goes straight to the engine.

/// The wheel's screen (djandroid WheelUi). `rewinding`: a change is being wound (the wheel plays
/// on and the new winding crossfades in). `moving`: it sounds now (the tab's dot). `started`: it
/// has been played since the engine started (before that it is stopped and the button says
/// Play); `paused`: held where it is, silent, everything kept.
struct WheelUI: Equatable {
  var presets: [WheelPreset] = []
  var layout: WheelLayout?
  var rewinding = false
  var moving = false
  var started = false
  var paused = false
  /// A finger on a cord moves it this many times faster than along the drawing (per instrument).
  var gear = 6.0
  /// The deck the sync × slider follows.
  var follow = "A"
}

extension RustDJModel {
  private nonisolated func seqKey(_ id: String) -> String { "wheel_sequence/\(id)" }
  private nonisolated func knobsKey(_ id: String) -> String { "wheel_knobs/\(id)" }
  private nonisolated func gearKey(_ id: String) -> String { "wheel_gear/\(id)" }

  /// At the engine's start: the instruments, the deck the sync follows, and the instrument as
  /// last left — at rest (a drum or a bow left on doesn't start turning by itself at launch).
  func attachWheel(_ p: Player) {
    wheel = WheelUI(presets: DJRust.wheelPresets(), follow: prefs.string(forKey: "wheel_follow") ?? "A")
    let id = prefs.string(forKey: "wheel_preset") ?? "hoop-looper"
    // a new Player each start (Kotlin's `fresh`: the iPad has no surviving engine to find on)
    WheelLog.i("switch.restore", ["n": 0, "to": id, "fresh": true])
    wheelJob("restore") { p in
      var l: WheelLayout
      do { l = try self.loadWithSequence(p, id) } catch {
        WheelLog.w("switch.restore.fail", ["to": id, "error": "\(error)"])
        throw error
      }
      if l.motor {
        try p.wheelMotor(on: false, speed: l.speedMps)
        l.motor = false
      }
      return l
    }
    Task.detached(priority: .userInitiated) { [weak self] in await self?.pollWheel(p) }
  }

  /// The magnets ~80 times a second while the drawing shows (else not at all), the meters, the
  /// tempo and the tab's dot ~30.
  nonisolated func pollWheel(_ p: Player) async {
    var last: [WheelMagnet]?
    var lastState = 0.0
    var seq = 0
    // the drawing's frame loop rests while every magnet is still, once a jump has eased out
    // (MagnetTracker's correction: 0.1 m × e^(−t / easeS) < 1e-5 m by ~0.6 s)
    var busyUntil = 0.0
    var still = true
    while !Task.isCancelled {
      let watching = wheelFeed.watching
      if watching, let m = try? p.wheelMotion() {
        let stamp = Date.timeIntervalSinceReferenceDate
        if m.magnets != last {
          last = m.magnets
          seq += 1
          let ms = m.magnets
          wheelFeed.publish(
            MagnetTracker.Sample(
              z: ms.map(\.z), v: ms.map(\.v), on: ms.map(\.on), seg: ms.map { Int($0.segment) },
              voiceS: m.voiceS, stamp: stamp, seq: seq))
          busyUntil = stamp + MagnetTracker.easeS * 10
        }
        let moving = m.magnets.contains { $0.on && abs($0.v) > MagnetTracker.stillMps }
        let idle = !moving && stamp >= busyUntil
        if idle != still {
          still = idle
          await MainActor.run { self.wheelStill = idle }
        }
      }
      let now = Date.timeIntervalSinceReferenceDate
      if now - lastState >= 0.033, let s = try? p.wheelState() {
        lastState = now
        await MainActor.run {
          self.wheelState = s
          let moving = !s.paused && (s.outPeak > 0.01 || abs(s.speedMps) > 0.05)
          if moving != self.wheel.moving || s.paused != self.wheel.paused || s.started != self.wheel.started {
            self.wheel.moving = moving
            self.wheel.paused = s.paused
            self.wheel.started = s.started
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(watching ? 12 : 33))
    }
  }

  /// `DJ_AUTOPLAY=wheel[:ID[:A]]`: instrument ID on the wheel (none or empty: the one restored),
  /// played; with ":A", deck A plays once loaded too.
  func wheelAutoplay(_ a: String) {
    let parts = a.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard let l = wheel.layout, !wheel.rewinding else { return }
    let want = parts.count > 1 && !parts[1].isEmpty ? parts[1] : l.id
    if want != l.id {
      guard !wheelAutoLoading else { return }
      wheelAutoLoading = true
      wheelLoad(want)
      return
    }
    autoplay = parts.count > 2 && parts[2] == "A" ? "1" : nil
    wheelPlayPause()
  }

  /// A re-wind on the wheel's queue; its layout replaces the shown one. `what` names it in the
  /// field log when it fails.
  private func wheelJob(_ what: String = "rewind", _ f: @escaping @Sendable (Player) throws -> WheelLayout) {
    guard let p = player else {
      WheelLog.w("wheel.job.skip", ["what": what, "why": "no player"])
      return
    }
    wheel.rewinding = true
    let log = wheelLog
    log.queued(+1)
    wheelQueue.async {
      do {
        let l = try f(p)
        Task { @MainActor in
          self.wheel.layout = l
          self.wheel.rewinding = false
        }
      } catch {
        let msg = "\(error)"
        WheelLog.w("wheel.job.fail", ["what": what, "error": msg, "type": String(describing: type(of: error))])
        Task { @MainActor in
          self.error = msg
          self.wheel.rewinding = false
        }
      }
      log.queued(-1)
    }
  }

  /// Switch the wheel to instrument `id` (its sequence and build knobs as last left on it):
  /// logged step by step (WheelLog, `switch.*` with one number `n` per switch): the state it
  /// starts from, the routes the wheel plays through (kept: a switch replaces the voice only),
  /// the load, what was restored, and the timings.
  func wheelLoad(_ id: String) {
    let log = wheelLog
    let (n, t0, sinceLast) = log.nextSwitch()
    let w = wheel
    let l = w.layout
    WheelLog.i(
      "switch.start",
      [
        "n": n, "from": l?.id, "to": id, "since_last_ms": sinceLast, "queued": log.queuedNow,
        "rewinding": w.rewinding, "started": w.started, "paused": w.paused, "moving": w.moving,
        "motor": l?.motor, "speed": l?.speedMps, "follow": w.follow,
      ])
    let inserts = inserts.chains["Wheel"]?.effects.filter(\.on).map(\.id).joined(separator: ",") ?? ""
    WheelLog.i(
      "switch.routes",
      [
        "n": n, "strip": "input:Windwheel", "kept": true, "vocoder": vox.state?.modulator,
        "wheel_inserts": inserts.isEmpty ? "none" : inserts,
      ])
    prefs.set(id, forKey: "wheel_preset")
    wheelJob("switch \(n) to \(id)") { p in
      let waited = WheelLog.now() - t0
      let got = try self.loadWithSequence(p, id, n)
      WheelLog.i(
        "switch.done",
        [
          "n": n, "to": got.id, "law": got.law, "notes": got.notes.count, "magnets": got.magnets,
          "motor": got.motor, "interval": got.intervalS, "waited_ms": waited, "total_ms": WheelLog.now() - t0,
        ])
      return got
    }
  }

  /// Load `id` with the note sequence last wound on it, if one was, and its build knobs. Each
  /// step is logged (switch `n`; 0: the launch's restore), a restore that fails too: it falls
  /// back to what loaded, and says so.
  private nonisolated func loadWithSequence(_ p: Player, _ id: String, _ n: Int = 0) throws -> WheelLayout {
    var t = WheelLog.now()
    let l0: WheelLayout
    do { l0 = try p.wheelLoad(id: id) } catch {
      WheelLog.w("switch.load.fail", ["n": n, "to": id, "error": "\(error)"])
      throw error
    }
    WheelLog.i("switch.load", ["n": n, "to": id, "law": l0.law, "notes": l0.notes.count, "ms": WheelLog.now() - t])
    let seq = prefs.string(forKey: seqKey(id))
    t = WheelLog.now()
    var l = l0
    if let seq, !seq.trimmingCharacters(in: .whitespaces).isEmpty {
      if seq == l0.sequence {
        WheelLog.i("switch.sequence", ["n": n, "restored": "same"])
      } else {
        do {
          l = try p.wheelSequence(text: seq)
          WheelLog.i("switch.sequence", ["n": n, "restored": seq, "ms": WheelLog.now() - t])
        } catch {
          WheelLog.w("switch.sequence.fail", ["n": n, "saved": seq, "error": "\(error)"])
        }
      }
    } else {
      WheelLog.i("switch.sequence", ["n": n, "restored": "none"])
    }
    let g = prefs.object(forKey: gearKey(id)) as? Double ?? 6
    Task { @MainActor in self.wheel.gear = g }
    guard let k = savedKnobs(id) else {
      WheelLog.i("switch.knobs", ["n": n, "restored": "none", "gear": g])
      return l
    }
    t = WheelLog.now()
    do {
      let lk = try p.wheelKnobs(knobs: k)
      WheelLog.i(
        "switch.knobs",
        [
          "n": n, "restored": "saved", "magnets": k.magnets, "carrier_g": k.carrierG, "braking": k.braking,
          "release_m": k.releaseM, "load_ohms": k.loadOhms, "timbre": k.timbre, "decay_ms": k.decayMs, "gear": g,
          "ms": WheelLog.now() - t,
        ])
      return lk
    } catch {
      WheelLog.w("switch.knobs.fail", ["n": n, "saved": prefs.string(forKey: knobsKey(id)), "error": "\(error)"])
      return l
    }
  }

  private nonisolated func savedKnobs(_ id: String) -> WheelKnobs? {
    guard let f = prefs.string(forKey: knobsKey(id))?.split(separator: "|", omittingEmptySubsequences: false),
      f.count == 7, let m = UInt32(f[0]), let c = Double(f[1]), let r = Double(f[3]), let o = Double(f[4]),
      let d = Double(f[6])
    else { return nil }
    return WheelKnobs(
      magnets: m, carrierG: c, braking: f[2] == "true", releaseM: r, loadOhms: o, timbre: String(f[5]), decayMs: d)
  }

  /// The layout shown, edited at once (the engine's answer replaces it when it comes).
  func editWheelLayout(_ f: (inout WheelLayout) -> Void) {
    guard var l = wheel.layout else { return }
    f(&l)
    wheel.layout = l
  }

  /// The build knobs of the instrument on now, as they stand.
  func currentWheelKnobs() -> WheelKnobs? {
    wheel.layout.map {
      WheelKnobs(
        magnets: $0.magnets, carrierG: $0.carrierG, braking: $0.braking, releaseM: $0.releaseM, loadOhms: $0.loadOhms,
        timbre: $0.timbre, decayMs: $0.decayMs)
    }
  }

  /// The build knobs, live (a slider sends dozens: one apply on its way, taking the latest), and
  /// saved for this instrument.
  func wheelKnobs(_ k: WheelKnobs) {
    guard let id = wheel.layout?.id else { return }
    editWheelLayout {
      $0.magnets = k.magnets
      $0.carrierG = k.carrierG
      $0.braking = k.braking
      $0.releaseM = k.releaseM
      $0.loadOhms = k.loadOhms
      $0.timbre = k.timbre
      $0.decayMs = k.decayMs
    }
    prefs.set(
      [
        "\(k.magnets)", "\(k.carrierG)", "\(k.braking)", "\(k.releaseM)", "\(k.loadOhms)", k.timbre, "\(k.decayMs)",
      ].joined(separator: "|"), forKey: knobsKey(id))
    guard knobsPending.put(k) else { return }
    let pending = knobsPending
    wheelJob { p in
      while true {
        let v = pending.value ?? k
        let l = try p.wheelKnobs(knobs: v)
        if pending.done(v) { return l }
      }
    }
  }

  /// Brightness as the slider moves: at most one re-wind on its way, taking the latest.
  func wheelBrightness(_ b: Double) {
    guard brightPending.put(b) else { return }
    let pending = brightPending
    wheelJob { p in
      while true {
        let v = pending.value ?? b
        let l = try p.wheelBrightness(brightness: v)
        if pending.done(v) { return l }
      }
    }
  }

  func wheelFollow(_ deck: String) {
    wheel.follow = deck
    prefs.set(deck, forKey: "wheel_follow")
  }

  /// The sync × slider: the wheel on rung `index` of `deck`'s ladder (×1 at 0, ×2 at 1, ½ at
  /// −1), live; one apply on its way takes the latest.
  func wheelRung(_ deck: String, _ index: Int) {
    guard let p = player else { return }
    let v = RungPick(deck: deck, index: index)
    guard rungPending.put(v) else { return }
    let pending = rungPending
    wheelQueue.async {
      while let v = pending.value {
        if let s = try? p.wheelRung(deck: v.deck, index: Int32(v.index)) {
          Task { @MainActor in
            self.editWheelLayout {
              $0.motor = true
              $0.speedMps = s.motorMps
            }
          }
        }
        if pending.done(v) { break }
      }
    }
  }

  func wheelGear(_ g: Double) {
    guard let id = wheel.layout?.id else { return }
    wheel.gear = g
    prefs.set(g, forKey: gearKey(id))
  }

  /// Wind a typed note sequence ("C E G B C B G E") round the instrument; kept for next time.
  func wheelSequence(_ text: String) {
    guard let id = wheel.layout?.id else { return }
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    prefs.set(t, forKey: seqKey(id))
    WheelLog.i("wheel.sequence", ["id": id, "text": t])
    wheelJob("sequence") { try $0.wheelSequence(text: t) }
  }

  /// Back to the preset's own notes (forgets the sequence wound on it; the build knobs stay).
  func wheelPresetNotes() {
    guard let id = wheel.layout?.id else { return }
    prefs.removeObject(forKey: seqKey(id))
    WheelLog.i("wheel.preset_notes", ["id": id])
    wheelJob("preset notes") { try self.loadWithSequence($0, id) }
  }

  func wheelKey(_ root: String, _ transpose: Int) {
    wheelJob { try $0.wheelKey(root: root, transpose: Int32(transpose)) }
  }

  func wheelVolume(_ db: Double) {
    editWheelLayout { $0.volumeDb = db }
    act { try $0.wheelVolume(db: db) }
  }

  /// The trigger's pull (0 open … ½ matched … 1 short), or nil for the fixed load.
  func wheelTrigger(_ pull: Double?) {
    editWheelLayout { $0.trigger = pull }
    act { try $0.wheelTrigger(pull: pull) }
  }

  func wheelMotor(_ on: Bool, _ speed: Double) {
    editWheelLayout {
      $0.motor = on
      $0.speedMps = speed
    }
    act { try $0.wheelMotor(on: on, speed: speed) }
  }

  /// Sync the wheel to `deck`: the motor set so its tempo settles on the whole-number multiple
  /// of the deck's BPM nearest it now.
  func wheelSync(_ deck: String) { wheelTempoMove { try $0.wheelSync(deck: deck) } }

  /// One rung up or down `deck`'s ladder, within the motor's range (nothing at its end).
  func wheelStep(_ deck: String, _ up: Bool) { wheelTempoMove { try $0.wheelStep(deck: deck, up: up) } }

  private func wheelTempoMove(_ f: @escaping @Sendable (Player) throws -> WheelSync?) {
    guard let p = player else { return }
    wheelQueue.async {
      do {
        guard let s = try f(p) else { return }
        Task { @MainActor in
          self.editWheelLayout {
            $0.motor = true
            $0.speedMps = s.motorMps
          }
        }
      } catch {
        let msg = "\(error)"
        Task { @MainActor in self.error = msg }
      }
    }
  }

  /// Gravity: a magnet drops by itself every `s` seconds (0: by hand only).
  func wheelInterval(_ s: Double) {
    editWheelLayout { $0.intervalS = s }
    act { try $0.wheelInterval(seconds: s) }
  }

  // A finger on the drawing: straight to the engine, on the caller's thread, in order. Each
  // takes the wheel's lock for a moment (the feeder holds it for 256 frames at most).
  func wheelDrive(_ v: Double) { try? player?.wheelDrive(v: v) }
  func wheelHand(_ z: Double) { try? player?.wheelHand(z: z) }
  func wheelRelease(_ v: Double?) { try? player?.wheelRelease(v: v) }
  func wheelPluck(_ segment: Int?) { try? player?.wheelPluck(segment: segment.map { UInt32($0) }) }

  /// Play/Pause. Playing: pause, everything held. Paused: play on from exactly there. Never
  /// played yet: play it, and set it going if nothing would (a cord's motor at the speed its
  /// notes are wound for; a drop or a pluck for the others).
  func wheelPlayPause() {
    let w = wheel
    WheelLog.i(
      "wheel.playpause", ["to": w.started && !w.paused ? "pause" : "play", "id": w.layout?.id, "started": w.started])
    if w.started && !w.paused {
      wheel.paused = true
      wheel.moving = false
      act { try $0.wheelPause(paused: true) }
      return
    }
    wheel.paused = false
    wheel.started = true
    willPlayWheel()
    let l = w.layout
    let kickMotor = !w.started && l?.cord == true && l?.motor == false
    let kickPluck = !w.started && l != nil && l?.cord == false
    if kickMotor { editWheelLayout { $0.motor = true } }
    let speed = l?.speedMps ?? 0
    act { p in
      try p.wheelPause(paused: false)
      if kickMotor { try p.wheelMotor(on: true, speed: speed) }
      if kickPluck { try p.wheelPluck(segment: nil) }
    }
  }
}

/// The field log's counters (Kotlin's `switches`, `lastSwitchMs`, `wheelQueued`): touched from
/// the main thread and the wheel's queue.
final class WheelLogCounters: @unchecked Sendable {
  private let lock = NSLock()
  private var switches = 0
  private var lastSwitchMs: Int64 = 0
  private var queuedJobs = 0

  /// The next switch's number, its start, and the ms since the last one (nil: the first).
  func nextSwitch() -> (Int, Int64, Int64?) {
    lock.lock()
    defer { lock.unlock() }
    switches += 1
    let t = WheelLog.now()
    let since = lastSwitchMs == 0 ? nil : t - lastSwitchMs
    lastSwitchMs = t
    return (switches, t, since)
  }

  /// Jobs queued on the wheel's queue and not yet done (a switch logs how many it waited behind).
  func queued(_ d: Int) {
    lock.lock()
    queuedJobs += d
    lock.unlock()
  }

  var queuedNow: Int {
    lock.lock()
    defer { lock.unlock() }
    return queuedJobs
  }
}

/// A sync-slider pick: a rung of a deck's ladder.
struct RungPick: Equatable {
  var deck: String
  var index: Int
}
