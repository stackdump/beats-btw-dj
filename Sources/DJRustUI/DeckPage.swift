import DJRust
import SwiftUI

// One deck (djandroid ui/DeckScreen.kt DeckPage): the ring, now playing, transport, roles, the
// next track, sound, what every track keeps, tempo & volume. Most-played first.

struct DeckPage: View {
  let model: RustDJModel
  let deck: String

  var body: some View {
    let u = model.decks[deck] ?? DeckUI()
    VStack(spacing: 16) {
      if let d = u.deck {
        Platter(d: d, clock: model.clocks[deck]!) { model.togglePlay(deck) }
        NowPlaying(d: d)
        Transport(model: model, deck: deck, d: d)
        RolesCard(model: model, deck: deck, d: d)
      } else {
        Text("deck \(deck): composing its first track…").foregroundStyle(DJTheme.dim)
          .frame(maxWidth: .infinity, minHeight: 120)
      }
      NextTrackCard(model: model, deck: deck, u: u)
      SoundCard(model: model, deck: deck, u: u)
      KeepCard(model: model, deck: deck, u: u)
      if let d = u.deck { TempoVolumeCard(model: model, deck: deck, d: d, u: u) }
      Spacer(minLength: 24)
    }
  }
}

/// The hero: the track as a ring of its sections, the playhead going round, the deck's level as
/// a glow; the centre is the play button. The playhead is extrapolated per frame from the clock
/// (TimelineView), so it glides and nothing else re-renders.
struct Platter: View {
  let d: DeckState
  let clock: PlayClock
  let onTap: () -> Void

  private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ now: Date) {
    let snap = clock.snap
    let side = min(size.width, size.height)
    let stroke = side * 0.07
    let r = (side - stroke - 8) / 2
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let total = Double(max(d.totalTicks, 1))
    let pos = max(0, snap.position(at: now)).truncatingRemainder(dividingBy: total)
    func arc(_ from: Double, _ sweep: Double) -> Path {
      var p = Path()
      p.addArc(
        center: c, radius: r, startAngle: .degrees(-90 + from), endAngle: .degrees(-90 + from + sweep),
        clockwise: false)
      return p
    }
    if d.sections.isEmpty {
      ctx.stroke(arc(0, 360), with: .color(DJTheme.surface2), lineWidth: stroke)
    }
    for s in d.sections {
      let start: Double = Double(s.startTick) / total * 360
      let sweep: Double = Double(s.ticks) / total * 360
      let current = pos >= Double(s.startTick) && pos < Double(s.startTick + s.ticks)
      let color = DJTheme.sectionColor(s.name).opacity(current ? 1 : 0.45)
      ctx.stroke(arc(start + 0.6, max(0.5, sweep - 1.2)), with: .color(color), lineWidth: stroke)
    }
    if d.totalTicks > 0 {
      let a: Double = (-90 + pos / total * 360) * .pi / 180
      let inner: Double = r - stroke * 0.9
      let outer: Double = r + stroke * 0.9
      var p = Path()
      p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
      p.addLine(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
      ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }
    let level = Double(min(max(snap.level, 0), 1))
    let gr: Double = side * (0.30 + 0.06 * level) * 1.3
    let glow = Gradient(colors: [DJTheme.accent.opacity(0.10 + 0.45 * level), .clear])
    ctx.fill(
      Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
      with: .radialGradient(glow, center: c, startRadius: 0, endRadius: gr))
  }

  var body: some View {
    TimelineView(.animation) { tl in
      Canvas { ctx, size in draw(&ctx, size, tl.date) }
    }
    .overlay {
      GeometryReader { g in
        let side = min(g.size.width, g.size.height) * 0.62
        Button(action: onTap) {
          VStack(spacing: 2) {
            if d.composing && !d.loaded {
              ProgressView().controlSize(.large)
            } else {
              Image(systemName: d.playing ? "pause.fill" : "play.fill").font(.system(size: 44))
                .foregroundStyle(DJTheme.accent)
            }
            Text(String(format: "%.1f", d.tempo)).font(.system(size: 34, weight: .light, design: .monospaced))
            Text("BPM").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
            Text(d.totalBars > 0 ? "bar \(d.bar) / \(d.totalBars)" : "bar \(d.bar) · loop")
              .font(.system(size: 12, design: .monospaced)).foregroundStyle(DJTheme.dim).padding(.top, 4)
          }
          .frame(width: side, height: side)
          .background(DJTheme.surface1, in: Circle())
          .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.playing ? "Pause" : "Play")
        .position(x: g.size.width / 2, y: g.size.height / 2)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: 560)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }
}

struct NowPlaying: View {
  let d: DeckState
  var body: some View {
    VStack(spacing: 6) {
      Text(d.title ?? "—").font(.system(size: 22, weight: .medium)).lineLimit(1)
      let parts = [d.genre, d.seed.map { "seed \($0)" }, d.structure ?? d.genre.map { _ in "loop" }].compactMap { $0 }
      Text(d.loaded ? parts.joined(separator: " · ") : d.composing ? "composing…" : "nothing loaded: Compose & load below")
        .font(.system(size: 14)).foregroundStyle(DJTheme.dim)
      if let s = d.section {
        Text(s).font(.system(size: 12)).foregroundStyle(DJTheme.sectionColor(s))
          .padding(.horizontal, 12).padding(.vertical, 4)
          .background(DJTheme.sectionColor(s).opacity(0.2), in: Capsule())
      }
      if let m = d.message { Text(m).font(.system(size: 12)).foregroundStyle(DJTheme.danger) }
    }
    .frame(maxWidth: .infinity)
  }
}

/// ⏮ ⏯ ⏭: back (the top, or the track before), play, the next version.
struct Transport: View {
  let model: RustDJModel
  let deck: String
  let d: DeckState
  var body: some View {
    HStack(spacing: 24) {
      iconButton("backward.end.fill", "Previous", 26) { model.previous(deck) }
      iconButton(d.playing ? "pause.fill" : "play.fill", d.playing ? "Pause" : "Play", 36, tint: DJTheme.accent) {
        model.togglePlay(deck)
      }
      iconButton("forward.end.fill", "Next", 26) { model.next(deck) }
    }
    .disabled(!d.loaded)
    .frame(maxWidth: .infinity)
  }

  private func iconButton(_ name: String, _ label: String, _ size: CGFloat, tint: Color = .white, _ f: @escaping () -> Void)
    -> some View
  {
    Button(action: f) {
      Image(systemName: name).font(.system(size: size)).foregroundStyle(tint).frame(minWidth: 56, minHeight: 56)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel(label)
  }
}

/// The song's roles: tap pauses a role or lets it play; long-press locks it out (muted now and
/// left out of every track this deck loads) or lets it back in.
struct RolesCard: View {
  let model: RustDJModel
  let deck: String
  let d: DeckState
  var body: some View {
    if !d.roles.isEmpty {
      Card(
        "Roles",
        trailing: { Text("tap: pause · hold: lock out").font(.system(size: 11)).foregroundStyle(DJTheme.dim) }
      ) {
        FlowLayout(spacing: 8) {
          ForEach(d.roles, id: \.name) { r in
            let bg: Color = r.disabled ? .clear : r.audible ? DJTheme.accent : DJTheme.surface2
            let fg: Color = r.disabled ? DJTheme.danger : r.audible ? .black : DJTheme.dim
            HStack(spacing: 6) {
              if r.disabled { Image(systemName: "lock.fill").font(.system(size: 12)) }
              Text(r.name).font(.system(size: 14)).strikethrough(r.disabled)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
              RoundedRectangle(cornerRadius: 12).stroke(
                r.disabled ? DJTheme.danger : r.audible ? DJTheme.accent : DJTheme.surface2, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { if !r.disabled { model.setRole(deck, r.name, !r.audible) } }
            .onLongPressGesture(minimumDuration: 0.5) { model.setRoleDisabled(deck, r.name, !r.disabled) }
            .accessibilityLabel(r.name)
            .accessibilityValue(r.disabled ? "locked out" : r.audible ? "playing" : "silent")
          }
        }
      }
    }
  }
}

struct NextTrackCard: View {
  let model: RustDJModel
  let deck: String
  let u: DeckUI

  var body: some View {
    if let draft = u.draft {
      let composing = u.deck?.composing == true
      Card(
        "Next track",
        trailing: {
          Button {
            model.surprise(deck)
          } label: {
            Label("Surprise me", systemImage: "shuffle").font(.system(size: 14))
          }
          .buttonStyle(.plain).foregroundStyle(DJTheme.accent).disabled(composing)
        }
      ) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(model.genres, id: \.self) { g in
              Chip(label: g, selected: g == draft.genre) { model.editDraft(deck) { $0.genre = g } }
            }
          }
        }
        .scrollIndicators(.hidden)
        HStack(spacing: 12) {
          Button {
            model.rollSeed(deck)
          } label: {
            Image(systemName: "dice.fill").font(.system(size: 20)).frame(width: 48, height: 48)
              .background(DJTheme.surface2, in: Circle())
          }
          .buttonStyle(.plain).accessibilityLabel("New seed")
          VStack(alignment: .leading) {
            Text(draft.title).font(.system(size: 17)).lineLimit(1)
            Text("seed \(draft.seed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(DJTheme.dim)
          }
          Spacer()
        }
        Picker(
          "Structure",
          selection: Binding(get: { draft.structure }, set: { s in model.editDraft(deck) { $0.structure = s } })
        ) {
          ForEach(model.structures, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        Button {
          model.compose(deck)
        } label: {
          HStack(spacing: 10) {
            if composing { ProgressView().controlSize(.small).tint(.black) }
            Text(composing ? "Composing…" : "Compose & load").font(.system(size: 17))
          }
          .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 56)
          .background(DJTheme.accent.opacity(composing ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).disabled(composing)
        AutoNextRows(model: model, deck: deck, a: u.autoNext, d: u.deck)
        EndOfSongRow(model: model, deck: deck, on: u.autoAdvance, d: u.deck)
      }
    }
  }
}

/// Auto-next every N bars: on the line that starts the run's last bar the deck steps to seed + 1.
struct AutoNextRows: View {
  let model: RustDJModel
  let deck: String
  let a: AutoNext
  let d: DeckState?
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Auto-next every \(a.bars) bars").font(.system(size: 14))
        let left = d?.autoNextLeft
        let status =
          !a.on
          ? "off"
          : d?.loaded != true
            ? "waiting for a track" : left.map { "Next in \($0)/\(a.bars)" } ?? (d!.playing ? "waiting" : "stopped: counts from play")
        Text(status).font(.system(size: 12, design: .monospaced))
          .foregroundStyle(a.on && left != nil ? DJTheme.accent : DJTheme.dim)
      }
      Spacer()
      DJToggle(label: "Auto-next", isOn: Binding(get: { a.on }, set: { v in model.setAutoNext(deck) { $0.on = v } }))
    }
    HStack(spacing: 8) {
      Text("bars").font(.system(size: 12)).foregroundStyle(DJTheme.dim)
      ForEach(AutoNext.presets, id: \.self) { n in
        Chip(label: "\(n)", selected: a.bars == n) { model.setAutoNext(deck) { $0.bars = n } }
      }
    }
  }
}

/// At a song's end, play its next version (the next generated seed).
struct EndOfSongRow: View {
  let model: RustDJModel
  let deck: String
  let on: Bool
  let d: DeckState?
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("At the end: the next seed").font(.system(size: 14))
        let status: String = {
          if !on { return "off: the song stops at its end" }
          if d?.structure == nil { return "a loop never ends (⏭ steps on)" }
          if let n = d?.nextVersionSeed, let g = d?.genre { return "then: \(trackTitle(genre: g, seed: n)) · seed \(n)" }
          return "on"
        }()
        Text(status).font(.system(size: 12)).foregroundStyle(on ? DJTheme.accent : DJTheme.dim).lineLimit(1)
      }
      Spacer()
      DJToggle(label: "At the end: the next seed", isOn: Binding(get: { on }, set: { model.setAutoAdvance(deck, $0) }))
    }
  }
}

struct SoundCard: View {
  let model: RustDJModel
  let deck: String
  let u: DeckUI
  var body: some View {
    if !u.palettes.isEmpty {
      let locked = u.soundLock != nil
      Card(
        "Sound",
        trailing: {
          HStack(spacing: 8) {
            Text(locked ? "Locked" : "Lock").font(.system(size: 12)).foregroundStyle(locked ? DJTheme.accent : DJTheme.dim)
            DJToggle(
              label: "Lock the sound: every track this deck loads keeps it",
              isOn: Binding(get: { locked }, set: { model.setSoundLock(deck, $0) }))
          }
        }
      ) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(u.palettes, id: \.id) { p in
              Chip(label: p.label, selected: p.selected, enabled: p.unavailable == nil) { model.setPalette(deck, p.id) }
            }
          }
        }
        .scrollIndicators(.hidden)
        if let sel = u.palettes.first(where: \.selected) {
          Text(deviceText(sel.description)).font(.system(size: 12)).foregroundStyle(DJTheme.dim)
        }
        let off = u.palettes.filter { $0.unavailable != nil }
        if !off.isEmpty {
          Text("needs a SoundFont: " + off.map(\.label).joined(separator: ", "))
            .font(.system(size: 12)).foregroundStyle(DJTheme.dim)
        }
      }
    }
  }
}

/// The engine's wording is the Mac app's; on an iPad, say iPad.
func deviceText(_ s: String) -> String {
  #if os(iOS)
    return s.replacingOccurrences(of: "this Mac", with: "this iPad")
  #else
    return s
  #endif
}

/// What every track this deck loads keeps besides its sound and tempo: key, feel, genre.
struct KeepCard: View {
  let model: RustDJModel
  let deck: String
  let u: DeckUI
  var body: some View {
    let loaded = u.deck?.loaded == true
    Card("Keep on every track") {
      row("Key", u.keyLabel, u.keyLock != nil, loaded) { model.setKeyLock(deck, $0) }
      row("Feel", u.feelLabel, u.feelLock != nil, loaded) { model.setFeelLock(deck, $0) }
      row(
        "Genre", u.genreLock ? "Surprise me keeps \(u.draft?.genre ?? "the genre")" : nil, u.genreLock, true
      ) { model.setGenreLock(deck, $0) }
    }
  }

  private func row(_ what: String, _ label: String?, _ on: Bool, _ can: Bool, _ set: @escaping (Bool) -> Void)
    -> some View
  {
    HStack {
      Text(what).frame(width: 64, alignment: .leading)
      Text(on ? label ?? "Locked" : can ? "Lock" : "Lock (nothing loaded)").font(.system(size: 12))
        .foregroundStyle(on ? DJTheme.accent : DJTheme.dim)
      Spacer()
      DJToggle(label: "Lock the \(what.lowercased())", isOn: Binding(get: { on }, set: { v in if can || !v { set(v) } }))
    }
  }
}

struct TempoVolumeCard: View {
  let model: RustDJModel
  let deck: String
  let d: DeckState
  let u: DeckUI

  var body: some View {
    let other = deck == "A" ? "B" : "A"
    Card(
      "Tempo & volume",
      trailing: {
        HStack(spacing: 8) {
          if !d.loaded { Text("nothing loaded").font(.system(size: 11)).foregroundStyle(DJTheme.dim) }
          Button("Sync to \(other)") { model.sync(deck) }.buttonStyle(.plain).foregroundStyle(DJTheme.accent)
            .disabled(!d.loaded)
        }
      }
    ) {
      HStack {
        Text(u.tempoLock.map { String(format: "Tempo locked at %.1f BPM", $0) } ?? "Lock the tempo")
          .font(.system(size: 12)).foregroundStyle(u.tempoLock != nil ? DJTheme.accent : DJTheme.dim)
        Spacer()
        DJToggle(
          label: "Lock the tempo: every track this deck loads plays at this BPM",
          isOn: Binding(get: { u.tempoLock != nil }, set: { v in if d.loaded || !v { model.setTempoLock(deck, v) } }))
      }
      HStack {
        Text("Tempo").frame(width: 64, alignment: .leading)
        Text(
          String(
            format: "%+.2f%%  ·  %.2f BPM", d.pitch * d.pitchRange * 100, d.baseTempo * (1 + d.pitch * d.pitchRange))
        )
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(d.pitch == 0 ? DJTheme.dim : DJTheme.accent)
        .onTapGesture(count: 2) { model.setPitch(deck, 0) }
        Spacer()
      }
      Slider(value: Binding(get: { d.pitch }, set: { model.setPitch(deck, $0) }), in: -1...1)
        .accessibilityLabel("Tempo")
      // beatmatching nudges live within ±1 %, a sliver of even the ±8 range
      FineSlider(
        description: "Tempo", value: d.pitch * d.pitchRange * 100, range: -1...1, caption: "±1 %, in hundredths"
      ) { v in
        model.setPitch(deck, (v * 100).rounded() / 10_000 / d.pitchRange)
      }
      HStack(spacing: 8) {
        Text("range").font(.system(size: 12)).foregroundStyle(DJTheme.dim)
        ForEach([0.08, 0.16, 0.5], id: \.self) { r in
          Chip(label: "±\(Int((r * 100).rounded()))", selected: abs(d.pitchRange - r) < 1e-6) {
            model.setPitchRange(deck, r)
          }
        }
        Spacer()
        Text("double-tap: 0").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
      }
      HStack(spacing: 12) {
        Image(systemName: "speaker.wave.2.fill").foregroundStyle(DJTheme.dim)
        Slider(value: Binding(get: { Fader.toPos(d.volume) }, set: { model.setVolume(deck, Fader.fromPos($0)) }))
          .accessibilityLabel("Volume")
      }
    }
  }
}
