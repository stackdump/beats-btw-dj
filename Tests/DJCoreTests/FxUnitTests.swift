import Testing

@testable import DJCore

// The FX unit (FxUnit.swift, FxUnitDeck.swift): a move glides to its target, a neutral unit is
// bit-transparent, macros ride on top of it and return to it, the pokes round-trip and replay to
// the byte, and a net deck's room and echo sends answer.

private let sr = 48_000.0

/// Two sines a loop, quiet enough that the loops' limiter never touches them.
private func tones() -> [SampleBuffer] {
  [fxSineBuffer(hz: 375, amplitude: 0.15), fxSineBuffer(hz: 6000, amplitude: 0.15)]
}

private func set(_ bus: LoopMasterBus, _ p: FxParam, _ v: Double, snap: Bool = false) {
  bus.sendFxUnit(.set(param: UInt8(p.index), value: v, snap: snap))
}

struct FxUnitLayerTests {
  /// A move glides there: a third of the way after ~12 ms, all the way after a few hundred.
  @Test func aMoveGlidesToItsTarget() {
    let a = FxAutomation()
    let u = FxUnitLayer(sampleRate: sr)
    u.take(.set(param: UInt8(FxParam.hp.index), value: 0.8, snap: false))
    var emitted: [Double] = []
    var frame = 0
    func block() {
      u.beginBlock(frames: 512, startFrame: frame, automation: a) { k, v in
        if k == .hpFreq { emitted.append(v) }
      }
      frame += 512
    }
    block()
    #expect(u.value(.hp) > 0.2 && u.value(.hp) < 0.6, "one block (10.7 ms): part of the way")
    for _ in 0..<60 { block() }
    #expect(u.value(.hp) == 0.8, "settled exactly on the target")
    #expect(u.settled)
    #expect(emitted.count > 5 && emitted.count < 62)
    #expect(zip(emitted, emitted.dropFirst()).allSatisfy { $0 < $1 }, "rises, never jumps back")
    #expect(emitted.last == 80, "the chain is asked for slider 80")
    // nothing more once it is there
    var more = 0
    u.beginBlock(frames: 512, startFrame: frame, automation: a) { _, _ in more += 1 }
    #expect(more == 0)
  }

  /// The combination rule: at neutral every macro dispatch passes through exactly; with the unit
  /// set, HP the higher, LP the lower, crush / drive / mix the larger, pitch adds.
  @Test func macrosRideOnTheUnitsSetting() {
    let a = FxAutomation()
    let u = FxUnitLayer(sampleRate: sr)
    for k in MasterFxKey.allCases {
      for v in stride(from: k.min, through: k.max, by: 7) {
        #expect(u.automated(k, v, automation: a) == Double(v), "\(k) \(v) at neutral")
      }
    }
    for (p, v) in [(FxParam.hp, 0.3), (.lp, 0.6), (.pitch, 3), (.crush, 0.5), (.phaserDepth, 0.9)] {
      u.take(.set(param: UInt8(p.index), value: v, snap: true))
    }
    #expect(u.automated(.hpFreq, 10, automation: a) == 30)
    #expect(u.automated(.hpFreq, 80, automation: a) == 80)
    #expect(u.automated(.lpFreq, 100, automation: a) == 60)
    #expect(u.automated(.lpFreq, 5, automation: a) == 5)
    #expect(u.automated(.masterPitch, 12, automation: a) == 15)
    #expect(u.automated(.masterPitch, -12, automation: a) == -9)
    #expect(u.automated(.crushBits, 20, automation: a) == 50)
    // depth: the unit's while no macro moves it, the macro's when it does
    #expect(u.automated(.phaserDepth, 50, automation: a) == 90)
    #expect(u.automated(.phaserDepth, 100, automation: a) == 100)
    // the bipolar filter: left is the LP, right the HP, against the knobs' own
    u.take(.set(param: UInt8(FxParam.filter.index), value: -0.7, snap: true))
    #expect(abs(u.automated(.lpFreq, 100, automation: a) - 30) < 1e-9, "the lower of 30 and 60")
    u.take(.set(param: UInt8(FxParam.filter.index), value: 0.5, snap: true))
    #expect(u.automated(.hpFreq, 0, automation: a) == 50, "the higher of 50 and 30")
    // killed: every macro passes through again
    u.take(.kill(on: true, frame: 0))
    u.beginBlock(frames: 512, startFrame: 0, automation: a) { _, _ in }
    for _ in 0..<80 { u.beginBlock(frames: 512, startFrame: 0, automation: a) { _, _ in } }
    #expect(u.automated(.hpFreq, 10, automation: a) == 10)
    #expect(u.automated(.masterPitch, 12, automation: a) == 12)
  }

  /// A quantised reset waits for its frame; a knob moved meanwhile lands it at once.
  @Test func aQuantisedResetLandsOnItsFrameOrUnderAHand() {
    let a = FxAutomation()
    let u = FxUnitLayer(sampleRate: sr)
    u.take(.set(param: UInt8(FxParam.drive.index), value: 0.7, snap: true))
    u.take(.reset(frame: 10_000))
    u.beginBlock(frames: 512, startFrame: 9_000, automation: a) { _, _ in }
    #expect(u.value(.drive) == 0.7, "not yet: the block ends before frame 10 000")
    u.beginBlock(frames: 512, startFrame: 9_600, automation: a) { _, _ in }
    #expect(u.value(.drive) < 0.7, "the block holding it")
    u.take(.set(param: UInt8(FxParam.crush.index), value: 0.4, snap: true))
    u.take(.reset(frame: 50_000))
    u.take(.set(param: UInt8(FxParam.pitch.index), value: 2, snap: true))
    #expect(u.value(.crush) == 0.4)
    u.beginBlock(frames: 512, startFrame: 10_100, automation: a) { _, _ in }
    #expect(u.value(.crush) < 0.4, "the hand landed the waiting reset")
    #expect(u.value(.pitch) == 2, "and its own move stands")
  }

  /// Dragging is recorded at most 30 times a second, the latest value winning, the last one sent.
  @Test func aDragIsCoalescedTo30Hz() {
    var c = FxUnitCoalescer()
    var sent: [Double] = []
    var t = 0.0
    for i in 0..<200 {  // 2 s of mouse events at 100 Hz
      let v = Double(i) / 200
      if c.offer("A|filter", v, now: t) { sent.append(v) }
      sent += c.due(now: t).map(\.value)
      t += 0.01
    }
    if let last = c.finish("A|filter") { sent.append(last) }
    #expect(sent.count <= 2 * 30 + 2, "\(sent.count) actions for 2 s")
    #expect(sent.count >= 40)
    #expect(sent.last == 199.0 / 200, "the last value is the one that lands")
    let again = c.offer("A|filter", 0.5, now: t)
    #expect(again, "a new drag sends at once")
  }
}

struct FxUnitBusTests {
  /// A unit set to its neutral values (never moved) sends nothing to the chain: the same bytes.
  @Test func aNeutralUnitIsBitTransparent() {
    let dry = FxBankRig(tones()).render(48_000)
    let rig = FxBankRig(tones())
    for p in FxParam.allCases { set(rig.bank.master, p, p.neutral) }
    rig.bank.master.sendFxUnit(.kill(on: false, frame: 0))
    let wet = rig.render(48_000)
    #expect(wet.left == dry.left && wet.right == dry.right)
    #expect(rig.bank.master.filterCorners.bypassed)
  }

  /// Every control moved, then reset (and, again, killed): once the glides and the stages' fades
  /// are done the bus is back to bypass and the bytes are the dry ones.
  @Test func afterAResetOrAKillTheBusIsBitIdenticalAgain() {
    for kill in [false, true] {
      let dry = FxBankRig(tones()).render(4 * 48_000)
      let rig = FxBankRig(tones())
      let bus = rig.bank.master
      for (p, v) in [
        (FxParam.filter, -0.4), (.hp, 0.3), (.phaserMix, 0.6), (.phaserDepth, 0.8),
        (.phaserRate, 0.3), (.crush, 0.5), (.drive, 0.4), (.pitch, -5),
      ] {
        set(bus, p, v)
      }
      var wet = rig.render(48_000)
      #expect(wet.left[24_000..<48_000] != dry.left[24_000..<48_000], "the unit is heard")
      #expect(!bus.filterCorners.bypassed)
      if kill { bus.sendFxUnit(.kill(on: true, frame: 0)) } else { bus.sendFxUnit(.reset(frame: 0)) }
      let rest = rig.render(3 * 48_000)
      wet.left += rest.left
      wet.right += rest.right
      let from = 2 * 48_000
      #expect(Array(wet.left[from...]) == Array(dry.left[from...]), "kill \(kill)")
      #expect(Array(wet.right[from...]) == Array(dry.right[from...]))
      #expect(bus.filterCorners.bypassed)
      #expect(rig.bank.limiter.idle)
    }
  }

  /// The HP corner glides to where the knob is (no jump at the first block), then holds.
  @Test func theCornerGlidesThereAndHolds() {
    let rig = FxBankRig(tones())
    let bus = rig.bank.master
    set(bus, .hp, 0.6)
    let target = MasterParams.hpFreq(60)
    rig.skip(512)
    let first = bus.filterCorners.hp
    #expect(first > 20 && first < target * 0.8, "part of the way after a block: \(first)")
    var last = first
    for _ in 0..<40 {
      rig.skip(512)
      let c = bus.filterCorners.hp
      #expect(c >= last - 1e-9, "never back")
      last = c
    }
    #expect(abs(last - target) / target < 1e-3, "\(last) Hz vs \(target)")
    // the low tone is cut, the high one passes
    let w = rig.render(4608 * 2)
    let dry = FxBankRig(tones())
    dry.skip(rig.frame - 4608 * 2)
    let d = dry.render(4608 * 2)
    let low = toneAmplitude(Array(w.left[0..<4608]), hz: 375)
    let lowDry = toneAmplitude(Array(d.left[0..<4608]), hz: 375)
    #expect(dB(low / lowDry) < -12, "375 Hz under a 550 Hz HP: \(dB(low / lowDry)) dB")
  }

  /// A macro rides on top of the unit and returns to it: sweep-hp from the unit's HP up and back
  /// to the unit's corner, not to 20 Hz.
  @Test func aMacroReturnsToTheUnitsSetting() {
    let rig = FxBankRig(tones())
    let bus = rig.bank.master
    set(bus, .hp, 0.3, snap: true)
    set(bus, .lp, 0.7, snap: true)
    rig.skip(4096)
    let base = MasterParams.hpFreq(30)
    let lpBase = MasterParams.lpFreq(70)
    #expect(abs(bus.filterCorners.hp - base) < 1e-6)
    bus.fire(.sweepHp, bars: 1, frame: 0, bpm: 240)  // one bar = 1 s
    bus.fire(.sweepLp, bars: 1, frame: 0, bpm: 240)
    var peakHP = 0.0
    var lowestLP = 1e9
    while rig.frame < 4096 + 48_000 {
      rig.skip(512)
      peakHP = max(peakHP, bus.filterCorners.hp)
      lowestLP = min(lowestLP, bus.filterCorners.lp)
      #expect(bus.filterCorners.hp >= base - 1e-6, "never under the unit's HP")
      #expect(bus.filterCorners.lp <= lpBase + 1e-6, "never over the unit's LP")
    }
    #expect(peakHP > 1000, "the sweep went up: \(peakHP)")
    #expect(lowestLP < 300, "and the LP down: \(lowestLP)")
    rig.skip(48_000)
    #expect(bus.activeMasterMacros.isEmpty)
    #expect(abs(bus.filterCorners.hp - base) < 1e-6, "back on the unit's HP")
    #expect(abs(bus.filterCorners.lp - lpBase) < 1e-6, "and its LP")
  }
}

struct FxUnitCodecTests {
  @Test func thePokesRoundTripFoldAndRead() throws {
    let actions: [DeckAction] = [
      .fx(deck: "A", param: "filter", value: -0.35), .fx(deck: "L", param: "pitch", value: 7),
      .fxReset(deck: "B", onBeat: false), .fxReset(deck: "L", onBeat: true),
      .fxKill(deck: "A", on: true, onBeat: false), .fxKill(deck: "B", on: false, onBeat: true),
    ]
    for (i, a) in actions.enumerated() {
      #expect(DeckAction(json: try JSONValue.parse(a.json.jsStringified)) == a)
      let e = JournalEntry(seq: i + 1, time: journalDate(1), frame: i, event: .action(a))
      #expect(try #require(JournalEntry(line: e.line)).event == .action(a))
    }
    #expect(DeckAction(json: try JSONValue.parse(#"{"op":"fx","deck":"A","value":1}"#)) == nil)
    #expect(DeckAction(json: try JSONValue.parse(#"{"op":"fx","deck":"A","param":"hp"}"#)) == nil)
    #expect(DeckAction.fxReset(deck: "A", onBeat: false).json.jsStringified.contains("onBeat") == false)
    let fx = JournalEvent.action(.fx(deck: "A", param: "hp", value: 0.2))
    #expect(fx.foldKey == "A.fxunit.hp")
    #expect(JournalEvent.action(.fx(deck: "A", param: "hp", value: 0.9)).foldKey == fx.foldKey)
    #expect(JournalEvent.action(.fx(deck: "A", param: "lp", value: 0.9)).foldKey != fx.foldKey)
    #expect(fx.foldKey != JournalEvent.action(.masterFx(deck: "A", key: "hp-freq", value: 0)).foldKey)
    #expect(fx.summary == "A fx unit hp 0.20")
    #expect(JournalEvent.action(.fxReset(deck: "L", onBeat: true)).summary == "L fx unit reset on the beat")
    #expect(JournalEvent.action(.fxKill(deck: "A", on: true, onBeat: false)).summary == "A fx unit killed")
  }

  /// A deck's FX unit is part of its starting params (sessions, checkpoints), and only when set.
  @Test func theSettingsAreInTheDecksParamsOnlyWhenSet() {
    var p = DeckParams()
    #expect(p.json["fxUnit"] == nil, "a neutral unit keeps old sets' canonical text")
    p.fxUnit[.filter] = 0.25
    p.fxUnit[.pitch] = -3
    p.fxUnit.killed = true
    let back = DeckParams(json: p.json)
    #expect(back.fxUnit == p.fxUnit)
    #expect(back.fxUnit.moved == [.filter, .pitch])
    var clamped = FxUnitSettings()
    clamped[.pitch] = 40
    clamped[.hp] = .nan
    #expect(clamped[.pitch] == 12 && clamped[.hp] == 0)
  }
}

struct FxUnitDeckTests {
  /// The deck keeps its setting through a mode switch and hands it to the chain it plays through.
  @Test @MainActor func theSettingFollowsTheDeckAcrossModes() throws {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: sr)
    let a = dj["A"]!
    a.loadDemo()
    dj.perform(.fx(deck: "A", param: "drive", value: 0.4))
    dj.perform(.fx(deck: "L", param: "filter", value: -0.5))
    #expect(a.fxUnit[.drive] == 0.4 && dj.loopChannel.fxUnit[.filter] == -0.5)
    #expect(dj["B"]!.fxUnit.isNeutral)
    #expect(!a.fxUnitControls.contains(.room), "a sample deck has no room send")
    #expect(a.fxUnitMissing(.echo) != nil && dj.loopChannel.fxUnitMissing(.room) != nil)
    #expect(a.fxUnitMissing(.crush) == nil)
    dj.perform(.fxKill(deck: "A", on: true, onBeat: false))
    #expect(a.fxUnit.killed && !a.fxUnit.isActive && !a.fxUnit.isNeutral)
    dj.perform(.fxReset(deck: "A", onBeat: true))
    #expect(a.fxUnit.isNeutral && !a.fxUnit.killed)
    #expect(a.currentParams.fxUnit.isNeutral && dj.loopChannel.currentParams.fxUnit[.filter] == -0.5)
    // a starting state restored at once
    var s = FxUnitSettings()
    s[.crush] = 0.3
    var p = a.currentParams
    p.fxUnit = s
    a.apply(p)
    #expect(a.fxUnit == s)
  }
}

struct FxUnitSendTests {
  /// A net deck's room and echo answer the unit's sends; set to neutral they leave the bytes alone.
  @Test func aNetDecksRoomAndEchoAnswer() {
    let rate = 22_050.0
    let opts = WaveOptions.extended(samplers: nil).forGenre("trance")
    var ov = JSONObject()
    ov["seed"] = .number(7)
    let song = compose(genre: "trance", overrides: .object(ov))
    func source() -> WaveDeckSource {
      let s = WaveDeckSource(sampleRate: rate, opts: .extended(samplers: nil))
      s.load(WaveRunner.prepare(song, sampleRate: rate, opts: opts))
      s.play()
      return s
    }
    let dry = source()
    let neutral = source()
    let wet = source()
    #expect(wet.hasRoom && wet.hasEcho)
    for p in FxParam.sends {
      neutral.sendFxUnit(.set(param: UInt8(p.index), value: 0, snap: false))
    }
    wet.sendFxUnit(.set(param: UInt8(FxParam.room.index), value: 1, snap: false))
    wet.sendFxUnit(.set(param: UInt8(FxParam.echo.index), value: 1, snap: false))
    wet.sendFxUnit(.set(param: UInt8(FxParam.feedback.index), value: 0.8, snap: false))
    func render(_ s: WaveDeckSource) -> [Float] {
      var out: [Float] = []
      var l = [Float](repeating: 0, count: 256)
      var r = [Float](repeating: 0, count: 256)
      for _ in 0..<600 {
        l.withUnsafeMutableBufferPointer { lp in
          r.withUnsafeMutableBufferPointer { rp in
            s.render(frames: 256, left: lp.baseAddress!, right: rp.baseAddress!)
          }
        }
        out += l
        out += r
      }
      return out
    }
    let d = render(dry)
    #expect(render(neutral) == d, "neutral sends: the genre's room and echo exactly")
    let w = render(wet)
    let diff = zip(w, d).map { $0 - $1 }
    #expect(rms(diff) > 0.1 * rms(d), "4× the sends are heard: \(rms(diff)) vs \(rms(d))")
  }
}

struct FxUnitReplayTests {
  /// A set that drags, kills (on the beat), resets and stacks a macro replays to the byte, by its
  /// session and by its journal.
  @Test @MainActor func aSetWithTheFxUnitReplaysToTheByte() throws {
    func script(_ dj: DJEngine, _ bar: Int, _ b: Int) {
      switch b {
      case (2 * bar)...(2 * bar + 40):
        dj.perform(.fx(deck: "A", param: "filter", value: -0.8 + 0.03 * Double(b - 2 * bar)))
      case 3 * bar: dj.perform(.fx(deck: "A", param: "pitch", value: 4))
      case 4 * bar: dj.perform(.fx(deck: "L", param: "crush", value: 0.5))
      case 4 * bar + 7: dj.perform(.macro(deck: "L", id: "sweep-hp"))
      case 5 * bar: dj.perform(.fx(deck: "L", param: "hp", value: 0.4))
      case 6 * bar: dj.perform(.fxKill(deck: "L", on: true, onBeat: true))
      case 6 * bar + 100: dj.perform(.fxKill(deck: "L", on: false, onBeat: false))
      case 7 * bar: dj.perform(.fxReset(deck: "A", onBeat: true))
      case 7 * bar + 50: dj.perform(.fxReset(deck: "L", onBeat: false))
      default: break
      }
    }
    let blocks = 9 * 344
    let live = try loopMasterSet(blocks: blocks, script)
    #expect(live.session.events.contains { $0.kind == .action(.fxKill(deck: "L", on: true, onBeat: true)) })
    let replay = try SessionPlayer(session: live.session).render()
    #expect(replay.left == live.audio.left && replay.right == live.audio.right, "session replay")
    let j = try Journal.replay(live.journal, endFrame: blocks * 128, render: true)
    let audio = try #require(j.audio)
    let n = min(audio.frames, live.audio.frames)
    #expect(n > blocks * 128 - 1024)
    #expect(Array(audio.left.prefix(n)) == Array(live.audio.left.prefix(n)), "journal replay")
    let dry = try loopMasterSet(blocks: blocks) { _, _, _ in }
    #expect(dry.audio.left != live.audio.left, "the unit was heard")
    let before = 2 * 344 * 128
    #expect(Array(dry.audio.left.prefix(before)) == Array(live.audio.left.prefix(before)))
  }
}
