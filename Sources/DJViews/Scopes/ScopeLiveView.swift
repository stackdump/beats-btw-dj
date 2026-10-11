import DJCore
import SwiftUI

// Scope / Live (SPEC mode 1, scope.js `drawLive`): the master waveform (per-pixel min/max
// envelope and +/- RMS) over four bars, with the notes the nets fired underneath, one lane per
// part, on one time axis whose right edge is "now".
//
// All numbers come from `LiveScopeModel` / `LiveScopeScene` (DJCore); this file only paints them,
// in the order drawLive does: grid -> envelope -> RMS -> corner label -> lanes -> events -> lane
// labels. Frames are paced and pumped by `ScopeCanvas`. A sample deck has a waveform and no lanes.

struct ScopeLiveView: View {
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  /// The feed's model from `LiveScopeStore`: it outlives this view (the host makes a new one for
  /// every switch of kind or source), so the gain and the waveform carry over.
  private let model: LiveScopeModel
  /// Monotonic seconds; the spring and the release run on real frame time, not audio time.
  private let wall: @MainActor () -> Double

  /// The host's initialiser (ScopePanelView). `measured` means nothing to this view.
  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub) {
    self.init(
      feed: feed, measured: measured, hub: hub, model: LiveScopeStore.shared.model(for: feed)
    ) {
      ProcessInfo.processInfo.systemUptime
    }
  }

  /// For tests: a model with a state of their choosing and a clock they control.
  init(
    feed: ScopeFeed, measured: Bool = false, hub: ScopeHub, model: LiveScopeModel,
    wall: @escaping @MainActor () -> Double
  ) {
    self.feed = feed
    self.measured = measured
    self.hub = hub
    self.model = model
    self.wall = wall
  }

  var body: some View {
    ScopeCanvas(hub: hub) { ctx, size in
      model.update(feed: feed, wall: wall())
      let scene = model.scene(feed: feed, width: size.width, height: size.height)
      LiveScopePainter.paint(scene, in: &ctx)
    }
  }
}

/// Scene -> Canvas calls.
enum LiveScopePainter {
  static let font = Font.system(size: 10, design: .monospaced)

  static func rect(_ r: LiveScopeRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

  static func paint(_ scene: LiveScopeScene, in ctx: inout GraphicsContext) {
    guard scene.ok else { return }

    func text(_ t: LiveScopeText, _ color: ScopeColor, in ctx: inout GraphicsContext) {
      ctx.draw(
        ctx.resolve(Text(t.text).font(font).foregroundColor(color.color)),
        at: CGPoint(x: t.x, y: t.y), anchor: .topLeading)
    }

    // grid: beat lines, then bar lines (they never overlap: a bar is every fourth beat), bar
    // numbers, section markers and names
    var beats = Path()
    var bars = Path()
    for g in scene.gridLines {
      if g.bar { bars.addRect(rect(g.rect)) } else { beats.addRect(rect(g.rect)) }
    }
    ctx.fill(beats, with: .color(ScopeColors.grid.color))
    ctx.fill(bars, with: .color(ScopeColors.barLine.color))
    for l in scene.barLabels { text(l, ScopeColors.text, in: &ctx) }
    for m in scene.sections {
      ctx.fill(Path(rect(m.rect)), with: .color(ScopeColors.sectionLine.color))
      text(m.name, ScopeColors.sectionLine, in: &ctx)
    }

    // envelope: one 1 px rect per column
    var env = Path()
    for r in scene.envelope { env.addRect(rect(r)) }
    ctx.fill(env, with: .color(ScopeColors.envelope.color))

    // RMS: -rms line, then +rms line
    for pts in [scene.rmsLower, scene.rmsUpper] {
      guard let first = pts.first else { continue }
      var p = Path()
      p.move(to: CGPoint(x: first.x, y: first.y))
      for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
      ctx.stroke(p, with: .color(ScopeColors.rms.color), lineWidth: 1.2)
    }

    if let c = scene.corner { text(c, ScopeColors.text, in: &ctx) }
    if let e = scene.emptyMessage { text(e, ScopeColors.text, in: &ctx) }

    // lanes: separators, then the events in the scene's order (newest first, so the oldest hit
    // is on top where two overlap; a dash that leaves its lane's band can overlap another lane's),
    // one fill per run of events of one lane, then the labels
    guard scene.laneHeight > 0 else { return }
    var seps = Path()
    for r in scene.laneLines { seps.addRect(rect(r)) }
    ctx.fill(seps, with: .color(ScopeColors.grid.color))
    var run = Path()
    var runLane = -1
    func flush(_ ctx: inout GraphicsContext) {
      if !run.isEmpty, scene.laneColors.indices.contains(runLane) {
        ctx.fill(run, with: .color(scene.laneColors[runLane].color))
      }
      run = Path()
    }
    for e in scene.events {
      if e.lane != runLane {
        flush(&ctx)
        runLane = e.lane
      }
      run.addRect(rect(e.rect))
    }
    flush(&ctx)
    for l in scene.laneLabels {
      let resolved = ctx.resolve(Text(l.text).font(font).foregroundColor(l.color.color))
      let size = resolved.measure(in: CGSize(width: 10_000, height: 100))
      ctx.fill(
        Path(CGRect(x: l.plateX, y: l.y, width: size.width + 4, height: l.plateHeight)),
        with: .color(
          Color(.sRGB, red: 5.0 / 255, green: 10.0 / 255, blue: 20.0 / 255, opacity: 0.7)))
      ctx.draw(resolved, at: CGPoint(x: l.textX, y: l.y), anchor: .topLeading)
    }
  }
}
