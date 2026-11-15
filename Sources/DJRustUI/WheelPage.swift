import DJRust
import SwiftUI

// The wheel (djandroid ui/WheelPage.kt): windwheel's linear tonewheel, magnets moved past a coil
// wound in a pattern, played beside the decks. Its sound is an input strip of the engine's, so it
// plays in the mix, takes the Inserts page's Wheel chain and can be the vocoder's modulator.
//
// Played on the drawing: drag the hoop or the rope round (a flick keeps it spinning), slide the
// rail's magnet, tap a tube to drop a magnet down it, tap the pendulum or the spring to pluck it.
// The cards under it pick the instrument, its key and its sound.

struct WheelPage: View {
  let model: RustDJModel

  var body: some View {
    let w = model.wheel
    let l = w.layout
    VStack(spacing: 16) {
      Card(
        l?.name ?? "Wheel",
        trailing: {
          // stopped until first played; after that only Play/Pause (a pause holds it all)
          let playing = w.started && !w.paused
          Button {
            model.wheelPlayPause()
          } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 22))
              .foregroundStyle(playing ? DJTheme.dim : DJTheme.accent)
              .frame(width: 48, height: 48).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(playing ? "Pause the wheel" : "Play the wheel")
        }
      ) {
        if let l {
          Caption(howToPlay(l)).lineLimit(1)
          Drawing(model: model, l: l, gear: w.gear)
        } else {
          Caption("winding the instrument…")
        }
      }
      if let l { PlayCard(model: model, l: l, follow: w.follow) }
      if let l, l.cord && l.periodic && !l.notes.isEmpty { TempoCard(model: model, l: l) }
      if !w.presets.isEmpty { InstrumentCard(model: model, presets: w.presets, l: l, gear: w.gear) }
      if let l {
        KeyCard(model: model, l: l).id(l.id)
        WheelSoundCard(model: model, l: l).id(l.id)
      }
      Spacer(minLength: 24)
    }
  }
}

private func howToPlay(_ l: WheelLayout) -> String {
  switch l.law {
  case "drive": "Drag the \(l.path) round · flick it to keep it spinning"
  case "motor": "The motor turns it · drag to push it along"
  case "bow": "The bow keeps it moving · drag to bow it yourself"
  case "gravity": l.shapes.count > 1 ? "Tap a tube to drop a magnet down it" : "Tap to drop a magnet"
  case "pendulum": "Tap to pull the pendulum back and let it swing"
  case "spring": "Tap to pluck the spring"
  case "rail": "Slide the magnet along the rail"
  default: ""
  }
}

/// The engine's message without its "wheel: " prefix.
func djMessage(_ e: Error) -> String {
  var m = "\(e)"
  if let d = e as? DjError, let s = Mirror(reflecting: d).children.first?.value as? String { m = s }
  return m.hasPrefix("wheel: ") ? String(m.dropFirst(7)) : m
}

// MARK: the drawing's geometry (model metres, y down)

/// Model metres → view points: the path's box fitted inside the view with a margin.
private struct Fit {
  let scale: Double
  private let ox: Double
  private let oy: Double

  init(_ l: WheelLayout, _ size: CGSize, margin: Double) {
    var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
    var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
    func grow(_ x: Double, _ y: Double) {
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    }
    for s in l.shapes { for i in s.xs.indices { grow(s.xs[i], s.ys[i]) } }
    if let p = l.pivot, p.count >= 2 { grow(p[0], p[1]) }
    if let a = l.anchor, a.count >= 2 { grow(a[0], a[1]) }
    if x0 > x1 { x0 = 0; x1 = 0; y0 = 0; y1 = 0 }
    let bw = max(x1 - x0, 1e-6), bh = max(y1 - y0, 1e-6)
    // a straight path has no extent across it: the other dimension sets the scale
    scale = max(1e-9, min((size.width - 2 * margin) / bw, (size.height - 2 * margin) / bh))
    ox = size.width / 2 - scale * (x0 + x1) / 2
    oy = size.height / 2 - scale * (y0 + y1) / 2
  }

  func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + scale * x, y: oy + scale * y) }
  func model(_ p: CGPoint) -> (Double, Double) { ((p.x - ox) / scale, (p.y - oy) / scale) }
}

/// A point on the path and its unit tangent.
private struct At { var x, y, tx, ty: Double }

/// The segment holding z (a periodic path's z wraps); `seg` when it is a valid hint.
private func segOf(_ l: WheelLayout, _ z: Double, _ seg: Int? = nil) -> Int {
  if let seg, l.shapes.indices.contains(seg) { return seg }
  if l.periodic { return 0 }
  var best = 0
  var bd = Double.greatestFiniteMagnitude
  for (i, s) in l.shapes.enumerated() {
    let d = z < s.startM ? s.startM - z : z > s.startM + s.lengthM ? z - s.startM - s.lengthM : 0
    if d < bd { bd = d; best = i }
  }
  return best
}

/// Where z is on the drawing (extrapolated past an open segment's ends).
private func at(_ l: WheelLayout, _ zIn: Double, _ seg: Int? = nil) -> At {
  let s = l.shapes[segOf(l, zIn, seg)]
  var z = zIn
  if s.closed && s.lengthM > 0 {
    let r = (z - s.startM).truncatingRemainder(dividingBy: s.lengthM)
    z = s.startM + (r < 0 ? r + s.lengthM : r)
  }
  let zs = s.zs, xs = s.xs, ys = s.ys
  let n = zs.count
  guard n >= 2 else { return At(x: xs.first ?? 0, y: ys.first ?? 0, tx: 1, ty: 0) }
  if z <= zs[0] || z >= zs[n - 1] {
    let (a, b) = z <= zs[0] ? (0, 1) : (n - 2, n - 1)
    let h = hypot(xs[b] - xs[a], ys[b] - ys[a])
    let d = h > 0 ? h : 1
    let tx = (xs[b] - xs[a]) / d, ty = (ys[b] - ys[a]) / d
    let (bx, by, over) = z <= zs[0] ? (xs[0], ys[0], z - zs[0]) : (xs[n - 1], ys[n - 1], z - zs[n - 1])
    return At(x: bx + tx * over, y: by + ty * over, tx: tx, ty: ty)
  }
  var lo = 0, hi = n - 1
  while hi - lo > 1 {
    let m = (lo + hi) / 2
    if zs[m] <= z { lo = m } else { hi = m }
  }
  let span = zs[hi] - zs[lo]
  let w = (z - zs[lo]) / (span > 0 ? span : 1)
  let h = hypot(xs[hi] - xs[lo], ys[hi] - ys[lo])
  let d = h > 0 ? h : 1
  return At(
    x: xs[lo] + (xs[hi] - xs[lo]) * w, y: ys[lo] + (ys[hi] - ys[lo]) * w, tx: (xs[hi] - xs[lo]) / d,
    ty: (ys[hi] - ys[lo]) / d)
}

/// The nearest place on the path to model point (x, y): its z and segment.
private func nearest(_ l: WheelLayout, _ x: Double, _ y: Double) -> (Double, Int) {
  var bz = 0.0, bs = 0, bd = Double.greatestFiniteMagnitude
  for (si, s) in l.shapes.enumerated() where s.xs.count >= 2 {
    for i in 1..<s.xs.count {
      let ax = s.xs[i - 1], ay = s.ys[i - 1]
      let dx = s.xs[i] - ax, dy = s.ys[i] - ay
      let l2 = dx * dx + dy * dy > 0 ? dx * dx + dy * dy : 1e-18
      let t = min(max(((x - ax) * dx + (y - ay) * dy) / l2, 0), 1)
      let d = hypot(x - (ax + dx * t), y - (ay + dy * t))
      if d < bd {
        bd = d; bs = si; bz = s.zs[i - 1] + (s.zs[i] - s.zs[i - 1]) * t
      }
    }
  }
  return (bz, bs)
}

/// How far the finger went along the path, the short way round a periodic one.
private func alongPath(_ l: WheelLayout, _ from: Double, _ to: Double) -> Double {
  var d = to - from
  if l.periodic {
    let c = l.extentM
    if d > c / 2 { d -= c } else if d < -c / 2 { d += c }
  }
  return d
}

/// Room around the path for the bars and the note names.
private func margin(_ l: WheelLayout) -> Double { l.notes.isEmpty ? 28 : 44 }

// MARK: the drawing

/// The path, its winding and the notes' names drawn once; the magnets over them at the display's
/// rate (a TimelineView that rests while nothing moves). One finger plays it: the gesture starts
/// on touch-down and keeps the touch (the pager and the page's scroll hold still under it).
private struct Drawing: View {
  let model: RustDJModel
  let l: WheelLayout
  let gear: Double
  @State private var size: CGSize = .zero
  @State private var touch: Touch?
  @GestureState private var pressing = false

  struct Touch {
    var z: Double
    var seg: Int
    var t: Date
    var v: Double
  }

  var body: some View {
    let tall = l.path == "tube" || l.path == "rack" || l.path == "arc"
    let ratio: CGFloat = tall ? 0.9 : (l.path == "rail" || l.path == "incline") ? 2 : 1
    let tracker = model.wheelShared.tracker(for: l)
    ZStack {
      Canvas { ctx, size in drawPath(&ctx, size) }
      TimelineView(.animation(minimumInterval: nil, paused: model.wheelStill)) { _ in
        // a moved-but-still sample (a jump) asks for one frame through `wheelMoved`
        let _ = model.wheelMoved
        Canvas { ctx, size in drawMagnets(&ctx, size, tracker) }
      }
    }
    .aspectRatio(ratio, contentMode: .fit)
    .frame(maxWidth: .infinity, maxHeight: 640)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .updating($pressing) { _, s, _ in s = true }
        .onChanged(moved)
        .onEnded { v in ended(v.time) }
    )
    .onChange(of: pressing) { _, on in
      // a gesture the system took away ends like a finger that stopped
      if !on && touch != nil { ended(nil) }
    }
    .onAppear { model.watchWheel(true) }
    .onDisappear { model.watchWheel(false) }
    .accessibilityElement()
    .accessibilityLabel("\(l.name): \(howToPlay(l))")
    .directTouch()
  }

  private func moved(_ v: DragGesture.Value) {
    let fit = Fit(l, size, margin: margin(l))
    guard var t = touch else {
      model.wheelTouching = true
      let (x0, y0) = fit.model(v.startLocation)
      let (z, seg) = nearest(l, x0, y0)
      if l.cord {
        model.wheelDrive(0)
      } else if l.law == "rail" {
        model.wheelHand(min(max(z, l.loZ), l.hiZ))
      } else if l.law == "gravity" {
        model.wheelPluck(seg)
      } else {
        model.wheelPluck(nil)
      }
      touch = Touch(z: z, seg: seg, t: v.time, v: 0)
      return
    }
    let (x, y) = fit.model(v.location)
    let (z1, s1) = nearest(l, x, y)
    let dt = max(0.001, v.time.timeIntervalSince(t.t))
    if l.cord {
      // geared: a finger moves the cord this many times faster than along the drawing
      t.v = 0.6 * t.v + 0.4 * (alongPath(l, t.z, z1) / dt) * gear
      model.wheelDrive(t.v)
    } else if l.law == "rail" {
      model.wheelHand(min(max(z1, l.loZ), l.hiZ))
    }
    t.z = z1
    t.seg = s1
    t.t = v.time
    touch = t
  }

  /// The finger off at `time` (nil: the gesture was cancelled).
  private func ended(_ time: Date?) {
    guard let t = touch else { return }
    touch = nil
    model.wheelTouching = false
    if l.cord {
      // a flick keeps its speed; a finger that stopped lets it coast
      let flick = time.map { $0.timeIntervalSince(t.t) < 0.08 } ?? false
      model.wheelRelease(flick ? t.v : 0)
    } else if l.law == "rail" {
      model.wheelRelease(nil)
    }
  }

  private func drawPath(_ ctx: inout GraphicsContext, _ size: CGSize) {
    let fit = Fit(l, size, margin: margin(l))
    let track = 6.0
    for s in l.shapes {
      var p = Path()
      for i in s.xs.indices {
        let o = fit.px(s.xs[i], s.ys[i])
        if i == 0 { p.move(to: o) } else { p.addLine(to: o) }
      }
      ctx.stroke(p, with: .color(DJTheme.surface2), style: StrokeStyle(lineWidth: track, lineCap: .round, lineJoin: .round))
    }
    if let pv = l.pivot, pv.count >= 2 {
      let o = fit.px(pv[0], pv[1])
      ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(DJTheme.dim))
    }
    guard !l.shapes.isEmpty else { return }
    // the winding: a bar per section, out for one sense, in for the other
    let most = Double(max(1, l.turns.map { abs(Int($0)) }.max() ?? 1))
    let bar = 14.0
    let half = l.sectionLengthM / 2
    for (i, n) in l.turns.enumerated() where n != 0 {
      let a = at(l, Double(i) * l.sectionLengthM + half)
      let o = fit.px(a.x, a.y)
      // the normal: the tangent turned −90° (outward on the clockwise hoop)
      let sgn = n > 0 ? 1.0 : -1.0
      let nx = a.ty * sgn, ny = -a.tx * sgn
      let from = CGPoint(x: o.x + nx * track / 2, y: o.y + ny * track / 2)
      let len = bar * Double(abs(Int(n))) / most
      var line = Path()
      line.move(to: from)
      line.addLine(to: CGPoint(x: from.x + nx * len, y: from.y + ny * len))
      ctx.stroke(
        line, with: .color(n > 0 ? DJTheme.accent : DJTheme.accent.opacity(0.45)),
        lineWidth: max(1.5, fit.scale * l.sectionLengthM * 0.8))
    }
    // the notes' names, outside their arcs
    for n in l.notes {
      let mid = (Double(n.startSection) + Double(n.count) / 2) * l.sectionLengthM
      let a = at(l, mid, Int(n.segment))
      let o = fit.px(a.x, a.y)
      let off = bar + 16
      ctx.draw(
        Text(n.name).font(.system(size: 11, weight: .medium)).foregroundColor(n.reachable ? DJTheme.dim : DJTheme.danger),
        at: CGPoint(x: o.x + a.ty * off, y: o.y - a.tx * off), anchor: .center)
    }
  }

  private func drawMagnets(_ ctx: inout GraphicsContext, _ size: CGSize, _ tracker: MagnetTracker) {
    guard !l.shapes.isEmpty, let (s, zs) = tracker.frame(monoNs()) else { return }
    let fit = Fit(l, size, margin: margin(l))
    let r = 7.0
    for k in s.z.indices where s.on[k] {
      let a = at(l, zs[k], l.periodic ? nil : s.seg[k])
      let o = fit.px(a.x, a.y)
      for p in [l.pivot, l.anchor] {
        guard let p, p.count >= 2 else { continue }
        var line = Path()
        line.move(to: fit.px(p[0], p[1]))
        line.addLine(to: o)
        ctx.stroke(line, with: .color(DJTheme.dim), lineWidth: 2)
      }
      let c = Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
      ctx.fill(c, with: .color(.white))
      ctx.stroke(c, with: .color(DJTheme.accent), lineWidth: 2)
    }
  }
}

// MARK: the cards

/// How the instrument is played: its motor, the magnets it drops, the pluck.
private struct PlayCard: View {
  let model: RustDJModel
  let l: WheelLayout
  let follow: String

  var body: some View {
    if l.cord {
      Card("Play") {
        ToggleRow(
          title: "Motor", sub: l.motor ? String(format: "Turns it at %.1f m/s", l.speedMps) : "Off: your finger moves it",
          isOn: l.motor
        ) { model.wheelMotor($0, l.speedMps) }
        WheelSlider(title: "Speed", value: String(format: "%.1f m/s", l.speedMps), v: l.speedMps, range: 0.5...20, taper: speedTaper) {
          model.wheelMotor(l.motor, $0)
        }
        // the instruments are wound for 0.8 to 4.5 m/s: the fine slider spans that end
        FineSlider(description: "Speed", value: l.speedMps, range: 0.5...8, caption: "0.5 … 8 m/s, in tenths") {
          model.wheelMotor(l.motor, ($0 * 10).rounded() / 10)
        }
        if l.periodic && !l.notes.isEmpty { SyncSlider(model: model, follow: follow) }
      }
    } else if l.law == "gravity" {
      Card("Play") {
        let tubes = l.shapes.count
        HStack(spacing: 8) {
          ForEach(0..<tubes, id: \.self) { i in
            // a tube's pad is named for its note
            let note = l.notes.first { Int($0.segment) == i }?.name
            WheelPad(label: note ?? (tubes > 1 ? "\(i + 1)" : "Drop")) { model.wheelPluck(i) }
          }
        }
        WheelSlider(
          title: "Drop by itself", value: l.intervalS > 0 ? String(format: "every %.2f s", l.intervalS) : "off",
          v: l.intervalS, range: 0...3, taper: intervalTaper
        ) { model.wheelInterval($0 <= 0 ? 0 : ($0 * 100).rounded() / 100) }
        // drops merge into one sound under ~0.15 s; the rhythms are 0.15 … 1 s
        FineSlider(description: "Drop by itself", value: l.intervalS, range: 0.1...1, caption: "0.1 … 1 s, in hundredths") {
          model.wheelInterval(($0 * 100).rounded() / 100)
        }
      }
    } else if l.law == "pendulum" || l.law == "spring" {
      Card("Play") {
        WheelPad(label: l.law == "pendulum" ? "Swing" : "Pluck") { model.wheelPluck(nil) }
      }
    }
  }
}

/// The wheel's tempo: note onsets a minute at the cord's actual speed (notes round the lap × laps
/// a second × 60), against each deck's BPM. A whole-number multiple or divisor within 1 % is
/// flagged; Sync sets the motor so the wheel settles on the nearest multiple of that deck.
private struct TempoCard: View {
  let model: RustDJModel
  let l: WheelLayout

  var body: some View {
    let state = model.wheelState
    let bpm = state?.bpm
    Card("Tempo") {
      HStack(alignment: .lastTextBaseline, spacing: 0) {
        Text(bpm.map { $0 >= 1 ? String(format: "%.0f", $0) : "–" } ?? "–").font(.system(size: 28, weight: .medium))
          .monospacedDigit()
        Caption(
          l.magnets > 1
            ? "  BPM · \(l.onsetsPerLap) onsets a lap (\(l.notes.count) notes × \(l.magnets) magnets)"
            : "  BPM · \(l.notes.count) notes a lap")
      }
      ForEach(deckNames, id: \.self) { deck in
        TempoRow(model: model, deck: deck, t: state?.tempo.first { $0.deck == deck })
      }
    }
  }
}

private struct TempoRow: View {
  let model: RustDJModel
  let deck: String
  let t: WheelTempo?

  var body: some View {
    HStack(spacing: 4) {
      VStack(alignment: .leading, spacing: 2) {
        Text(t.map { String(format: "Deck \(deck) · %.1f BPM · ×%.2f", $0.deckBpm, $0.ratio) } ?? "Deck \(deck) · nothing loaded")
          .font(.system(size: 14)).foregroundStyle(t == nil ? DJTheme.dim : Color.white).lineLimit(1)
        // one line each, the second always laid out: the card keeps its height as the ratio
        // changes (or first appears)
        let label: String = {
          guard let t else { return " " }
          let rel = t.multiple ? "×" : "÷"
          if t.locked { return "\(rel)\(t.n) — a whole-number \(t.multiple ? "multiple" : "divisor")" }
          return String(format: "near \(rel)\(t.n) (%+.1f%%)", t.error * 100)
        }()
        Text(label).font(.system(size: 12, weight: t?.locked == true ? .medium : .regular))
          .foregroundStyle(t?.locked == true ? DJTheme.accent : DJTheme.dim).lineLimit(1)
      }
      Spacer(minLength: 4)
      // ◀ ×6 ▶: a rung down or up the deck's whole-number multiples (and ½, ⅓, … below ×1), as
      // far as the motor goes
      ArrowButton(system: "chevron.left", enabled: t?.down == true, label: "Wheel a rung slower against deck \(deck)") {
        model.wheelStep(deck, false)
      }
      Text(t.map { rungLabel(Int($0.n), $0.multiple) } ?? "–").font(.system(size: 15, weight: .medium))
        .foregroundStyle(t?.locked == true ? DJTheme.accent : DJTheme.dim).frame(width: 40)
      ArrowButton(system: "chevron.right", enabled: t?.up == true, label: "Wheel a rung faster against deck \(deck)") {
        model.wheelStep(deck, true)
      }
      Button("Sync") { model.wheelSync(deck) }
        .buttonStyle(.plain).font(.system(size: 14, weight: .medium))
        .foregroundStyle(t == nil ? DJTheme.dim : DJTheme.accent)
        .frame(minWidth: 56, minHeight: 44).contentShape(Rectangle())
        .disabled(t == nil)
        .accessibilityLabel("Sync the wheel to deck \(deck)")
    }
  }
}

private struct ArrowButton: View {
  let system: String
  let enabled: Bool
  let label: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: system).font(.system(size: 16, weight: .semibold))
        .foregroundStyle(enabled ? Color.white : DJTheme.dim.opacity(0.5))
        .frame(width: 40, height: 44).contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
  }
}

/// Sync ×: the wheel's tempo as a multiple of the followed deck's, snapped to whole rungs (×1,
/// ×2, …, and ½, ⅓, … below) as it's dragged. It shows where the wheel is, so the arrows and the
/// speed slider move it too; a free speed shows its fractional ratio.
private struct SyncSlider: View {
  let model: RustDJModel
  let follow: String
  /// The rung under the finger while dragging (the wheel takes a moment to get there).
  @State private var drag: Int?

  var body: some View {
    let t = model.wheelState?.tempo.first { $0.deck == follow }
    let lo = t?.rungLo.map(Int.init)
    let hi = t?.rungHi.map(Int.init)
    let ok = t != nil && lo != nil && hi != nil && hi! > lo!
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Sync ×").font(.system(size: 14))
        Spacer()
        ForEach(deckNames, id: \.self) { d in
          let on = d == follow
          Button {
            model.wheelFollow(d)
          } label: {
            Text("Deck \(d)").font(.system(size: 12)).foregroundStyle(on ? Color.black : Color.white)
              .padding(.horizontal, 10).padding(.vertical, 4)
              .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
        let label: String = {
          if let drag { return rungLabel(drag) }
          guard let t else { return "–" }
          return t.locked ? rungLabel(Int(t.n), t.multiple) : String(format: "×%.2f", t.ratio)
        }()
        Text(label).font(.system(size: 14, weight: .medium))
          .foregroundStyle(drag != nil || t?.locked == true ? DJTheme.accent : DJTheme.dim)
          .frame(width: 56, alignment: .trailing)
      }
      // always laid out, disabled with the reason while there's no ladder: the row keeps its
      // height, so the cards under it don't jump when the tempo is first read
      let a = Double(lo ?? 0)
      let b = ok ? Double(hi!) : a + 1
      Slider(
        value: Binding(
          get: { min(max(drag.map(Double.init) ?? t?.place ?? a, a), b) },
          set: { v in
            guard ok else { return }
            let i = min(max(Int(v.rounded()), lo!), hi!)
            if i != drag {
              drag = i
              model.wheelRung(follow, i)
            }
          }),
        in: a...b, step: 1,
        onEditingChanged: { if !$0 { drag = nil } }
      )
      .tint(DJTheme.accent).disabled(!ok)
      .accessibilityLabel("Sync multiple of deck \(follow)")
      let why: String = {
        guard let t else { return "Deck \(follow) has nothing loaded (or the wheel is still)" }
        guard let lo else {
          return String(format: "No whole multiple of deck \(follow)'s %.1f BPM within the motor's speeds", t.deckBpm)
        }
        guard let hi, hi > lo else { return "Only \(rungLabel(lo)) of deck \(follow) is within the motor's speeds" }
        return String(format: "\(rungLabel(lo)) … \(rungLabel(hi)) of deck \(follow)'s %.1f BPM", t.deckBpm)
      }()
      Text(why).font(.system(size: 11)).foregroundStyle(DJTheme.dim).lineLimit(1)
      // fine: ×½ … ×16 on a log scale (each doubling the same travel), the doublings detents
      FineSlider(
        description: "Sync multiple of deck \(follow)",
        value: log2(rungRatio(drag.map(Double.init) ?? t?.place ?? 0)),
        range: -1...4,
        caption: "×½ … ×16, the doublings catch the thumb",
        marks: (-1...4).map { (Double($0), rungLabel(ratioRung(pow(2, Double($0))))) },
        enabled: ok,
        onDone: { drag = nil }
      ) { x in
        guard ok else { return }
        let i = min(max(ratioRung(pow(2, syncDetent(x))), lo!), hi!)
        if i != drag {
          drag = i
          model.wheelRung(follow, i)
        }
      }
    }
  }
}

/// A position on the fine sync slider (log2 of the ratio), caught by a doubling within 0.15.
func syncDetent(_ x: Double) -> Double {
  let k = x.rounded()
  return abs(x - k) < 0.15 ? k : x
}

/// Rung place `p` (×1 at 0, ×(p+1) above, 1/(1−p) below) as a ratio to the deck.
func rungRatio(_ p: Double) -> Double { p >= 0 ? p + 1 : 1 / (1 - p) }

/// The rung nearest ratio `r`: ×n is rung n−1, 1/n is rung 1−n.
func ratioRung(_ r: Double) -> Int { r >= 1 ? Int(r.rounded()) - 1 : 1 - Int((1 / r).rounded()) }

/// Rung `i` of the ladder: ×1 at 0, ×(i+1) above, ½, ⅓, … below.
func rungLabel(_ i: Int) -> String { i >= 0 ? rungLabel(i + 1, true) : rungLabel(1 - i, false) }

/// A rung of the tempo ladder: ×n, or ½, ⅓, … for the divisors.
func rungLabel(_ n: Int, _ multiple: Bool) -> String {
  // just under the deck's tempo reads as 1/1 otherwise: the same rung
  if multiple || n <= 1 { return "×\(max(n, 1))" }
  if (2...10).contains(n) { return String(Array("½⅓¼⅕⅙⅐⅛⅑⅒")[n - 2]) }
  return "1/\(n)"
}

// The Wheel's tapers, from sweeping each knob with the voice rendered (wheel::sweep in djmobile):
// speed and gear are ratios (each doubling a tempo octave, a finger twice as geared); the drop's
// level rises evenly per doubling of the height, the spring's 6 dB per doubling of the pluck; the
// decay is heard from 5 to ~300 ms and barely past that; the drops run into one sound under
// ~0.15 s and are rhythms to about 1 s.
private let speedTaper = LogTaper(lo: 0.5, hi: 20)
private let gearTaper = LogTaper(lo: 1, hi: 20)
private let heightTaper = LogTaper(lo: 0.5, hi: 50)
/// Mass divides the coil's drag: by ratio, like the rest.
private let carrierTaper = LogTaper(lo: 0.5, hi: 100)
/// "sustained" (0) is the stop at the long end, past 1 s.
private let decayTaper = LogTaper(lo: 5, hi: 1000, offAt: 1, off: 0)
/// "off" (0) is the stop at the start.
private let intervalTaper = LogTaper(lo: 0.05, hi: 3, offAt: -1, off: 0)

/// A big tap target (a tube's drop, the pluck): Surface2, an Accent edge.
private struct WheelPad: View {
  let label: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(label).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(DJTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DJTheme.accent.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct InstrumentCard: View {
  let model: RustDJModel
  let presets: [WheelPreset]
  let l: WheelLayout?
  let gear: Double

  var body: some View {
    Card("Instrument") {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
        ForEach(presets, id: \.id) { p in
          let on = p.id == l?.id
          Button {
            model.wheelLoad(p.id)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(p.name).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? Color.black : Color.white)
              Text(lawName(p.law, p.path)).font(.system(size: 11)).foregroundStyle(on ? Color.black : DJTheme.dim)
            }
            .lineLimit(1)
            .padding(12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent.opacity(on ? 1 : 0.3), lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(p.name), \(lawName(p.law, p.path))")
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      if let l {
        SequenceEditor(model: model, l: l).id("\(l.id)|\(l.sequence.isEmpty)")
        BuildKnobs(model: model, l: l, gear: gear)
      }
    }
  }
}

private func lawName(_ law: String, _ path: String) -> String {
  switch law {
  case "drive": "hand-spun \(path)"
  case "motor": "motor \(path)"
  case "bow": "bowed \(path)"
  case "gravity": path == "incline" ? "rolled down a slope" : "dropped down tubes"
  case "pendulum": "a swinging pendulum"
  case "spring": "a magnet on a spring"
  case "rail": "slid by hand"
  default: law
  }
}

private struct Divider1: View {
  var body: some View { Rectangle().fill(DJTheme.dim.opacity(0.3)).frame(height: 1).padding(.top, 4) }
}

/// The web toy's build knobs for this instrument, all live and kept per instrument.
private struct BuildKnobs: View {
  let model: RustDJModel
  let l: WheelLayout
  let gear: Double

  private var knobs: WheelKnobs {
    WheelKnobs(
      magnets: l.magnets, carrierG: l.carrierG, braking: l.braking, releaseM: l.releaseM, loadOhms: l.loadOhms,
      timbre: l.timbre, decayMs: l.decayMs)
  }

  private func set(_ f: (inout WheelKnobs) -> Void) {
    var k = knobs
    f(&k)
    model.wheelKnobs(k)
  }

  var body: some View {
    Divider1()
    Text("Build").font(.system(size: 14, weight: .medium))
    // the free laws but the tubes move one magnet
    if l.cord || l.law == "gravity" {
      StepRow(title: l.cord ? "Magnets on the cord" : "Magnets", value: "\(l.magnets)", label: "Magnets") { d in
        let n = UInt32(min(max(Int(l.magnets) + d, 1), 16))
        if n != l.magnets { set { $0.magnets = n } }
      }
      if l.cord && l.onsetsPerLap > 0 {
        Caption("\(l.notes.count) notes × \(l.magnets) magnet\(l.magnets > 1 ? "s" : ""): \(l.onsetsPerLap) onsets a lap")
      }
    }
    if l.cord {
      WheelSlider(title: "Gear", value: String(format: "×%.1f", gear), v: gear, range: 1...20, taper: gearTaper) {
        model.wheelGear(($0 * 2).rounded() / 2)
      }
    }
    WheelSlider(title: "Carrier", value: String(format: "%.1f g", l.carrierG), v: l.carrierG, range: 0...100, taper: carrierTaper) {
      v in set { $0.carrierG = v < 10 ? (v * 10).rounded() / 10 : v.rounded() }
    }
    ToggleRow(
      title: "Coil drag",
      sub: l.braking ? "The coil's current brakes the motion (Lenz)" : "Off: the motion doesn't feel the coil",
      isOn: l.braking
    ) { on in set { $0.braking = on } }
    switch l.releaseKind {
    case "drop":
      WheelSlider(
        title: "Drop height", value: String(format: "%.1f cm", l.releaseM * 100), v: l.releaseM * 100, range: 0.5...50,
        taper: heightTaper
      ) { v in set { $0.releaseM = ((v * 10).rounded() / 10) / 100 } }
    case "pluck":
      WheelSlider(
        title: "Pluck", value: String(format: "%.1f mm", l.releaseM * 1000), v: l.releaseM * 1000, range: 0.5...50,
        taper: heightTaper
      ) { v in set { $0.releaseM = ((v * 10).rounded() / 10) / 1000 } }
    default: EmptyView()
    }
    let loads: [Double] = [8, 32, 100, 470, 2000, 10000]
    StepRow(title: "Load", value: l.trigger != nil ? "trigger" : ohms(l.loadOhms), label: "Load") { d in
      guard l.trigger == nil else { return }
      let i = loads.firstIndex { $0 >= l.loadOhms - 1e-6 } ?? loads.count - 1
      let j = min(max(i + d, 0), loads.count - 1)
      if loads[j] != l.loadOhms { set { $0.loadOhms = loads[j] } }
    }
    if !l.notes.isEmpty && !l.timbre.isEmpty {
      FlowLayout(spacing: 6) {
        Text("Timbre").font(.system(size: 14)).padding(.trailing, 8).frame(minHeight: 32)
        ForEach(l.timbres, id: \.self) { t in
          Chip(label: t, selected: t == l.timbre) { set { $0.timbre = t } }
        }
      }
      WheelSlider(
        title: "Decay", value: l.decayMs < 1 ? "sustained" : String(format: "%.0f ms", l.decayMs), v: l.decayMs,
        range: 0...1000, taper: decayTaper
      ) { v in set { $0.decayMs = v <= 0 ? 0 : v < 50 ? v.rounded() : (v / 5).rounded() * 5 } }
    }
  }
}

private func presetNotes(_ l: WheelLayout) -> String {
  l.notes.map { n in String(n.name.split(separator: "+").first ?? "").split(separator: "-").first.map(String.init) ?? "" }
    .joined(separator: " ")
}

/// The instrument's note sequence: type the notes the path plays, in order ("C E G B C B G E";
/// octave optional), wound as you type (round a hoop it loops each lap). The chips show how it
/// reads; after winding, the notes as wound.
private struct SequenceEditor: View {
  let model: RustDJModel
  let l: WheelLayout
  @State private var text: String

  init(model: RustDJModel, l: WheelLayout) {
    self.model = model
    self.l = l
    _text = State(initialValue: l.sequence.isEmpty ? presetNotes(l) : l.sequence)
  }

  var body: some View {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let wound = !l.sequence.isEmpty && trimmed == l.sequence
    let parsed = model.wheelParse(text, l.root)
    Divider1()
    Text("Note sequence").font(.system(size: 14, weight: .medium))
    Caption(
      "The notes the path plays, in order, wound as you type; round a hoop it loops each lap. Octave optional: C E G B C rises to the octave above."
    )
    TextField("notes", text: $text)
      .font(.system(size: 15, design: .monospaced))
      .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.characters)
      #endif
      .submitLabel(.done)
      .onSubmit { if case .success = parsed { model.wheelSequence(text) } }
      .padding(.horizontal, 12).frame(minHeight: 44)
      .background(DJTheme.surface0, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(DJTheme.dim.opacity(0.5)))
      .accessibilityLabel("Note sequence")
      // wound as typed: once the field reads as notes and has paused a moment (a few ms to wind;
      // it crossfades in while the wheel plays)
      .task(id: "\(text)|\(l.root)") {
        guard case .success = parsed, !wound, !trimmed.isEmpty else { return }
        if l.sequence.isEmpty && trimmed == presetNotes(l) { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        model.wheelSequence(text)
      }
    FlowLayout(spacing: 4) {
      switch parsed {
      // a blank field (the rail and the spring have no notes) is not a mistake to point at
      case .failure(let e) where !trimmed.isEmpty:
        Text(djMessage(e)).font(.system(size: 12)).foregroundStyle(DJTheme.danger)
      case .failure:
        EmptyView()
      case .success(let names):
        if wound {
          ForEach(Array(l.notes.suffix(names.count).enumerated()), id: \.offset) { _, n in
            NoteChip(name: n.name, color: n.reachable ? DJTheme.accent : DJTheme.danger, solid: true)
          }
        } else {
          ForEach(Array(names.enumerated()), id: \.offset) { _, n in NoteChip(name: n, color: DJTheme.dim, solid: false) }
        }
      }
    }
    Button("Preset's notes") { model.wheelPresetNotes() }
      .buttonStyle(.plain).font(.system(size: 14, weight: .medium))
      .foregroundStyle(l.sequence.isEmpty ? DJTheme.dim : DJTheme.accent)
      .frame(minHeight: 44).disabled(l.sequence.isEmpty)
  }
}

private struct NoteChip: View {
  let name: String
  let color: Color
  let solid: Bool
  var body: some View {
    Text(name).font(.system(size: 12)).foregroundStyle(solid ? Color.black : color)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(solid ? color : .clear, in: Capsule())
      .overlay(Capsule().stroke(color, lineWidth: 1))
  }
}

private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

/// "E3" → 52 (MIDI); "Bb2" and "C#4" too. Nil for anything else.
private func midiOf(_ name: String) -> Int? {
  let s = name.trimmingCharacters(in: .whitespaces)
  guard let first = s.first, let deg = "CDEFGAB".firstIndex(of: Character(first.uppercased())) else { return nil }
  var rest = s.dropFirst()
  var acc = 0
  if rest.first == "#" { acc = 1; rest = rest.dropFirst() } else if rest.first == "b" { acc = -1; rest = rest.dropFirst() }
  guard let oct = Int(rest) else { return nil }
  let base = [0, 2, 4, 5, 7, 9, 11]["CDEFGAB".distance(from: "CDEFGAB".startIndex, to: deg)]
  return (oct + 1) * 12 + base + acc
}

private func nameOf(_ midi: Int) -> String {
  let pc = ((midi % 12) + 12) % 12
  let oct = Int((Double(midi) / 12).rounded(.down)) - 1
  return noteNames[pc] + "\(oct)"
}

/// The key: the root the notes are wound around, and a transposition; each change re-winds.
private struct KeyCard: View {
  let model: RustDJModel
  let l: WheelLayout
  // the steppers move a draft; the re-wind (a few ms) follows a burst of taps
  @State private var root: String
  @State private var transpose: Int32

  init(model: RustDJModel, l: WheelLayout) {
    self.model = model
    self.l = l
    _root = State(initialValue: l.root)
    _transpose = State(initialValue: l.transpose)
  }

  var body: some View {
    Card("Key") {
      StepRow(title: "Root", value: root, label: "Root note") { d in
        if let m = midiOf(root) { root = nameOf(min(max(m + d, 24), 84)) }
      }
      StepRow(title: "Transpose", value: String(format: "%+d", transpose), label: "Transpose") { d in
        transpose = min(max(transpose + Int32(d), -24), 24)
      }
      let far = l.outOfReach
      Text(
        far > 0
          ? "\(far) note\(far > 1 ? "s" : "") past this coil's reach · lower the key or brighten"
          : "Every note is re-wound for the key you set"
      )
      .font(.system(size: 12)).foregroundStyle(far > 0 ? DJTheme.danger : DJTheme.dim).lineLimit(1)
    }
    .task(id: "\(root)|\(transpose)") {
      guard root != l.root || transpose != l.transpose else { return }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      model.wheelKey(root, transpose)
    }
  }
}

/// − value +: a title, and steppers either side of the value.
private struct StepRow: View {
  let title: String
  let value: String
  let label: String
  let step: (Int) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Text(title).font(.system(size: 14))
      Spacer()
      stepButton("minus", -1, "\(label) down")
      Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit().lineLimit(1).frame(minWidth: 64)
      stepButton("plus", 1, "\(label) up")
    }
  }

  private func stepButton(_ icon: String, _ d: Int, _ a11y: String) -> some View {
    Button {
      step(d)
    } label: {
      Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(DJTheme.accent)
        .frame(width: 48, height: 48).contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel(a11y)
  }
}

/// Brightness (the coil and magnet sizes), the level, the trigger and the output meter.
private struct WheelSoundCard: View {
  let model: RustDJModel
  let l: WheelLayout
  @State private var bright: Double

  init(model: RustDJModel, l: WheelLayout) {
    self.model = model
    self.l = l
    _bright = State(initialValue: l.brightness)
  }

  var body: some View {
    let s = model.wheelState
    Card("Sound") {
      WheelSlider(
        title: "Brightness", value: String(format: "coil %.1f mm · magnet %.1f mm", l.coilRadiusMm, l.magnetMm), v: bright,
        range: 0...1
      ) {
        bright = $0
        model.wheelBrightness($0)  // live: the coil re-winds as the slider moves
      }
      WheelSlider(title: "Level", value: String(format: "%+.0f dB", l.volumeDb), v: l.volumeDb, range: -20...40) {
        model.wheelVolume($0.rounded())
      }
      ToggleRow(
        title: "Trigger",
        sub: l.trigger != nil ? "A load across the coil: open · matched · short" : "Off: the coil drives its \(ohms(l.loadOhms)) load",
        isOn: l.trigger != nil
      ) { model.wheelTrigger($0 ? 0.5 : nil) }
      // always laid out (greyed while off): the card keeps its height when the trigger comes on
      WheelSlider(
        title: "Pull", value: l.trigger.map(pullName) ?? "turn the trigger on first", v: l.trigger ?? 0, range: 0...1,
        enabled: l.trigger != nil
      ) { model.wheelTrigger($0) }
      // the pull is heard from about ¼ to ¾ (−17 dB … matched … −17 dB); near the ends it's near silent
      FineSlider(
        description: "Pull", value: l.trigger ?? 0.5, range: 0.25...0.75, caption: "¼ … ¾, matched in the middle",
        enabled: l.trigger != nil
      ) { model.wheelTrigger($0) }
      Meter(label: "out", level: Float(s?.outPeak ?? 0))
      Text(s.map { String(format: "%.1f m/s · drag %.2f N · %.1f mW", abs($0.speedMps), $0.dragN, $0.powerMw) } ?? " ")
        .font(.system(size: 11)).foregroundStyle(DJTheme.dim).monospacedDigit()
      Dropouts(s: s)
    }
  }
}

/// The wheel's feed into its strip, live: dropouts (the strip ran dry and played silence; it
/// skipped ahead on an overfull ring) since the app started, and over the last second the least
/// the ring held and the biggest block the output took at once. Red once anything has dropped out.
private struct Dropouts: View {
  let s: WheelState?
  // the poll's low / block are since the last poll (~33 ms): held over a second here
  @State private var held = (t0: Int64(0), low: Double.greatestFiniteMagnitude, block: 0.0)
  @State private var shown = (low: 0.0, block: 0.0)

  var body: some View {
    let bad = s.map { $0.underruns > 0 || $0.skips > 0 } ?? false
    Text(
      s.map {
        String(
          format: "dropouts \($0.underruns) · skips \($0.skips) · ring low %.1f ms · block %.1f ms · kept %.0f ms",
          shown.low, shown.block, $0.ringTargetMs)
      } ?? " "
    )
    .font(.system(size: 11)).foregroundStyle(bad ? DJTheme.danger : DJTheme.dim).monospacedDigit()
    .accessibilityLabel("Wheel dropouts")
    .onChange(of: s) { _, s in
      guard let s else { return }
      let now = monoNs()
      var h = held
      if h.t0 == 0 { h.t0 = now }
      h.low = min(h.low, s.ringLowMs)
      h.block = max(h.block, s.blockMs)
      if now - h.t0 >= 1_000_000_000 {
        shown = (h.low == .greatestFiniteMagnitude ? 0 : h.low, h.block)
        h = (now, .greatestFiniteMagnitude, 0)
      }
      held = h
    }
  }
}

private func ohms(_ r: Double) -> String { r >= 1000 ? String(format: "%.0f kΩ", r / 1000) : String(format: "%.0f Ω", r) }

private func pullName(_ p: Double) -> String {
  if p <= 0.02 { return "open: silent, no drag" }
  if p >= 0.98 { return "short: silent, full brake" }
  if abs(p - 0.5) < 0.06 { return "matched: loudest" }
  return p < 0.5 ? "light: quiet, little drag" : "heavy: quiet, strong brake"
}

/// A slider with its title and value on a line above (djandroid LabeledSlider), on a taper over
/// `range` (linear without one).
private struct WheelSlider: View {
  let title: String
  let value: String
  let v: Double
  let range: ClosedRange<Double>
  var enabled = true
  var taper: Taper?
  var onDone: (() -> Void)?
  let onChange: (Double) -> Void

  var body: some View {
    let t: Taper = taper ?? LinearTaper(lo: range.lowerBound, hi: range.upperBound)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(title).font(.system(size: 14)).foregroundStyle(enabled ? Color.white : DJTheme.dim)
        Spacer()
        Text(value).font(.system(size: 12)).foregroundStyle(DJTheme.dim).lineLimit(1)
      }
      Slider(
        value: Binding(get: { min(max(t.toPos(v), 0), 1) }, set: { onChange(t.fromPos($0)) }),
        in: 0...1,
        onEditingChanged: { if !$0 { onDone?() } }
      )
      .tint(enabled ? DJTheme.accent : DJTheme.dim)
      .disabled(!enabled)
      .accessibilityLabel(title).accessibilityValue(value)
    }
  }
}

extension View {
  /// VoiceOver passes touches on the drawing straight through (it is played, not read).
  @ViewBuilder func directTouch() -> some View {
    #if os(iOS)
      accessibilityAddTraits(.allowsDirectInteraction)
    #else
      self
    #endif
  }
}
