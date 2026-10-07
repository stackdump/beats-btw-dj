import Testing

@testable import DJCore

struct SurfaceProfileTests {
  let apc = SurfaceProfile.apcMiniMK2
  let mpk = SurfaceProfile.mpkMiniMK2
  let inpulse = SurfaceProfile.inpulse200MK3

  @Test func profilesLoadAndMatchPortNames() {
    #expect(apc.matches(portName: "APC mini mk2 Control"))
    #expect(!apc.matches(portName: "APC mini mk2 Notes"))
    #expect(!apc.matches(portName: "APC mini"))  // mk1 has a different protocol
    #expect(mpk.matches(portName: "MPK Mini Mk II"))
    #expect(mpk.matches(portName: "MPKmini2"))
    #expect(!mpk.matches(portName: "DJControl Inpulse 200 Mk3"))
  }

  @Test func apcParsesPadsButtonsAndFaders() {
    #expect(
      apc.parse([0x90, 0x00, 0x7F])
        == ControlEvent(group: "pads", index: 0, value: 1, pressed: true, isCC: false))
    #expect(apc.parse([0x90, 0x3F, 0x00])?.pressed == false)
    #expect(apc.parse([0x80, 0x09, 0x40])?.pressed == false)
    #expect(apc.parse([0x90, 0x64, 0x7F])?.group == "track")
    #expect(apc.parse([0x90, 0x77, 0x7F]).map { [$0.group, "\($0.index)"] } == ["scene", "7"])
    #expect(
      apc.parse([0xB0, 0x38, 127])
        == ControlEvent(group: "faders", index: 8, value: 1, pressed: true, isCC: true))
    #expect(apc.parse([0xB0, 0x39, 10]) == nil)  // past master fader
    #expect(apc.parse([0x90, 0x40, 0x7F]) == nil)  // gap above the grid
  }

  @Test func mpkMatchesTheMeasuredPreset() {
    #expect(mpk.parse([0x90, 48, 100]).map { [$0.group, "\($0.index)"] } == ["keys", "48"])
    #expect(mpk.parse([0xB0, 8, 64]).map { [$0.group, "\($0.index)"] } == ["knobs", "7"])
    #expect(
      mpk.parse([0xC0, 3, 0]).map { [$0.group, "\($0.index)", "\($0.pressed)"] } == [
        "pads", "3", "true",
      ])
    #expect(mpk.parse([0x99, 36, 100])?.group == "padNotes")
    let bend = mpk.parse([0xE0, 0x00, 0x40])  // centre = 8192
    #expect(bend?.group == "joystickX")
    #expect(abs((bend?.value ?? 0) - 8192.0 / 16383) < 1e-9)
    #expect(mpk.parse([0xB0, 77, 64]) == nil)  // beats' factory map, not this preset
  }

  @Test func inpulseDecodes14BitAndShiftChannels() {
    var d = SurfaceDecoder(profile: inpulse)
    let msb = d.decode([0xB1, 0x00, 0x40])  // deck A volume, MSB
    #expect(msb?.name == "volume")
    let lsb = d.decode([0xB1, 0x20, 0x7F])  // LSB refines it
    #expect(lsb?.group == "deckA.faders")
    #expect(abs((lsb?.value ?? 0) - Double(0x40 << 7 | 0x7F) / 16383) < 1e-12)
    #expect(inpulse.parse([0x91, 0x07, 0x7F])?.name == "play")
    #expect(
      inpulse.parse([0x92, 0x06, 0x7F]).map { [$0.group, $0.name ?? ""] } == [
        "deckB.buttons", "cue",
      ])
    #expect(inpulse.parse([0x94, 0x09, 0x7F])?.group == "deckA.shiftButtons")
    #expect(inpulse.parse([0x96, 0x02, 0x7F])?.group == "deckA.hotcuePads")
    #expect(inpulse.parse([0xB0, 0x01, 0x7F])?.delta == -1)  // browser encoder
  }

  /// Phase 1 contract: every control in every profile is bound or parked on
  /// purpose — none falls through.
  @Test func everyControlIsCovered() {
    for p in SurfaceProfile.all {
      for g in p.groups {
        let wide = p.layout.contains { $0.group == g.id && $0.index == nil }
        for i in g.controlNumbers.indices where !wide {
          #expect(
            p.layout.contains { $0.group == g.id && $0.index == i },
            "\(p.name): \(g.id)[\(i)] has no layout entry")
        }
        if g.type == .pitchbend {
          #expect(p.layout.contains { $0.group == g.id }, "\(p.name): \(g.id) has no layout entry")
        }
      }
      for b in p.layout {
        #expect(p.group(b.group) != nil, "\(p.name): layout names unknown group \(b.group)")
        if let i = b.index, p.group(b.group)?.type != .pitchbend {
          #expect(
            p.number(group: b.group, index: i) != nil, "\(p.name): \(b.group)[\(i)] out of range")
        }
        if b.action == .unbound {
          #expect(b.reason != nil, "\(p.name): \(b.group) parked without a reason")
        }
        let deckless: Set<DJActionKind> = [.crossfader, .master, .shift, .unbound]
        if !deckless.contains(b.action) { #expect(b.deck != nil, "\(p.name): \(b)") }
      }
      let keys = p.layout.map {
        "\($0.group)#\($0.index.map(String.init) ?? "*")#\($0.shift.map { "\($0)" } ?? "-")"
      }
      #expect(Set(keys).count == keys.count, "\(p.name) binds a control twice")
    }
  }

  /// Every distinct message the real hardware sent on 2026-10-07 decodes
  /// and lands on a layout entry (jog messages go to the jog profile).
  @Test func everyCapturedMessageIsCovered() throws {
    let caps = try capturedMessages()
    let profiles = ["inpulse": inpulse, "apc": apc, "mpk": mpk]
    #expect(Set(caps.keys) == Set(profiles.keys))
    var checked = 0
    for (dev, msgs) in caps {
      let p = profiles[dev]!
      var d = SurfaceDecoder(profile: p)
      for m in msgs {
        if dev == "inpulse", JogProfile.inpulse200MK3.parse(m) != nil { continue }
        if dev == "inpulse", m[0] & 0xF0 == 0xB0, [0x09, 0x0A].contains(m[1]), m[2] == 0 {
          continue
        }  // zero-tick jog
        guard let e = d.decode(m) else {
          Issue.record("\(dev): \(m.map { String(format: "%02X", $0) }) does not decode")
          continue
        }
        let covered = p.layout.contains {
          $0.group == e.group && ($0.index == nil || $0.index == e.index)
        }
        #expect(covered, "\(dev): \(e.group)[\(e.index)] decoded but has no layout entry")
        checked += 1
      }
    }
    #expect(checked > 280, "only \(checked) captured messages checked")
  }
}

@MainActor
struct SurfaceControllerTests {
  func make(_ p: SurfaceProfile = .apcMiniMK2) throws -> (DJEngine, SurfaceController) {
    let dj = try DJEngine(offline: true)
    for d in dj.decks.values { d.loadDemo() }
    return (dj, SurfaceController(profile: p, engine: dj))
  }

  func send(_ s: SurfaceController, _ bytes: [UInt8], now: Double = 0) {
    s.handle(s.profile.parse(bytes)!, now: now)
  }

  @Test func fadersDriveTheMixer() throws {
    let (dj, s) = try make()
    send(s, [0xB0, 0x30, 0])  // fader 1: A volume
    send(s, [0xB0, 0x37, 127])  // fader 8: B volume
    send(s, [0xB0, 0x33, 127])  // fader 4: crossfader hard B
    send(s, [0xB0, 0x38, 64])  // master
    #expect(dj["A"]!.volume == 0)
    #expect(dj["B"]!.volume == 1)
    #expect(dj.crossfader == 1)
    #expect(abs(dj.crossfadeGain("A")) < 1e-9)
    #expect(abs(dj.master - 64.0 / 127) < 1e-6)
    #expect(dj["B"]!.strip.outputVolume == 1)
    #expect(dj["A"]!.strip.outputVolume == 0)
  }

  @Test func pitchFaderHasCentreDetent() throws {
    let (dj, s) = try make()
    send(s, [0xB0, 0x32, 64])  // 64/127 is just off centre
    #expect(dj["A"]!.pitch == 0)
    send(s, [0xB0, 0x32, 127])
    #expect(dj["A"]!.pitch == 1)
  }

  @Test func filterSweepsLowAndHighPass() throws {
    let (dj, s) = try make()
    let eq = dj["A"]!.filterNode
    send(s, [0xB0, 0x31, 0])
    #expect(!eq.bands[0].bypass && eq.bands[1].bypass)
    #expect(abs(eq.bands[0].frequency - 200) < 1)
    send(s, [0xB0, 0x31, 64])
    #expect(eq.bands[0].bypass && eq.bands[1].bypass)
    send(s, [0xB0, 0x31, 127])
    #expect(eq.bands[0].bypass && !eq.bands[1].bypass)
    #expect(abs(eq.bands[1].frequency - 5000) < 1)
  }

  @Test func playTogglesOnPressOnly() throws {
    let (dj, s) = try make()
    send(s, [0x90, 0x70, 0x7F])
    send(s, [0x90, 0x70, 0x00])  // release does nothing
    #expect(dj["A"]!.playing)
    send(s, [0x90, 0x70, 0x7F])
    #expect(!dj["A"]!.playing)
  }

  @Test func hotCueSetsThenClears() throws {
    let (dj, s) = try make()
    send(s, [0x90, 4, 0x7F])  // pad 4: B cue 0 — empty, so set at playhead
    #expect(dj["B"]!.hotCues[0] != nil)
    send(s, [0x90, 12, 0x7F])  // pad 12: clear B cue 0
    #expect(dj["B"]!.hotCues[0] == nil)
  }

  @Test func ledsReflectStateAndOnlySendChanges() throws {
    let (dj, s) = try make()
    let first = s.ledFrame(now: 100)
    #expect(first.count == 64 + 8 + 8)  // every LED once
    #expect(s.ledFrame(now: 100).isEmpty)  // nothing changed
    #expect(first.contains([0x92, 0, 9]))  // A cue pad: dim orange
    #expect(first.contains([0x92, 63, 0]))  // unbound pad: off
    #expect(first.contains([0x90, 0x70, 1]))  // play A: on

    dj["A"]!.setPlaying(true)
    send(s, [0x90, 0, 0x7F], now: 100)  // set A cue 0
    let next = s.ledFrame(now: 100.01)
    #expect(next.contains([0x96, 0, 9]))  // cue set: bright
    #expect(next.contains([0x92, 8, 5]))  // its clear pad: red
    #expect(next.contains([0x90, 0x70, 2]))  // playing: blink
    #expect(s.blackout().count == 80)
  }

  @Test func mpkHasNoLEDs() throws {
    let (_, s) = try make(.mpkMiniMK2)
    #expect(s.ledFrame().isEmpty)
  }
}

@MainActor
struct Phase1ActionTests {
  func make(_ p: SurfaceProfile) throws -> (DJEngine, SurfaceController) {
    let dj = try DJEngine(offline: true)
    for d in dj.decks.values { d.loadDemo() }
    return (dj, SurfaceController(profile: p, engine: dj))
  }

  @Test func inpulseTransportCueAndLoopButtons() throws {
    let (dj, s) = try make(.inpulse200MK3)
    let a = dj["A"]!
    s.handle(bytes: [0x91, 0x06, 0x7F])  // CUE while paused: set cue point
    #expect(a.cuePoint == a.turntable.position)
    s.handle(bytes: [0x91, 0x07, 0x7F])  // PLAY
    #expect(a.playing)
    s.handle(bytes: [0x91, 0x06, 0x7F])  // CUE while playing: back to cue, pause
    #expect(!a.playing)
    s.handle(bytes: [0x91, 0x09, 0x7F])  // LOOP IN
    #expect(a.loopStart != nil && !a.looping)
    s.handle(bytes: [0x91, 0x0A, 0x7F])  // LOOP OUT at the same spot: too short, ignored
    #expect(!a.looping)
    s.handle(bytes: [0x92, 0x07, 0x7F])  // deck B PLAY
    #expect(dj["B"]!.playing)
  }

  @Test func inpulseKnobsDriveGainAndEQ() throws {
    let (dj, s) = try make(.inpulse200MK3)
    let b = dj["B"]!
    s.handle(bytes: [0xB2, 0x05, 0x7F])  // gain MSB → full
    s.handle(bytes: [0xB2, 0x25, 0x7F])
    #expect(b.gain == 1)
    #expect(abs(b.strip.outputVolume - Float(2 * b.volume * dj.crossfadeGain("B"))) < 1e-4)
    s.handle(bytes: [0xB2, 0x02, 0x00])  // EQ low → kill
    s.handle(bytes: [0xB2, 0x22, 0x00])
    #expect(b.filterNode.bands[2].gain == -24 && !b.filterNode.bands[2].bypass)
    s.handle(bytes: [0xB2, 0x04, 0x40])  // EQ high → centre
    s.handle(bytes: [0xB2, 0x24, 0x00])
    #expect(abs(b.eqHigh - 0.5) < 0.01 && b.filterNode.bands[4].bypass)
  }

  @Test func apcShiftIsHeldInSoftware() throws {
    let (_, s) = try make(.apcMiniMK2)
    #expect(!s.shiftHeld)
    s.handle(bytes: [0x90, 0x7A, 0x7F])
    #expect(s.shiftHeld)
    s.handle(bytes: [0x80, 0x7A, 0x00])
    #expect(!s.shiftHeld)
  }

  @Test func softTakeoverBetweenDevices() throws {
    let dj = try DJEngine(offline: true)
    let apc = SurfaceController(profile: .apcMiniMK2, engine: dj)
    let mpk = SurfaceController(profile: .mpkMiniMK2, engine: dj)
    apc.handle(bytes: [0xB0, 0x30, 0])  // APC fader 1 → A volume 0
    #expect(dj["A"]!.volume == 0)
    // MPK knob 2 (A volume) is physically at max: held back, not a jump.
    #expect(
      mpk.handle(bytes: [0xB0, 2, 127])?.1
        == .pickup(mpk.binding(for: mpk.decode([0xB0, 2, 127])!)!))
    #expect(dj["A"]!.volume == 0)
    // Turning it down through the current value picks it up.
    mpk.handle(bytes: [0xB0, 2, 60])
    #expect(dj["A"]!.volume == 0)
    mpk.handle(bytes: [0xB0, 2, 2])  // within the window
    #expect(abs(dj["A"]!.volume - 2.0 / 127) < 1e-9)
    // The MPK now owns it and turns it up to ~0.79.
    mpk.handle(bytes: [0xB0, 2, 100])
    #expect(abs(dj["A"]!.volume - 100.0 / 127) < 1e-9)
    // The APC fader is still physically near the bottom: held back.
    apc.handle(bytes: [0xB0, 0x30, 1])
    #expect(abs(dj["A"]!.volume - 100.0 / 127) < 1e-9)
    // Pushing it up past the current value (1 → 110 crosses 100) picks it up.
    apc.handle(bytes: [0xB0, 0x30, 110])
    #expect(abs(dj["A"]!.volume - 110.0 / 127) < 1e-9)
    #expect(dj.owners["A.volume"] == "APC mini mk2/faders#0")
  }
}
