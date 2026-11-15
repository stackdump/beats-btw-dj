import DJRust
import Foundation
import os

// The wheel half of djandroid's PlayerViewModel ("MARK: the wheel", `pollWheel`): windwheel's
// tonewheel, played on the Wheel tab. Same calls, same preference keys (`wheel_preset`,
// `wheel_follow`, `wheel_sequence/<id>`, `wheel_knobs/<id>`, `wheel_gear/<id>`).
//
// Re-winds and loads (a few ms to a few hundred) run one at a time on `wheelQueue`, each
// replacing the layout the page draws; the plain settings go through `act` like every other
// control. A finger on the drawing calls the engine straight from the gesture, in order (each
// takes only the wheel's lock for a moment).

private let log = Logger(subsystem: "io.bitwrap.beats-btw-dj", category: "wheel")

/// djandroid WheelUi. `rewinding`: a change is being wound (the wheel plays on and the new
/// winding crossfades in). `moving`: it sounds now (the tab's dot). `started`: played since the
/// engine started (before that it is stopped and the button says Play); `paused`: held where it
/// is, silent, everything kept.
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

/// The latest of a burst (a slider sends dozens): at most one apply on its way, and it takes the
/// latest value when it gets there (djandroid's AtomicReference pattern).
final class Latest<T: Equatable>: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: T?
  /// Store `v`; true if an apply is already on its way (it will take `v`).
  func set(_ v: T) -> Bool { lock.withLock { defer { pending = v }; return pending != nil } }
  var value: T? { lock.withLock { pending } }
  /// The apply of `v` is done: true if nothing newer came meanwhile (then it's cleared).
  func done(_ v: T) -> Bool { lock.withLock { if pending == v { pending = nil; return true }; return false } }
}

struct RungAim: Equatable { var deck: String; var index: Int32 }

/// What the wheel's poll (a background task) and the page share: how many drawings watch the
/// magnets, and the tracker they read.
final class WheelShared: @unchecked Sendable {
  private let lock = NSLock()
  private var watchers = 0
  private var _tracker: MagnetTracker?
  private var trackerKey = ""
  private var generation = 0
  let knobs = Latest<WheelKnobs>()
  let rung = Latest<RungAim>()
  let brightness = Latest<Double>()

  var watching: Bool { lock.withLock { watchers > 0 } }
  func watch(_ on: Bool) { lock.withLock { watchers += on ? 1 : -1 } }

  /// The tracker and its generation (a new one per instrument and path: a motor or level change
  /// keeps it, and the motion it has).
  var tracker: (MagnetTracker, Int)? { lock.withLock { _tracker.map { ($0, generation) } } }

  func tracker(for l: WheelLayout) -> MagnetTracker {
    lock.withLock {
      let key = "\(l.id)|\(l.periodic)|\(l.extentM)"
      if let t = _tracker, key == trackerKey { return t }
      let t = MagnetTracker(extent: l.periodic ? l.extentM : 0)
      _tracker = t
      trackerKey = key
      generation += 1
      return t
    }
  }
}

extension RustDJModel {
  // MARK: start and poll

  func wheelAttach(_ p: Player) {
    wheel = WheelUI(presets: DJRust.wheelPresets(), follow: prefs.string(forKey: "wheel_follow") ?? "A")
    // the instrument as last left, at rest: a drum or a bow left on doesn't start turning by
    // itself at launch
    let id = prefs.string(forKey: "wheel_preset") ?? "hoop-looper"
    let saved = savedWheel(id)
    log.info("switch.restore to=\(id, privacy: .public)")
    wheelJob("restore \(id)") { p in
      var l = try Self.loadWithSequence(p, id, saved)
      if l.motor {
        try p.wheelMotor(on: false, speed: l.speedMps)
        l.motor = false
      }
      return l
    }
    let shared = wheelShared
    Task.detached(priority: .userInitiated) { [weak self] in await self?.pollWheel(p, shared) }
  }

  /// The magnets at about the display's rate while a drawing watches (fed to its tracker only
  /// when they moved), the meters, tempo and the tab's dot ~30 times a second.
  private nonisolated func pollWheel(_ p: Player, _ shared: WheelShared) async {
    var lastState: Int64 = 0
    var last: [WheelMagnet]?
    var lastGen = 0
    var still = true
    while !Task.isCancelled {
      let now = monoNs()
      let watched = shared.watching
      if watched, let tg = shared.tracker, let m = try? p.wheelMotion() {
        let stamp = monoNs()
        let (t, gen) = tg
        if gen != lastGen {
          lastGen = gen
          last = nil
        }
        var fed = false
        if m.magnets != last {
          fed = true
          last = m.magnets
          let ms = m.magnets
          t.feed(
            MagnetTracker.Sample(
              z: ms.map(\.z), v: ms.map(\.v), on: ms.map(\.on), seg: ms.map { Int($0.segment) }, voiceS: m.voiceS,
              stampNs: stamp))
        }
        // a sample that moved them while the drawing rests (a jump: a magnet dropped back in,
        // a hand on the rail) asks it for one frame
        let idle = t.idle(monoNs())
        let jump = fed && idle
        if idle != still || jump {
          still = idle
          await MainActor.run {
            self.wheelStill = idle
            if jump { self.wheelMoved &+= 1 }
          }
        }
      }
      if now - lastState >= 33_000_000, let s = try? p.wheelState() {
        lastState = now
        let moving = !s.paused && (s.outPeak > 0.01 || abs(s.speedMps) > 0.05)
        await MainActor.run {
          // the meters only while the page shows (they redraw the cards that read them)
          if watched { self.wheelState = s }
          let w = self.wheel
          if moving != w.moving || s.paused != w.paused || s.started != w.started {
            self.wheel.moving = moving
            self.wheel.paused = s.paused
            self.wheel.started = s.started
          }
        }
      }
      try? await Task.sleep(for: .milliseconds(watched ? 12 : 33))
    }
  }

  /// The drawing is on screen (true) or gone (false): the magnets are polled only while it is.
  func watchWheel(_ on: Bool) { wheelShared.watch(on) }

  /// `DJ_AUTOPLAY=wheel:ID[:A]`: instrument ID on the wheel (empty: the one restored), played;
  /// with `:A`, deck A plays once loaded too.
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

  /// A wheel job: run on `wheelQueue` (in order), its layout replaces the one drawn; a refusal
  /// becomes the error dialog. Results come back to the main thread in the order they ran.
  func wheelJob(_ what: String, _ f: @escaping @Sendable (Player) throws -> WheelLayout) {
    guard let p = player else {
      log.warning("wheel.job.skip what=\(what, privacy: .public) why=no player")
      return
    }
    wheel.rewinding = true
    wheelQueue.async {
      let r = Result { try f(p) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch r {
          case .success(let l):
            self.wheel.layout = l
          case .failure(let e):
            log.warning("wheel.job.fail what=\(what, privacy: .public) error=\("\(e)", privacy: .public)")
            self.error = "\(e)"
          }
          self.wheel.rewinding = false
        }
      }
    }
  }

  /// An engine call on the wheel's lane whose `WheelSync` sets the motor shown.
  private func wheelSyncJob(_ f: @escaping @Sendable (Player) throws -> WheelSync?) {
    guard let p = player else { return }
    wheelQueue.async {
      let r = Result { try f(p) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch r {
          case .success(let s?): self.editWheelLayout { $0.motor = true; $0.speedMps = s.motorMps }
          case .success(nil): break
          case .failure(let e): self.error = "\(e)"
          }
        }
      }
    }
  }

  func editWheelLayout(_ f: (inout WheelLayout) -> Void) {
    guard var l = wheel.layout else { return }
    f(&l)
    wheel.layout = l
  }

  // MARK: switching instruments

  private func seqKey(_ id: String) -> String { "wheel_sequence/\(id)" }
  private func knobsKey(_ id: String) -> String { "wheel_knobs/\(id)" }
  private func gearKey(_ id: String) -> String { "wheel_gear/\(id)" }

  /// What was last left on instrument `id`: its note sequence, build knobs and gear.
  struct SavedWheel: Sendable {
    var sequence: String?
    var knobs: WheelKnobs?
    var gear: Double
  }

  func savedWheel(_ id: String) -> SavedWheel {
    let g = prefs.object(forKey: gearKey(id)) as? Double
    return SavedWheel(sequence: prefs.string(forKey: seqKey(id)), knobs: savedKnobs(id), gear: g ?? 6)
  }

  private func savedKnobs(_ id: String) -> WheelKnobs? {
    guard let f = prefs.string(forKey: knobsKey(id))?.split(separator: "|", omittingEmptySubsequences: false),
      f.count == 7, let m = UInt32(f[0]), let c = Double(f[1]), let r = Double(f[3]), let o = Double(f[4]),
      let d = Double(f[6])
    else { return nil }
    return WheelKnobs(
      magnets: m, carrierG: c, braking: f[2] == "true", releaseM: r, loadOhms: o, timbre: String(f[5]), decayMs: d)
  }

  /// Load instrument `id` with the note sequence last wound on it, if one was, and its build
  /// knobs. A restore that fails falls back to what loaded, and says so in the log.
  nonisolated static func loadWithSequence(_ p: Player, _ id: String, _ saved: SavedWheel) throws -> WheelLayout {
    let l0 = try p.wheelLoad(id: id)
    var l = l0
    if let seq = saved.sequence, !seq.isEmpty, seq != l0.sequence {
      do { l = try p.wheelSequence(text: seq) } catch {
        log.warning("switch.sequence.fail to=\(id, privacy: .public) saved=\(seq, privacy: .public)")
      }
    }
    guard let k = saved.knobs else { return l }
    do { return try p.wheelKnobs(knobs: k) } catch {
      log.warning("switch.knobs.fail to=\(id, privacy: .public)")
      return l
    }
  }

  /// Switch the wheel to instrument `id` (kept for the next launch).
  func wheelLoad(_ id: String) {
    log.info(
      "switch.start from=\(self.wheel.layout?.id ?? "-", privacy: .public) to=\(id, privacy: .public) started=\(self.wheel.started) paused=\(self.wheel.paused)"
    )
    prefs.set(id, forKey: "wheel_preset")
    let saved = savedWheel(id)
    wheel.gear = saved.gear
    wheelJob("switch to \(id)") { try Self.loadWithSequence($0, id, saved) }
  }

  // MARK: the build knobs (the web toy's), saved per instrument

  /// The build knobs, live (a slider sends dozens: at most one apply on its way, taking the
  /// latest), and saved for this instrument.
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
      ["\(k.magnets)", "\(k.carrierG)", "\(k.braking)", "\(k.releaseM)", "\(k.loadOhms)", k.timbre, "\(k.decayMs)"]
        .joined(separator: "|"), forKey: knobsKey(id))
    let latest = wheelShared.knobs
    if latest.set(k) { return }
    wheelJob("knobs") { p in
      while true {
        let v = latest.value ?? k
        let l = try p.wheelKnobs(knobs: v)
        if latest.done(v) { return l }
      }
    }
  }

  func wheelGear(_ g: Double) {
    guard let id = wheel.layout?.id else { return }
    wheel.gear = g
    prefs.set(g, forKey: gearKey(id))
  }

  // MARK: notes and key

  /// Wind a typed note sequence ("C E G B C B G E") round the instrument; kept for next time.
  func wheelSequence(_ text: String) {
    guard let id = wheel.layout?.id else { return }
    let t = text.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return }
    prefs.set(t, forKey: seqKey(id))
    wheelJob("sequence") { try $0.wheelSequence(text: t) }
  }

  /// Back to the preset's own notes (forgets the sequence wound on it; the build knobs stay).
  func wheelPresetNotes() {
    guard let id = wheel.layout?.id else { return }
    prefs.removeObject(forKey: seqKey(id))
    let saved = savedWheel(id)
    wheelJob("preset notes") { try Self.loadWithSequence($0, id, saved) }
  }

  /// How `text` reads over `root` (chip names), or the parser's complaint.
  func wheelParse(_ text: String, _ root: String) -> Result<[String], Error> {
    Result { try wheelParseSequence(text: text, root: root) }
  }

  func wheelKey(_ root: String, _ transpose: Int32) {
    wheelJob("key \(root) \(transpose)") { try $0.wheelKey(root: root, transpose: transpose) }
  }

  /// Brightness as the slider moves: at most one re-wind on its way, taking the latest value.
  func wheelBrightness(_ b: Double) {
    let latest = wheelShared.brightness
    if latest.set(b) { return }
    wheelJob("brightness") { p in
      while true {
        let v = latest.value ?? 0.5
        let l = try p.wheelBrightness(brightness: v)
        if latest.done(v) { return l }
      }
    }
  }

  // MARK: the plain settings

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

  /// Gravity: a magnet drops by itself every `s` seconds (0: by hand only).
  func wheelInterval(_ s: Double) {
    editWheelLayout { $0.intervalS = s }
    act { try $0.wheelInterval(seconds: s) }
  }

  // MARK: tempo against the decks

  /// The deck the sync × slider follows ("A" or "B"), kept across launches.
  func wheelFollow(_ deck: String) {
    wheel.follow = deck
    prefs.set(deck, forKey: "wheel_follow")
  }

  /// Sync the wheel to `deck`: the motor set so the wheel's tempo settles on the whole-number
  /// multiple of the deck's BPM nearest it now.
  func wheelSync(_ deck: String) { wheelSyncJob { try $0.wheelSync(deck: deck) } }

  /// One rung up or down `deck`'s ladder (into ½, ⅓, … below ×1), within the motor's range.
  func wheelStep(_ deck: String, _ up: Bool) { wheelSyncJob { try $0.wheelStep(deck: deck, up: up) } }

  /// The sync × slider: the wheel on rung `index` of `deck`'s ladder (×1 at 0, ×2 at 1, ½ at −1),
  /// live; a drag sends many, one apply on its way takes the latest.
  func wheelRung(_ deck: String, _ index: Int) {
    let latest = wheelShared.rung
    let aim = RungAim(deck: deck, index: Int32(index))
    if latest.set(aim) { return }
    wheelSyncJob { p in
      var got: WheelSync?
      while let v = latest.value {
        got = try? p.wheelRung(deck: v.deck, index: v.index)
        if latest.done(v) { break }
      }
      return got
    }
  }

  // MARK: a finger on the drawing: straight to the engine, in order

  func wheelDrive(_ v: Double) { try? player?.wheelDrive(v: v) }
  func wheelHand(_ z: Double) { try? player?.wheelHand(z: z) }
  func wheelRelease(_ v: Double?) { try? player?.wheelRelease(v: v) }
  func wheelPluck(_ segment: Int?) { try? player?.wheelPluck(segment: segment.map { UInt32($0) }) }

  /// Play/Pause. Playing: pause, everything held (the magnets where they are, their speeds, the
  /// motor, the sync, the knobs). Paused: play on from exactly there. Never played yet (stopped):
  /// play it, and set it going if nothing would (a cord's motor at the speed its notes are wound
  /// for; a drop or a pluck for the others).
  func wheelPlayPause() {
    let w = wheel
    log.info("wheel.playpause to=\(w.started && !w.paused ? "pause" : "play", privacy: .public)")
    if w.started && !w.paused {
      wheel.paused = true
      wheel.moving = false
      act { try $0.wheelPause(paused: true) }
      return
    }
    willPlay()
    wheel.paused = false
    wheel.started = true
    let l = w.layout
    var kick: (@Sendable (Player) throws -> Void)?
    if !w.started, let l {
      if l.cord && !l.motor {
        let speed = l.speedMps
        kick = { try $0.wheelMotor(on: true, speed: speed) }
        editWheelLayout { $0.motor = true }
      } else if !l.cord {
        kick = { try $0.wheelPluck(segment: nil) }
      }
    }
    let go = kick
    act { p in
      try p.wheelPause(paused: false)
      try go?(p)
    }
  }
}
