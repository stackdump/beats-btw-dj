import DJCore
import SwiftUI
import Testing

@testable import DJViews

// SPEC mode 26 on screen. AppKit controls (buttons, toggles) render as placeholders offscreen, so
// the glow is checked on plain shapes, and the NetPanel snapshot by what changes around its
// controls when a macro runs.
@MainActor
struct MacroPulseRenderTests {
  func netState(
    running: Set<NetMacro> = [], pulsing: Set<String> = [], hot: Set<String> = []
  ) -> DeckState {
    var s = DeckState()
    s.isNet = true
    s.roles = ["kick", "snare", "hihat", "bass", "melody", "harmony", "arp"]
    s.rolesOn = Set(s.roles)
    s.macroPulse = MacroPulseState(running: running, pulsing: pulsing, hot: hot)
    return s
  }

  func panel(_ s: DeckState) -> some View {
    NetPanel(name: "A", state: s, model: AppModel(), tint: .orange).padding(14)
  }

  /// A 60 x 24 slab on a clear 140 x 70 ground, lit as a chase would.
  func slab(_ level: MacroPulseLevel) -> some View {
    Rectangle().fill(Color(white: 0.5)).frame(width: 60, height: 24).macroPulseGlow(level)
  }

  @Test func theGlowIsDimWhenTouchedAndHardWhenHot() throws {
    let off = try #require(renderPixels(slab(.none), width: 140, height: 70))
    let dim = try #require(renderPixels(slab(.dim), width: 140, height: 70))
    let hot = try #require(renderPixels(slab(.hot), width: 140, height: 70))
    // the slab spans x 40...100, y 23...47; look 2 pt left of its edge, mid-height
    let (x, y) = (38, 35)
    #expect(off.color(x, y).a == 0, "no level, no glow")
    let d = dim.color(x, y)
    let h = hot.color(x, y)
    #expect(d.a > 20 && d.a < 110, "dim: 0 0 4px 1px at 0.35: \(d)")
    #expect(h.a > 110, "hot: 0 0 10px 3px at 0.95: \(h)")
    #expect(h.a > d.a * 2)
    // both are the accent #e94560 (premultiplied by their alpha)
    for c in [d, h] {
      let k = Double(c.a) / 255
      #expect(abs(Double(c.r) / k - 233) < 30 && abs(Double(c.g) / k - 69) < 30, "\(c)")
    }
    // the hot glow reaches further out than the dim one
    let far = (30, 35)
    #expect(hot.color(far.0, far.1).a > dim.color(far.0, far.1).a, "hot reaches further")
    // and the slab itself is untouched
    #expect(hot.near(70, 35, (128, 128, 128), tol: 6))
  }

  /// A box-shadow of blur B px is a Gaussian of sigma B / 2, centred on the shadow's edge: the
  /// grown rectangle's edge. Beside the middle of a long edge the alpha falls as
  /// `alpha * Q(d / sigma)`, d the distance out from that edge and Q the Gaussian's upper tail
  /// (Q(0) = 0.5, Q(1) = 0.1587, Q(2) = 0.0228). Looked at 4 pixels to the point, so the falloff
  /// itself can be read, not just whether there is a glow.
  @Test func theGlowFallsOffAsTheCSSBlurDoes() throws {
    // a 100 x 60 slab on a 200 x 120 ground: its left edge at x = 50, the glow's at 50 - spread
    func profile(_ level: MacroPulseLevel, spread: Double, at ds: [Double]) throws -> [Int] {
      let view = Rectangle().fill(Color(white: 0.5)).frame(width: 100, height: 60)
        .macroPulseGlow(level)
      let px = try #require(renderPixelsScaled(view, width: 200, height: 120, scale: 4))
      return ds.map { px.alpha(atPoint: 50 - spread - $0, 60, scale: 4) }
    }
    // hot: 0 0 10px 3px at 0.95: sigma 5 pt, so 121 / 38 / 5.5 of 255 at 0 / 5 / 10 pt out
    let hot = try profile(.hot, spread: 3, at: [0, 5, 10])
    #expect(abs(hot[0] - 121) <= 14, "at the glow's edge: \(hot[0])")
    #expect(
      abs(hot[1] - 38) <= 9, "one sigma out (a blur of 10 px, not 5, would read 75): \(hot[1])")
    #expect(abs(hot[2] - 6) <= 6, "two sigma out: \(hot[2])")
    // dim: 0 0 4px 1px at 0.35: sigma 2 pt, so 45 / 14 / 2 of 255 at 0 / 2 / 4 pt out
    let dim = try profile(.dim, spread: 1, at: [0, 2, 4])
    #expect(abs(dim[0] - 45) <= 10, "\(dim[0])")
    #expect(abs(dim[1] - 14) <= 7, "\(dim[1])")
    #expect(abs(dim[2] - 2) <= 4, "\(dim[2])")
    // and inside the grown edge the glow is under the slab, which hides it
    let inside = try profile(.hot, spread: 3, at: [-6])  // 3 pt in from the glow's edge
    #expect(inside[0] > 200, "the slab itself: \(inside[0])")
  }

  @Test func aRunningMacroLightsItsButton() throws {
    func button(_ running: Bool, time: Double = 0.5) -> some View {
      MacroButton(macro: .drop, running: running, time: time) {}.padding(16)
    }
    let size = (w: 120, h: 60)
    let idle = try #require(renderPixels(button(false), width: size.w, height: size.h))
    // Offscreen the button is a placeholder box in the middle (about x 35...85, y 18...45); what
    // the macro adds is a red glow in the margin around it.
    func glow(_ p: Pixels) -> Int {
      var n = 0
      for y in 0..<p.height {
        for x in 0..<p.width where x < 30 || x >= 90 || y < 14 || y >= 50 {
          let c = p.color(x, y)
          if c.r > 2 * c.g && c.r > 2 * c.b { n += c.a }  // alpha-weighted: the glow's energy
        }
      }
      return n
    }
    #expect(glow(idle) == 0, "an idle macro button has no glow")
    func running(_ t: Double) throws -> Pixels {
      try #require(renderPixels(button(true, time: t), width: size.w, height: size.h))
    }
    let peak = glow(try running(0.5))
    let quarter = glow(try running(0.25))
    let late = glow(try running(0.375))
    let rest = glow(try running(0))
    #expect(peak > 1000, "a running macro's button glows at the middle of its cycle: \(peak)")
    #expect(rest == 0, "0 0 0 0: nothing outside the button at the ends of the cycle: \(rest)")
    // (the placeholder box offscreen is a little larger than the button's own frame, which hides
    // the first of the glow: the order is what is checked)
    #expect(rest <= quarter && quarter <= late && late < peak, "\(rest) \(quarter) \(late) \(peak)")
    #expect(glow(try running(0.625)) == late, "the way down mirrors the way up")
    #expect(glow(try running(1.0)) == rest, "and the cycle repeats every second")
  }

  @Test func theNetPanelChasesTheTargetsAndMovesTheLightEveryStep() throws {
    let targets: Set<String> = ["bass", "melody", "harmony", "arp"]
    let idle = try #require(renderPixels(panel(netState()), width: 330, height: 160))
    func lit(hot: String) throws -> Pixels {
      try #require(
        renderPixels(
          panel(netState(running: [.drop], pulsing: targets, hot: [hot])), width: 330, height: 160))
    }
    let a = try lit(hot: "bass")
    let b = try lit(hot: "melody")
    func diff(_ p: Pixels, _ q: Pixels) -> [(x: Int, y: Int)] {
      var out: [(x: Int, y: Int)] = []
      for y in 0..<p.height {
        for x in 0..<p.width where p.color(x, y) != q.color(x, y) { out.append((x, y)) }
      }
      return out
    }
    let running = diff(idle, a)
    #expect(running.count > 400, "a running drop changes the panel: \(running.count) pixels")
    // the chase moves: the two frames differ where the light left and where it arrived
    let moved = diff(a, b)
    #expect(moved.count > 150, "\(moved.count) pixels differ between hot = bass and hot = melody")
    savePNG(
      panel(netState(running: [.drop], pulsing: targets, hot: ["melody"])), width: 330, height: 160,
      name: "macro-chase-netpanel")
    savePNG(panel(netState()), width: 330, height: 160, name: "macro-chase-netpanel-idle")
  }

  @Test func aMacroWithNoChaseStillShowsRunning() throws {
    let idle = try #require(renderPixels(panel(netState()), width: 330, height: 160))
    let beat = try #require(
      renderPixels(panel(netState(running: [.beatRepeat])), width: 330, height: 160))
    var changed = 0
    for y in 0..<idle.height {
      for x in 0..<idle.width where idle.color(x, y) != beat.color(x, y) { changed += 1 }
    }
    #expect(changed > 100, "the beat repeat's own button shows running: \(changed)")
  }
}

/// The whole path: a real deck's macro, the engine's mirror, the app model's poll.
@MainActor
struct MacroChaseAppTests {
  func rig() throws -> (AppModel, DJEngine, Deck, () -> Double, (Double) -> Void) {
    let dj = try DJEngine(decks: ["A", "B"], offline: true, sampleRate: 22_050)
    let a = try #require(dj["A"])
    a.loadNet(PreparedTrack(spec: TrackSpec(genre: "techno", seed: 42), sampleRate: 22_050))
    dj["B"]!.loadDemo()
    a.wave.setTempo(300)  // a tick every 50 ms: a bar is 800 ms
    a.setPlaying(true)
    try dj.start()
    nonisolated(unsafe) var now = 100.0
    let m = AppModel(engine: dj)
    m.uptime = { now }
    m.start()
    return (m, dj, a, { now }, { now = $0 })
  }

  @Test func aDropChasesTheRolesItMutedUntilItsRestore() throws {
    let (m, dj, a, _, setClock) = try rig()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050 / 2)
    m.poll()
    #expect(m.decks["A"]?.macroPulse == MacroPulseState(), "nothing runs yet")
    let drums: Set<String> = ["kick", "snare", "hihat", "clap"]
    let expected = a.roles.filter { !drums.contains($0) && a.isRoleOn($0) }
    #expect(expected.count >= 3)

    m.fire("A", .drop)  // one bar: 16 ticks = 800 ms of engine time
    _ = try renderOffline(dj, frames: 512)
    setClock(200)
    m.poll()
    var pulse = try #require(m.decks["A"]?.macroPulse)
    #expect(pulse.running == [.drop])
    #expect(pulse.pulsing == Set(expected), "the roles the engine holds muted")
    #expect(pulse.hot == [expected[0]], "the light starts on the first")
    #expect(m.decks["A"]?.rolesOn.isDisjoint(with: Set(expected)) == true, "they really are muted")

    // 120 ms of the app's clock per poll (the engine barely moves): the light walks the roles
    // in mixer order and wraps
    var seen = [expected[0]]
    for i in 1...(expected.count + 1) {
      _ = try renderOffline(dj, frames: 512)
      setClock(200 + Double(i) * 0.12)
      m.poll()
      pulse = try #require(m.decks["A"]?.macroPulse)
      #expect(pulse.running == [.drop], "still in effect after \(i) steps")
      seen.append(try #require(pulse.hot.first))
    }
    let want = (0...(expected.count + 1)).map { expected[$0 % expected.count] }
    #expect(seen == want, "\(seen)")

    // the restore ends the chase: engine time runs out, the roles come back
    _ = try renderOffline(dj, frames: 22_050)
    setClock(210)
    m.poll()
    #expect(m.decks["A"]?.macroPulse == MacroPulseState(), "end on macro end")
    #expect(m.decks["A"]?.rolesOn.isSuperset(of: Set(expected)) == true)
  }

  @Test func twoOverlappingMacrosEachChaseOnlyTheirOwnRoles() throws {
    let (m, dj, a, _, setClock) = try rig()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050 / 2)
    let drums: Set<String> = ["kick", "snare", "hihat", "clap"]
    let on = a.roles.filter { a.isRoleOn($0) }
    m.fire("A", .drop)  // holds the non-drums...
    m.fire("A", .cut)  // ...and the cut finds only the drums still sounding
    _ = try renderOffline(dj, frames: 512)
    setClock(600)
    m.poll()
    let activity = a.macroActivity
    let drop = activity.targets[.drop] ?? []
    let cut = activity.targets[.cut] ?? []
    #expect(Set(drop) == Set(on.filter { !drums.contains($0) }) && !drop.isEmpty, "drop: \(drop)")
    #expect(Set(cut) == Set(on.filter { drums.contains($0) }) && !cut.isEmpty, "cut: \(cut)")
    #expect(Set(drop).isDisjoint(with: cut), "no role is chased twice")
    let pulse = try #require(m.decks["A"]?.macroPulse)
    #expect(pulse.running == [.drop, .cut])
    #expect(pulse.pulsing == Set(drop).union(cut), "the toggles pulse for both, once each")
    #expect(pulse.hot.count == 2, "each chase has its own running light: \(pulse.hot)")
  }

  @Test func aBreakdownChasesTheDrumsAndPanicEndsIt() throws {
    let (m, dj, a, _, setClock) = try rig()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050 / 2)
    let drums = a.roles.filter {
      ["kick", "snare", "hihat", "clap"].contains($0) && a.isRoleOn($0)
    }
    m.fire("A", .breakdown)
    _ = try renderOffline(dj, frames: 512)
    setClock(300)
    m.poll()
    let pulse = try #require(m.decks["A"]?.macroPulse)
    #expect(pulse.running == [.breakdown] && pulse.pulsing == Set(drums) && !drums.isEmpty)
    m.panic("A")
    _ = try renderOffline(dj, frames: 512)
    setClock(300.1)
    m.poll()
    #expect(m.decks["A"]?.macroPulse == MacroPulseState(), "panic restores everything")
  }

  @Test func theBeatRepeatAndATempoMacroShowRunningWithoutAChase() throws {
    let (m, dj, _, _, setClock) = try rig()
    defer { dj.stop() }
    _ = try renderOffline(dj, frames: 22_050 / 2)
    m.fire("A", .beatRepeat)
    m.fire("A", .halfTime)
    _ = try renderOffline(dj, frames: 2048)
    setClock(400)
    m.poll()
    let pulse = try #require(m.decks["A"]?.macroPulse)
    #expect(pulse.running == [.beatRepeat, .halfTime])
    #expect(pulse.pulsing.isEmpty && pulse.hot.isEmpty, "the JS never chases these")
  }

  @Test func aSampleDeckNeverPulses() throws {
    let (m, dj, _, _, setClock) = try rig()
    defer { dj.stop() }
    setClock(500)
    m.poll()
    #expect(m.decks["B"]?.macroPulse == MacroPulseState())
  }
}
