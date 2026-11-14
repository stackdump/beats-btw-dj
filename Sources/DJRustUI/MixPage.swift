import DJRust
import SwiftUI

// The mixer (djandroid ui/MixPage.kt): the crossfader, both decks' strips under it, auto level.

struct MixPage: View {
  let model: RustDJModel

  var body: some View {
    let x = model.mix?.crossfader ?? 0
    VStack(spacing: 16) {
      Card(
        "Crossfader",
        trailing: { Text("lead: deck \(leadDeck(x))").font(.system(size: 12)).foregroundStyle(DJTheme.dim) }
      ) {
        HStack {
          Text("A").font(.system(size: 22, weight: .medium)).foregroundStyle(x <= 0.5 ? DJTheme.accent : DJTheme.dim)
          Slider(value: Binding(get: { x }, set: { model.setCrossfader($0) }), in: 0...1)
            .frame(minHeight: 56)
            .accessibilityLabel("Crossfader, lead deck \(leadDeck(x))")
          Text("B").font(.system(size: 22, weight: .medium)).foregroundStyle(x > 0.5 ? DJTheme.accent : DJTheme.dim)
        }
        HStack {
          ForEach([("all A", 0.0), ("centre", 0.5), ("all B", 1.0)], id: \.0) { label, v in
            Button(label) { model.setCrossfader(v) }.buttonStyle(.plain).foregroundStyle(DJTheme.dim)
              .frame(maxWidth: .infinity, minHeight: 44)
          }
        }
      }
      ForEach(deckNames, id: \.self) { DeckStrip(model: model, deck: $0) }
      let auto = model.mix?.autoLevel ?? true
      Card(
        "Auto level",
        trailing: { DJToggle(label: "Auto level", isOn: Binding(get: { auto }, set: { model.setAutoLevel($0) })) }
      ) {
        Text(auto ? "A and B kept equally loud" : "Off: each deck at its own level")
          .font(.system(size: 12)).foregroundStyle(DJTheme.dim)
      }
      Spacer(minLength: 24)
    }
  }
}

struct DeckStrip: View {
  let model: RustDJModel
  let deck: String

  var body: some View {
    let d = model.decks[deck]?.deck
    let other = deck == "A" ? "B" : "A"
    let loaded = d?.loaded == true
    Card(
      "Deck \(deck)",
      trailing: {
        Button("Sync to \(other)") { model.sync(deck) }.buttonStyle(.plain).foregroundStyle(DJTheme.accent)
          .disabled(!loaded)
      }
    ) {
      HStack(spacing: 12) {
        Button {
          model.togglePlay(deck)
        } label: {
          Image(systemName: d?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 22))
            .foregroundStyle(DJTheme.accent).frame(width: 52, height: 52).background(DJTheme.surface2, in: Circle())
        }
        .buttonStyle(.plain).disabled(!loaded).accessibilityLabel(d?.playing == true ? "Pause" : "Play")
        VStack(alignment: .leading, spacing: 2) {
          Text(d?.title ?? "—").font(.system(size: 14)).lineLimit(1)
          if !loaded {
            // an empty deck says why its play and sync are off (DESIGN §4.2.3)
            Text(d?.composing == true ? "composing…" : "Deck \(deck) has nothing loaded")
              .font(.system(size: 12)).foregroundStyle(DJTheme.dim)
          } else if let d {
            let parts = [
              String(format: "%.1f BPM", d.tempo > 0 ? d.tempo : d.baseTempo), d.section, "bar \(d.bar)",
              model.mix?.autoLevel == true ? String(format: "auto %+.1f dB", d.autoGainDb) : nil,
            ].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.system(size: 12, design: .monospaced))
              .foregroundStyle(DJTheme.dim)
          }
        }
        Spacer()
      }
      LevelMeter(clock: model.clocks[deck]!)
      HStack {
        Text("vol").font(.system(size: 12)).foregroundStyle(DJTheme.dim).frame(width: 32, alignment: .leading)
        Slider(
          value: Binding(get: { Fader.toPos(d?.volume ?? 0) }, set: { model.setVolume(deck, Fader.fromPos($0)) })
        )
        .disabled(d == nil)
        .accessibilityLabel("Deck \(deck) volume")
      }
    }
  }
}

/// The deck's level, per frame from its clock.
struct LevelMeter: View {
  let clock: PlayClock
  var body: some View {
    TimelineView(.animation) { _ in
      Canvas { ctx, size in
        let l = CGFloat(min(max(clock.snap.level, 0), 1))
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(DJTheme.surface2))
        ctx.fill(
          Path(roundedRect: CGRect(x: 0, y: 0, width: size.width * l, height: size.height), cornerRadius: 3),
          with: .color(DJTheme.accent))
      }
    }
    .frame(height: 6)
  }
}
