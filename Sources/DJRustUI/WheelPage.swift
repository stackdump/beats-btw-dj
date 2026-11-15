import DJRust
import SwiftUI

// The wheel (djandroid ui/WheelPage.kt): windwheel's linear tonewheel, magnets moved past a coil
// wound in a pattern, played beside the decks. Its sound is an input strip of the engine's, so it
// plays in the mix (and the vocoder can take it as its modulator).
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
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20))
              .foregroundStyle(playing ? DJTheme.dim : DJTheme.accent).frame(width: 48, height: 48)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(playing ? "Pause the wheel" : "Play the wheel")
        }
      ) {
        if let l {
          Caption(howToPlay(l)).lineLimit(1)
          WheelDrawing(model: model, l: l, gear: w.gear)
            .id("\(l.id)|\(l.periodic)|\(l.extentM)")
        } else {
          Caption("winding the instrument…")
        }
      }
      if let l { PlayCard(model: model, l: l, follow: w.follow) }
      if let l, l.cord, l.periodic, !l.notes.isEmpty { TempoCard(model: model, l: l) }
      if !w.presets.isEmpty { InstrumentCard(model: model, l: l) }
      if let l {
        KeyCard(model: model, l: l).id(l.id)
        WheelSoundCard(model: model, l: l)
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

// MARK: the path's geometry

/// Model metres → view points: the path's box fitted inside the view with a margin.
private struct Fit {
  let scale: Double
  private let ox: Double, oy: Double

  init(_ l: WheelLayout, _ size: CGSize) {
    let margin: Double = l.notes.isEmpty ? 28 : 44
    var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
    var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
    func grow(_ x: Double, _ y: Double) {
      x0 = min(x0, x)
      y0 = min(y0, y)
      x1 = max(x1, x)
      y1 = max(y1, y)
    }
    for s in l.shapes { for i in s.xs.indices { grow(s.xs[i], s.ys[i]) } }
    if let p = l.pivot, p.count >= 2 { grow(p[0], p[1]) }
    if let a = l.anchor, a.count >= 2 { grow(a[0], a[1]) }
    if x0 > x1 { (x0, y0, x1, y1) = (0, 0, 1, 1) }
    let bw = max(x1 - x0, 1e-6), bh = max(y1 - y0, 1e-6)
    // a straight path has no extent across it: the other dimension sets the scale
    scale = min((size.width - 2 * margin) / bw, (size.height - 2 * margin) / bh)
    ox = size.width / 2 - scale * (x0 + x1) / 2
    oy = size.height / 2 - scale * (y0 + y1) / 2
  }

  func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + scale * x, y: oy + scale * y) }
  func model(_ p: CGPoint) -> (Double, Double) { ((p.x - ox) / scale, (p.y - oy) / scale) }
}

/// A point on the path and its unit tangent.
private struct At {
  var x: Double, y: Double, tx: Double, ty: Double
}

/// The segment holding z (a periodic path's z wraps); `seg` when it is a valid hint.
private func segOf(_ l: WheelLayout, _ z: Double, _ seg: Int?) -> Int {
  if let seg, l.shapes.indices.contains(seg) { return seg }
  if l.periodic { return 0 }
  var best = 0, bd = Double.greatestFiniteMagnitude
  for (i, s) in l.shapes.enumerated() {
    let d = z < s.startM ? s.startM - z : z > s.startM + s.lengthM ? z - s.startM - s.lengthM : 0
    if d < bd {
      bd = d
      best = i
    }
  }
  return best
}

/// Where z is on the drawing (extrapolated past an open segment's ends).
private func at(_ l: WheelLayout, _ zIn: Double, _ seg: Int? = nil) -> At {
  let s = l.shapes[segOf(l, zIn, seg)]
  var z = zIn
  if s.closed && s.lengthM > 0 {
    z = s.startM + ((z - s.startM).truncatingRemainder(dividingBy: s.lengthM) + s.lengthM)
      .truncatingRemainder(dividingBy: s.lengthM)
  }
  let zs = s.zs, xs = s.xs, ys = s.ys
  let n = zs.count
  guard n >= 2 else { return At(x: xs.first ?? 0, y: ys.first ?? 0, tx: 1, ty: 0) }
  if z <= zs[0] || z >= zs[n - 1] {
    let (a, b) = z <= zs[0] ? (0, 1) : (n - 2, n - 1)
    let d0 = hypot(xs[b] - xs[a], ys[b] - ys[a])
    let d = d0 > 0 ? d0 : 1
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
  let d0 = hypot(xs[hi] - xs[lo], ys[hi] - ys[lo])
  let d = d0 > 0 ? d0 : 1
  return At(
    x: xs[lo] + (xs[hi] - xs[lo]) * w, y: ys[lo] + (ys[hi] - ys[lo]) * w, tx: (xs[hi] - xs[lo]) / d,
    ty: (ys[hi] - ys[lo]) / d)
}

/// The nearest place on the path to model point (x, y): its z and segment.
private func nearest(_ l: WheelLayout, _ x: Double, _ y: Double) -> (Double, Int) {
  var bz = 0.0, bs = 0, bd = Double.greatestFiniteMagnitude
  for (si, s) in l.shapes.enumerated() {
    for i in s.xs.indices.dropFirst() {
      let ax = s.xs[i - 1], ay = s.ys[i - 1]
      let dx = s.xs[i] - ax, dy = s.ys[i] - ay
      let l2 = dx * dx + dy * dy > 0 ? dx * dx + dy * dy : 1e-18
      let t = min(max(((x - ax) * dx + (y - ay) * dy) / l2, 0), 1)
      let d = hypot(x - (ax + dx * t), y - (ay + dy * t))
      if d < bd {
        bd = d
        bs = si
        bz = s.zs[i - 1] + (s.zs[i] - s.zs[i - 1]) * t
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

// MARK: the drawing

/// A finger on the drawing: where it is on the path and how fast it moves it.
private final class DragTrack {
  var active = false
  var z = 0.0
  var seg = 0
  var t = Date.distantPast
  var v = 0.0
}

/// The path, its winding (a bar per section: out for one sense, in for the other), the notes'
/// names, and the magnets. The magnets move at the display's rate: a TimelineView reads the
/// tracker, which moves them on between polls on the voice's clock; the path, the winding and
/// the names are their own Canvas, drawn once per layout.
struct WheelDrawing: View {
  let model: RustDJModel
  let l: WheelLayout
  let gear: Double
  @State private var tracker: MagnetTracker
  @State private var drag = DragTrack()

  init(model: RustDJModel, l: WheelLayout, gear: Double) {
    self.model = model
    self.l = l
    self.gear = gear
    _tracker = State(initialValue: MagnetTracker(extent: l.periodic ? l.extentM : 0))
  }

  private var ratio: CGFloat {
    switch l.path {
    case "tube", "rack", "arc": 0.9
    case "rail", "incline": 2
    default: 1
    }
  }

  var body: some View {
    GeometryReader { g in
      ZStack {
        Canvas { ctx, size in drawPath(&ctx, size) }
        TimelineView(.animation) { tl in
          Canvas { ctx, size in drawMagnets(&ctx, size, tl.date.timeIntervalSinceReferenceDate) }
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in moved(v, Fit(l, g.size)) }
          .onEnded { v in lifted(v) }
      )
    }
    .aspectRatio(ratio, contentMode: .fit)
    .onAppear { model.wheelFeed.watch(true) }
    .onDisappear { model.wheelFeed.watch(false) }
    .accessibilityElement()
    .accessibilityLabel("\(l.name): \(howToPlay(l))")
    .accessibilityAddTraits(.allowsDirectInteraction)
  }

  private func moved(_ v: DragGesture.Value, _ fit: Fit) {
    if !drag.active {
      drag.active = true
      let (x0, y0) = fit.model(v.startLocation)
      (drag.z, drag.seg) = nearest(l, x0, y0)
      drag.t = v.time
      drag.v = 0
      if l.cord {
        model.wheelDrive(0)
      } else if l.law == "rail" {
        model.wheelHand(min(max(drag.z, l.loZ), l.hiZ))
      } else if l.law == "gravity" {
        model.wheelPluck(drag.seg)
      } else {
        model.wheelPluck(nil)
      }
      return
    }
    let (x, y) = fit.model(v.location)
    let (z1, s1) = nearest(l, x, y)
    let dt = max(0.001, v.time.timeIntervalSince(drag.t))
    if l.cord {
      // geared: a finger moves the cord this many times faster than along the drawing
      drag.v = 0.6 * drag.v + 0.4 * (alongPath(l, drag.z, z1) / dt) * gear
      model.wheelDrive(drag.v)
    } else if l.law == "rail" {
      model.wheelHand(min(max(z1, l.loZ), l.hiZ))
    }
    drag.z = z1
    drag.seg = s1
    drag.t = v.time
  }

  private func lifted(_ v: DragGesture.Value) {
    // a flick keeps its speed; a finger that stopped lets it coast
    if l.cord {
      model.wheelRelease(v.time.timeIntervalSince(drag.t) < 0.08 ? drag.v : 0)
    } else if l.law == "rail" {
      model.wheelRelease(nil)
    }
    drag.active = false
  }

  private func drawPath(_ ctx: inout GraphicsContext, _ size: CGSize) {
    guard !l.shapes.isEmpty else { return }
    let fit = Fit(l, size)
    let track: CGFloat = 6
    for s in l.shapes {
      var p = Path()
      for i in s.xs.indices {
        let o = fit.pt(s.xs[i], s.ys[i])
        if i == 0 { p.move(to: o) } else { p.addLine(to: o) }
      }
      ctx.stroke(p, with: .color(DJTheme.surface2), style: StrokeStyle(lineWidth: track, lineCap: .round, lineJoin: .round))
    }
    if let pv = l.pivot, pv.count >= 2 {
      let o = fit.pt(pv[0], pv[1])
      ctx.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(DJTheme.dim))
    }
    let most = max(1, l.turns.map { abs(Int($0)) }.max() ?? 1)
    let bar: CGFloat = 14
    let half = l.sectionLengthM / 2
    for (i, n) in l.turns.enumerated() where n != 0 {
      let a = at(l, Double(i) * l.sectionLengthM + half)
      let o = fit.pt(a.x, a.y)
      // the normal: the tangent turned −90° (outward on the clockwise hoop)
      let sgn: Double = n > 0 ? 1 : -1
      let nx = a.ty * sgn, ny = -a.tx * sgn
      let from = CGPoint(x: o.x + nx * track / 2, y: o.y + ny * track / 2)
      let len = bar * CGFloat(abs(Int(n))) / CGFloat(most)
      var p = Path()
      p.move(to: from)
      p.addLine(to: CGPoint(x: from.x + nx * len, y: from.y + ny * len))
      ctx.stroke(
        p, with: .color(n > 0 ? DJTheme.accent : DJTheme.accent.opacity(0.45)),
        lineWidth: max(1.5, fit.scale * l.sectionLengthM * 0.8))
    }
    // the notes' names, outside their arcs
    for n in l.notes {
      let mid = (Double(n.startSection) + Double(n.count) / 2) * l.sectionLengthM
      let a = at(l, mid, Int(n.segment))
      let o = fit.pt(a.x, a.y)
      let off = bar + 16
      ctx.draw(
        Text(n.name).font(.system(size: 11, weight: .medium)).foregroundStyle(n.reachable ? DJTheme.dim : DJTheme.danger),
        at: CGPoint(x: o.x + a.ty * off, y: o.y - a.tx * off))
    }
  }

  private func drawMagnets(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
    if let s = model.wheelFeed.sample, s.seq != tracker.sample?.seq { tracker.feed(s) }
    guard let s = tracker.sample, !l.shapes.isEmpty else { return }
    let fit = Fit(l, size)
    let r: CGFloat = 7
    for k in s.z.indices where s.on[k] {
      let a = at(l, tracker.z(k, t), l.periodic ? nil : s.seg[k])
      let o = fit.pt(a.x, a.y)
      for end in [l.pivot, l.anchor] {
        guard let e = end, e.count >= 2 else { continue }
        var p = Path()
        p.move(to: fit.pt(e[0], e[1]))
        p.addLine(to: o)
        ctx.stroke(p, with: .color(DJTheme.dim), lineWidth: 2)
      }
      let c = Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: 2 * r, height: 2 * r))
      ctx.fill(c, with: .color(.white))
      ctx.stroke(c, with: .color(DJTheme.accent), lineWidth: 2)
    }
  }
}

// MARK: tapers and rungs

// The Wheel's tapers, from sweeping each knob with the voice rendered (wheel::sweep in djmobile):
// speed and gear are ratios; the drop's level rises evenly per doubling of the height, the
// spring's 6 dB per doubling of the pluck; the decay is heard from 5 to ~300 ms; the drops run
// into one sound under ~0.15 s and are rhythms to about 1 s.
private let speedTaper = LogTaper(lo: 0.5, hi: 20)
private let gearTaper = LogTaper(lo: 1, hi: 20)
private let heightTaper = LogTaper(lo: 0.5, hi: 50)
/// Mass divides the coil's drag: by ratio, like the rest.
private let carrierTaper = LogTaper(lo: 0.5, hi: 100)
/// "sustained" (0) is the stop at the long end, past 1 s.
private let decayTaper = LogTaper(lo: 5, hi: 1000, offAt: 1, off: 0)
/// "off" (0) is the stop at the start.
private let intervalTaper = LogTaper(lo: 0.05, hi: 3, offAt: -1, off: 0)

/// Rung place `p` (×1 at 0, ×(p+1) above, 1/(1−p) below) as a ratio to the deck.
func rungRatio(_ p: Double) -> Double { p >= 0 ? p + 1 : 1 / (1 - p) }

/// The rung nearest ratio `r`: ×n is rung n−1, 1/n is rung 1−n.
func ratioRung(_ r: Double) -> Int { r >= 1 ? Int(r.rounded()) - 1 : 1 - Int((1 / r).rounded()) }

/// A position on the fine sync slider (log2 of the ratio), caught by a doubling within 0.15.
func syncDetent(_ x: Double) -> Double {
  let k = x.rounded()
  return abs(x - k) < 0.15 ? k : x
}

/// Rung `i` of the ladder: ×1 at 0, ×(i+1) above, ½, ⅓, … below.
func rungLabel(_ i: Int) -> String { i >= 0 ? rungLabel(i + 1, multiple: true) : rungLabel(1 - i, multiple: false) }

/// A rung of the tempo ladder: ×n, or ½, ⅓, … for the divisors.
func rungLabel(_ n: Int, multiple: Bool) -> String {
  // just under the deck's tempo reads as 1/1 otherwise: the same rung
  if multiple || n <= 1 { return "×\(max(n, 1))" }
  if (2...10).contains(n) { return String(Array("½⅓¼⅕⅙⅐⅛⅑⅒")[n - 2]) }
  return "1/\(n)"
}

private func ohms(_ r: Double) -> String { r >= 1000 ? String(format: "%.0f kΩ", r / 1000) : String(format: "%.0f Ω", r) }

private func pullName(_ p: Double) -> String {
  if p <= 0.02 { return "open: silent, no drag" }
  if p >= 0.98 { return "short: silent, full brake" }
  if abs(p - 0.5) < 0.06 { return "matched: loudest" }
  return p < 0.5 ? "light: quiet, little drag" : "heavy: quiet, strong brake"
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

// MARK: small controls

/// A title, its value on the right, and a slider on an optional taper over `range`.
struct LabeledSlider: View {
  let title: String
  let value: String
  let v: Double
  let range: ClosedRange<Double>
  var enabled = true
  var taper: Taper?
  var onDone: (() -> Void)?
  let onChange: (Double) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(title).font(.system(size: 14)).foregroundStyle(enabled ? Color.white : DJTheme.dim)
        Spacer()
        Caption(value).lineLimit(1)
      }
      Slider(
        value: Binding(
          get: { taper?.toPos(v) ?? min(max(v, range.lowerBound), range.upperBound) },
          set: { p in onChange(taper?.fromPos(p) ?? p) }),
        in: taper != nil ? 0...1 : range,
        onEditingChanged: { if !$0 { onDone?() } }
      )
      .disabled(!enabled)
      .accessibilityLabel(title).accessibilityValue(value)
    }
  }
}

/// − value + with a title: a knob in steps.
struct WheelStepper: View {
  let title: String
  let value: String
  let label: String
  let step: (Int) -> Void

  var body: some View {
    HStack(spacing: 0) {
      Text(title).font(.system(size: 14))
      Spacer()
      Button {
        step(-1)
      } label: {
        Image(systemName: "minus").foregroundStyle(DJTheme.accent).frame(width: 48, height: 48).contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("\(label) down")
      Text(value).font(.system(size: 17, weight: .medium)).frame(width: 64)
      Button {
        step(1)
      } label: {
        Image(systemName: "plus").foregroundStyle(DJTheme.accent).frame(width: 48, height: 48).contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("\(label) up")
    }
  }
}

private struct WheelPad: View {
  let label: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(label).font(.system(size: 17, weight: .medium)).foregroundStyle(.white).lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(DJTheme.surface2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DJTheme.accent.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct Divider1: View {
  var body: some View { Rectangle().fill(DJTheme.dim.opacity(0.3)).frame(height: 1).padding(.top, 4) }
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
        LabeledSlider(
          title: "Speed", value: String(format: "%.1f m/s", l.speedMps), v: l.speedMps, range: 0.5...20, taper: speedTaper
        ) { model.wheelMotor(l.motor, $0) }
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
        LabeledSlider(
          title: "Drop by itself", value: l.intervalS > 0 ? String(format: "every %.2f s", l.intervalS) : "off",
          v: l.intervalS, range: 0...3, taper: intervalTaper
        ) { model.wheelInterval($0 <= 0 ? 0 : ($0 * 100).rounded() / 100) }
        // drops merge into one sound under ~0.15 s; the rhythms are 0.15 … 1 s
        FineSlider(description: "Drop by itself", value: l.intervalS, range: 0.1...1, caption: "0.1 … 1 s, in hundredths") {
          model.wheelInterval(($0 * 100).rounded() / 100)
        }
      }
    } else if l.law == "pendulum" || l.law == "spring" {
      Card("Play") { WheelPad(label: l.law == "pendulum" ? "Swing" : "Pluck") { model.wheelPluck(nil) } }
    }
  }
}

/// Sync ×: the wheel's tempo as a multiple of the followed deck's, snapped to whole rungs (×1,
/// ×2, …, and ½, ⅓, … below) as it's dragged. A free speed shows its fractional ratio.
private struct SyncSlider: View {
  let model: RustDJModel
  let follow: String
  /// The rung under the finger while dragging (the wheel takes a moment to get there).
  @State private var drag: Int?

  var body: some View {
    let t = model.wheelState?.tempo.first { $0.deck == follow }
    let lo = t?.rungLo.map(Int.init)
    let hi = t?.rungHi.map(Int.init)
    // always laid out, disabled with the reason while there's no ladder: the row keeps its height
    let ok = t != nil && lo != nil && hi != nil && hi! > lo!
    let why: String? =
      if t == nil {
        "Deck \(follow) has nothing loaded (or the wheel is still)"
      } else if lo == nil {
        String(format: "No whole multiple of deck \(follow)'s %.1f BPM within the motor's speeds", t!.deckBpm)
      } else if hi == nil || hi! <= lo! {
        "Only \(rungLabel(lo!)) of deck \(follow) is within the motor's speeds"
      } else { nil }
    let label =
      if let d = drag { rungLabel(d) } else if let t { t.locked ? rungLabel(Int(t.n), multiple: t.multiple) : String(format: "×%.2f", t.ratio) } else { "–" }
    let a = Double(lo ?? 0)
    let b = ok ? Double(hi!) : a + 1
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Sync ×").font(.system(size: 14))
        Spacer()
        ForEach(deckNames, id: \.self) { d in
          Chip(label: "Deck \(d)", selected: d == follow) { model.wheelFollow(d) }
        }
        Text(label).font(.system(size: 14, weight: .medium))
          .foregroundStyle(drag != nil || t?.locked == true ? DJTheme.accent : DJTheme.dim)
          .frame(width: 52, alignment: .trailing)
      }
      Slider(
        value: Binding(
          get: { min(max(drag.map(Double.init) ?? t?.place ?? a, a), b) },
          set: { x in
            guard ok else { return }
            let i = min(max(Int(x.rounded()), lo!), hi!)
            if i != drag {
              drag = i
              model.wheelRung(follow, i)
            }
          }),
        in: a...b, onEditingChanged: { if !$0 { drag = nil } }
      )
      .disabled(!ok)
      .accessibilityLabel("Sync multiple of deck \(follow)").accessibilityValue(label)
      Caption(why ?? String(format: "\(rungLabel(lo!)) … \(rungLabel(hi!)) of deck \(follow)'s %.1f BPM", t!.deckBpm))
        .lineLimit(1)
      // fine: ×½ … ×16 on a log scale (each doubling the same travel), the doublings detents
      FineSlider(
        description: "Sync multiple of deck \(follow)",
        value: log2(rungRatio(drag.map(Double.init) ?? t?.place ?? 0)), range: -1...4,
        caption: "×½ … ×16, the doublings catch the thumb", enabled: ok,
        marks: (-1...4).map { (Double($0), rungLabel(ratioRung(pow(2, Double($0))))) },
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

/// The wheel's tempo: note onsets a minute at the cord's actual speed, against each deck's BPM.
/// A whole-number multiple or divisor within 1 % is flagged; Sync sets the motor so the wheel
/// settles on the nearest multiple of that deck.
private struct TempoCard: View {
  let model: RustDJModel
  let l: WheelLayout

  var body: some View {
    let s = model.wheelState
    Card("Tempo") {
      HStack(alignment: .lastTextBaseline, spacing: 0) {
        Text(s?.bpm.flatMap { $0 >= 1 ? String(format: "%.0f", $0) : nil } ?? "–").font(.system(size: 28, weight: .medium))
        Caption(
          l.magnets > 1
            ? "  BPM · \(l.onsetsPerLap) onsets a lap (\(l.notes.count) notes × \(l.magnets) magnets)"
            : "  BPM · \(l.notes.count) notes a lap")
      }
      ForEach(deckNames, id: \.self) { deck in
        let t = s?.tempo.first { $0.deck == deck }
        HStack(spacing: 4) {
          VStack(alignment: .leading, spacing: 2) {
            Text(t.map { String(format: "Deck \(deck) · %.1f BPM · ×%.2f", $0.deckBpm, $0.ratio) } ?? "Deck \(deck) · nothing loaded")
              .font(.system(size: 14)).foregroundStyle(t == nil ? DJTheme.dim : .white).lineLimit(1)
            // one line each, the second always laid out: the card keeps its height
            let label: String =
              if let t {
                t.locked
                  ? "\(t.multiple ? "×" : "÷")\(t.n) — a whole-number \(t.multiple ? "multiple" : "divisor")"
                  : String(format: "near \(t.multiple ? "×" : "÷")\(t.n) (%+.1f%%)", t.error * 100)
              } else { " " }
            Text(label).font(.system(size: 12, weight: t?.locked == true ? .medium : .regular))
              .foregroundStyle(t?.locked == true ? DJTheme.accent : DJTheme.dim).lineLimit(1)
          }
          Spacer()
          // ◀ ×6 ▶: a rung down or up the deck's whole-number multiples (½, ⅓, … below ×1)
          Button {
            model.wheelStep(deck, false)
          } label: {
            Image(systemName: "chevron.left").frame(width: 40, height: 44).contentShape(Rectangle())
          }
          .buttonStyle(.plain).foregroundStyle(t?.down == true ? Color.white : DJTheme.dim).disabled(t?.down != true)
          .accessibilityLabel("Wheel a rung slower against deck \(deck)")
          Text(t.map { rungLabel(Int($0.n), multiple: $0.multiple) } ?? "–").font(.system(size: 15, weight: .medium))
            .foregroundStyle(t?.locked == true ? DJTheme.accent : DJTheme.dim).frame(width: 36)
          Button {
            model.wheelStep(deck, true)
          } label: {
            Image(systemName: "chevron.right").frame(width: 40, height: 44).contentShape(Rectangle())
          }
          .buttonStyle(.plain).foregroundStyle(t?.up == true ? Color.white : DJTheme.dim).disabled(t?.up != true)
          .accessibilityLabel("Wheel a rung faster against deck \(deck)")
          Button("Sync") { model.wheelSync(deck) }.buttonStyle(.plain)
            .foregroundStyle(t != nil ? DJTheme.accent : DJTheme.dim).disabled(t == nil).frame(minWidth: 48, minHeight: 44)
            .accessibilityLabel("Sync the wheel to deck \(deck)")
        }
      }
    }
  }
}

/// The instruments, then this one's note sequence and build knobs.
private struct InstrumentCard: View {
  let model: RustDJModel
  let l: WheelLayout?

  var body: some View {
    Card("Instrument", trailing: { if model.wheel.rewinding { Caption("winding…") } }) {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(model.wheel.presets, id: \.id) { p in
          let on = p.id == l?.id
          Button {
            model.wheelLoad(p.id)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(p.name).font(.system(size: 14, weight: .medium)).lineLimit(1).foregroundStyle(on ? Color.black : .white)
              Text(lawName(p.law, p.path)).font(.system(size: 11)).lineLimit(1).foregroundStyle(on ? Color.black : DJTheme.dim)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent.opacity(on ? 1 : 0.3), lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(p.name), \(lawName(p.law, p.path))").accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      if let l {
        SequenceEditor(model: model, l: l).id("\(l.id)|\(l.sequence.isEmpty)")
        BuildKnobs(model: model, l: l, gear: model.wheel.gear)
      }
    }
  }
}

/// The instrument's note sequence: type the notes the path plays, in order ("C E G B C B G E";
/// octave optional), and it re-winds the coil for them as you type, round a hoop once a lap. The
/// chips show how it reads; after winding, the notes as wound.
private struct SequenceEditor: View {
  let model: RustDJModel
  let l: WheelLayout
  @State private var text: String

  init(model: RustDJModel, l: WheelLayout) {
    self.model = model
    self.l = l
    _text = State(initialValue: l.sequence.isEmpty ? Self.presetText(l) : l.sequence)
  }

  static func presetText(_ l: WheelLayout) -> String {
    l.notes.map { n in String(n.name.prefix { $0 != "+" && $0 != "-" }) }.joined(separator: " ")
  }

  private var parsed: Result<[String], Error> {
    Result { try wheelParseSequence(text: text, root: l.root) }
  }

  var body: some View {
    let wound = !l.sequence.isEmpty && text.trimmingCharacters(in: .whitespaces) == l.sequence
    let p = parsed
    VStack(alignment: .leading, spacing: 8) {
      Divider1()
      Text("Note sequence").font(.system(size: 14, weight: .medium))
      Caption(
        "The notes the path plays, in order, wound as you type; round a hoop it loops each lap. Octave optional: "
          + "C E G B C rises to the octave above.")
      TextField("notes", text: $text)
        .font(.system(size: 15, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.words)
        #endif
        .submitLabel(.done)
        .onSubmit { if case .success = p { model.wheelSequence(text) } }
        .accessibilityLabel("Note sequence")
      FlowLayout(spacing: 4) {
        switch p {
        case .failure(let e):
          Text("\(e)".replacingOccurrences(of: "wheel: ", with: "")).font(.system(size: 12)).foregroundStyle(DJTheme.danger)
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
      Button("Preset's notes") { model.wheelPresetNotes() }.buttonStyle(.plain)
        .foregroundStyle(l.sequence.isEmpty ? DJTheme.dim : DJTheme.accent).disabled(l.sequence.isEmpty).frame(minHeight: 44)
    }
    // wound as typed: once the field reads as notes and has paused a moment
    .task(id: "\(text)|\(l.root)") {
      let t = text.trimmingCharacters(in: .whitespaces)
      guard case .success = parsed, !wound, !t.isEmpty else { return }
      if l.sequence.isEmpty && t == Self.presetText(l) { return }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      model.wheelSequence(text)
    }
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

/// The web toy's build knobs for this instrument, all live and kept per instrument.
private struct BuildKnobs: View {
  let model: RustDJModel
  let l: WheelLayout
  let gear: Double
  private static let loads: [Double] = [8, 32, 100, 470, 2000, 10000]

  private func set(_ f: (inout WheelKnobs) -> Void) {
    guard var k = model.currentWheelKnobs() else { return }
    f(&k)
    model.wheelKnobs(k)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider1()
      Text("Build").font(.system(size: 14, weight: .medium))
      // the free laws but the tubes move one magnet
      if l.cord || l.law == "gravity" {
        WheelStepper(title: l.cord ? "Magnets on the cord" : "Magnets", value: "\(l.magnets)", label: "Magnets") { d in
          let n = UInt32(min(max(Int(l.magnets) + d, 1), 16))
          if n != l.magnets { set { $0.magnets = n } }
        }
        if l.cord && l.onsetsPerLap > 0 {
          Caption("\(l.notes.count) notes × \(l.magnets) magnet\(l.magnets > 1 ? "s" : ""): \(l.onsetsPerLap) onsets a lap")
        }
      }
      if l.cord {
        LabeledSlider(title: "Gear", value: String(format: "×%.1f", gear), v: gear, range: 1...20, taper: gearTaper) {
          model.wheelGear(($0 * 2).rounded() / 2)
        }
      }
      LabeledSlider(
        title: "Carrier", value: String(format: "%.1f g", l.carrierG), v: l.carrierG, range: 0...100, taper: carrierTaper
      ) { x in set { $0.carrierG = x < 10 ? (x * 10).rounded() / 10 : x.rounded() } }
      ToggleRow(
        title: "Coil drag",
        sub: l.braking ? "The coil's current brakes the motion (Lenz)" : "Off: the motion doesn't feel the coil",
        isOn: l.braking
      ) { on in set { $0.braking = on } }
      if l.releaseKind == "drop" {
        LabeledSlider(
          title: "Drop height", value: String(format: "%.1f cm", l.releaseM * 100), v: l.releaseM * 100, range: 0.5...50,
          taper: heightTaper
        ) { x in set { $0.releaseM = ((x * 10).rounded() / 10) / 100 } }
      } else if l.releaseKind == "pluck" {
        LabeledSlider(
          title: "Pluck", value: String(format: "%.1f mm", l.releaseM * 1000), v: l.releaseM * 1000, range: 0.5...50,
          taper: heightTaper
        ) { x in set { $0.releaseM = ((x * 10).rounded() / 10) / 1000 } }
      }
      WheelStepper(title: "Load", value: l.trigger != nil ? "trigger" : ohms(l.loadOhms), label: "Load") { d in
        guard l.trigger == nil else { return }
        let loads = Self.loads
        let i = loads.firstIndex { $0 >= l.loadOhms - 1e-6 } ?? loads.count - 1
        let j = min(max(i + d, 0), loads.count - 1)
        if loads[j] != l.loadOhms { set { $0.loadOhms = loads[j] } }
      }
      if !l.notes.isEmpty && !l.timbre.isEmpty {
        FlowLayout(spacing: 6) {
          Text("Timbre").font(.system(size: 14)).padding(.trailing, 8).frame(minHeight: 36)
          ForEach(l.timbres, id: \.self) { t in Chip(label: t, selected: t == l.timbre) { set { $0.timbre = t } } }
        }
        LabeledSlider(
          title: "Decay", value: l.decayMs < 1 ? "sustained" : String(format: "%.0f ms", l.decayMs), v: l.decayMs,
          range: 0...1000, taper: decayTaper
        ) { x in set { $0.decayMs = x <= 0 ? 0 : x < 50 ? x.rounded() : (x / 5).rounded() * 5 } }
      }
    }
  }
}

private let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

/// "E3" → 52 (MIDI); "Bb2" and "C#4" too. Nil for anything else.
private func midiOf(_ name: String) -> Int? {
  let s = name.trimmingCharacters(in: .whitespaces)
  guard let first = s.first, let i = "CDEFGAB".firstIndex(of: Character(first.uppercased())) else { return nil }
  var rest = s.dropFirst()
  var acc = 0
  if rest.first == "#" {
    acc = 1
    rest = rest.dropFirst()
  } else if rest.first == "b" {
    acc = -1
    rest = rest.dropFirst()
  }
  guard let oct = Int(rest) else { return nil }
  let base = [0, 2, 4, 5, 7, 9, 11]["CDEFGAB".distance(from: "CDEFGAB".startIndex, to: i)]
  return (oct + 1) * 12 + base + acc
}

private func nameOf(_ midi: Int) -> String {
  noteNames[((midi % 12) + 12) % 12] + "\(Int((Double(midi) / 12).rounded(.down)) - 1)"
}

/// The key: the root the notes are wound around, and a transposition; each change re-winds.
/// The steppers move a draft; the re-wind follows a burst of taps.
private struct KeyCard: View {
  let model: RustDJModel
  let l: WheelLayout
  @State private var root: String
  @State private var transpose: Int

  init(model: RustDJModel, l: WheelLayout) {
    self.model = model
    self.l = l
    _root = State(initialValue: l.root)
    _transpose = State(initialValue: Int(l.transpose))
  }

  var body: some View {
    Card("Key") {
      WheelStepper(title: "Root", value: root, label: "Root note") { d in
        if let m = midiOf(root) { root = nameOf(min(max(m + d, 24), 84)) }
      }
      WheelStepper(title: "Transpose", value: String(format: "%+d", transpose), label: "Transpose") { d in
        transpose = min(max(transpose + d, -24), 24)
      }
      let far = l.outOfReach
      Caption(
        far > 0
          ? "\(far) note\(far > 1 ? "s" : "") past this coil's reach · lower the key or brighten"
          : "Every note is re-wound for the key you set"
      )
      .foregroundStyle(far > 0 ? DJTheme.danger : DJTheme.dim).lineLimit(1)
    }
    .task(id: "\(root)|\(transpose)") {
      guard root != l.root || transpose != Int(l.transpose) else { return }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      model.wheelKey(root, transpose)
    }
  }
}

/// Brightness (the coil and magnet sizes), the level, the trigger and the output meter, then the
/// feed's health.
private struct WheelSoundCard: View {
  let model: RustDJModel
  let l: WheelLayout
  @State private var bright: Double?

  var body: some View {
    let s = model.wheelState
    Card("Sound") {
      LabeledSlider(
        title: "Brightness", value: String(format: "coil %.1f mm · magnet %.1f mm", l.coilRadiusMm, l.magnetMm),
        v: bright ?? l.brightness, range: 0...1, onDone: { bright = nil }
      ) {
        bright = $0
        model.wheelBrightness($0)  // live: the coil re-winds as the slider moves
      }
      LabeledSlider(title: "Level", value: String(format: "%+.0f dB", l.volumeDb), v: l.volumeDb, range: -20...40) {
        model.wheelVolume($0.rounded())
      }
      ToggleRow(
        title: "Trigger",
        sub: l.trigger != nil ? "A load across the coil: open · matched · short" : "Off: the coil drives its \(ohms(l.loadOhms)) load",
        isOn: l.trigger != nil
      ) { model.wheelTrigger($0 ? 0.5 : nil) }
      // always laid out (greyed while off): the card keeps its height when the trigger comes on
      LabeledSlider(
        title: "Pull", value: l.trigger.map(pullName) ?? "turn the trigger on first", v: l.trigger ?? 0, range: 0...1,
        enabled: l.trigger != nil
      ) { model.wheelTrigger($0) }
      // the pull is heard from about ¼ to ¾ (−17 dB … matched … −17 dB); near the ends it's near silent
      FineSlider(
        description: "Pull", value: l.trigger ?? 0.5, range: 0.25...0.75, caption: "¼ … ¾, matched in the middle",
        enabled: l.trigger != nil
      ) { model.wheelTrigger($0) }
      Meter(label: "out", level: Float(s?.outPeak ?? 0))
      Caption(s.map { String(format: "%.1f m/s · drag %.2f N · %.1f mW", abs($0.speedMps), $0.dragN, $0.powerMw) } ?? " ")
        .font(.system(size: 11))
      Dropouts(s: s)
    }
  }
}

/// The wheel's feed into its strip, live: dropouts (the strip ran dry) and skips (an overfull
/// ring) since the engine started, and over the last second the least the ring held and the
/// biggest block the output took at once. Red once anything has dropped out.
private struct Dropouts: View {
  let s: WheelState?
  @State private var t0 = Date.distantPast
  @State private var low = Double.greatestFiniteMagnitude
  @State private var block = 0.0
  @State private var shown = (0.0, 0.0)

  var body: some View {
    let bad = (s?.underruns ?? 0) > 0 || (s?.skips ?? 0) > 0
    Text(
      s.map {
        String(
          format: "dropouts %u · skips %u · ring low %.1f ms · block %.1f ms · kept %.0f ms", $0.underruns, $0.skips,
          shown.0, shown.1, $0.ringTargetMs)
      } ?? " "
    )
    .font(.system(size: 11)).foregroundStyle(bad ? DJTheme.danger : DJTheme.dim)
    .accessibilityLabel("Wheel dropouts")
    // the poll's low / block are since the last poll (~33 ms): held over a second here
    .onChange(of: s) { _, s in
      guard let s else { return }
      let now = Date()
      if t0 == .distantPast { t0 = now }
      low = min(low, s.ringLowMs)
      block = max(block, s.blockMs)
      if now.timeIntervalSince(t0) >= 1 {
        shown = (low == .greatestFiniteMagnitude ? 0 : low, block)
        t0 = now
        low = .greatestFiniteMagnitude
        block = 0
      }
    }
  }
}
