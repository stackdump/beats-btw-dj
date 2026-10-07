import Testing

@testable import DJCore

struct SurfaceProfileTests {
  let apc = SurfaceProfile.apcMiniMK2
  let mpk = SurfaceProfile.mpkMiniMK2

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

  @Test func mpkParsesAnyChannel() {
    #expect(mpk.parse([0x99, 36, 100])?.group == "pads")  // pads often send on ch 10
    #expect(mpk.parse([0x90, 48, 100]).map { [$0.group, "\($0.index)"] } == ["keys", "0"])
    #expect(mpk.parse([0xB0, 77, 64])?.index == 7)
  }

  @Test func everyLayoutEntryPointsAtARealControl() {
    for p in SurfaceProfile.all {
      for b in p.layout {
        #expect(
          p.number(group: b.group, index: b.index) != nil, "\(p.name): \(b.group)[\(b.index)]")
        if b.action != .crossfader && b.action != .master {
          #expect(b.deck != nil, "\(p.name): \(b)")
        }
      }
      #expect(
        Set(p.layout.map { "\($0.group)#\($0.index)" }).count == p.layout.count,
        "\(p.name) binds a control twice")
    }
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
