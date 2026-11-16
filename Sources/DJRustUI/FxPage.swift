import DJRust
import SwiftUI

// The effects (djandroid ui/FxPage.kt): every trick and macro in the one category the engine puts
// it in (a Transition card of one-shots, then Filter & tone, Space, Rhythm, Arrange, Pitch,
// Stereo & shape, Feel, and the Sweeps). Nothing fires at once: a pad lands on the deck's next
// bar and runs for the length picked (1–4 bars, or latched until pressed again). A transition is
// held; a sweep has bars and no latch. The filter knob is a hand, not a trigger, and answers at
// once. On an Acid Bass loop the deck's own Acid Bass tricks show too.

/// An Acid Bass loop (groups 1–8, "1A" … "8B"), the ones the Acid Bass tricks reshape; 9 is
/// Floor & Sub.
func isAcidLoop(_ id: String?) -> Bool {
  guard let id, id.count >= 2, let g = Int(id.dropLast()) else { return false }
  return (1...8).contains(g)
}

struct FxPage: View {
  let model: RustDJModel
  /// The deck the pads act on; nil follows the lead deck.
  @State private var aimed: String?
  @State private var length: FxMode = .bars(bars: 1)
  @State private var sweepBars: UInt8 = 2

  var body: some View {
    let d = aimed ?? leadDeck(model.mix?.crossfader)
    let active = Dictionary((model.fxActive[d] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    VStack(spacing: 16) {
      Card(
        "Effects on",
        trailing: {
          Button("PANIC") { model.fxPanic(d) }
            .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(DJTheme.danger)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(DJTheme.danger.opacity(0.6)))
            .accessibilityLabel("Panic: end deck \(d)'s effects now")
        }
      ) {
        HStack(spacing: 8) {
          ForEach(deckNames, id: \.self) { n in Chip(label: "Deck \(n)", selected: d == n) { aimed = n } }
        }
      }
      Card("Length", trailing: { Caption("lands on the next bar") }) {
        LengthChips(selected: length, latch: true) { length = $0 }
      }
      ForEach(model.fxCategories, id: \.id) { cat in
        let pads = model.fxCatalogue.filter { $0.category == cat.id }
        if !pads.isEmpty {
          Card(
            cat.label,
            trailing: {
              if cat.transition {
                Caption("hold · one-shot")
              } else if !cat.latchable {
                LengthChips(selected: .bars(bars: sweepBars), latch: false) {
                  if case let .bars(n) = $0 { sweepBars = n }
                }
              }
            }
          ) {
            FlowLayout(spacing: 8) {
              ForEach(pads, id: \.id) { p in
                if cat.transition {
                  HoldPad(
                    label: p.label, active: active[p.id],
                    onPress: { model.engage(d, p.id, .momentary) }, onRelease: { model.fxRelease(d, p.id) })
                } else {
                  let mode = cat.latchable ? length : .bars(bars: sweepBars)
                  FxPad(label: p.label, active: active[p.id]) {
                    if active[p.id] != nil { model.fxUnlatch(d, p.id) } else { model.engage(d, p.id, mode) }
                  }
                }
              }
            }
            if cat.id == "filter-tone" { FilterKnob(model: model, deck: d) }
          }
        }
      }
      // the engine's own Acid Bass tricks (djmobile `fx::ACID_TRICKS`): held pads, on this deck's loop
      let acid = model.fxCatalogue.filter { $0.family == "acid" }
      if !acid.isEmpty && isAcidLoop(model.decks[d]?.deck?.td3) {
        Card("Acid Bass", trailing: { Caption("on this deck's loop") }) {
          FlowLayout(spacing: 8) {
            ForEach(acid, id: \.id) { p in
              HoldPad(
                label: p.label, active: active[p.id],
                onPress: { model.fxAcid(d, p.id, true) }, onRelease: { model.fxAcid(d, p.id, false) })
            }
          }
          Caption(
            "Accents hit every note hard, slides hold every note into the next (both land on the next bar). "
              + "Cutoff closes the bass and rides it open over two bars.")
        }
      }
      Spacer(minLength: 24)
    }
  }
}

/// A Dim caption (12 pt).
struct Caption: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(DJTheme.dim) }
}

/// 1 2 3 4 bars, and (where the category allows it) Latch.
struct LengthChips: View {
  let selected: FxMode
  let latch: Bool
  let onSelect: (FxMode) -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(1...4, id: \.self) { n in
        Chip(label: "\(n)", selected: selected == .bars(bars: UInt8(n))) { onSelect(.bars(bars: UInt8(n))) }
          .accessibilityLabel("\(n) bar\(n == 1 ? "" : "s")")
      }
      if latch { Chip(label: "Latch", selected: selected == .latch) { onSelect(.latch) } }
    }
  }
}

private func padState(_ a: FxActive?) -> String {
  guard let a else { return "" }
  return a.pending ? ", waiting for the bar" : a.latched ? ", latched" : ", on"
}

/// A pad: a tap engages it for the length picked, on the next bar; a tap while it is on (or
/// waiting, or latched) lets it go on the next bar. Lit once its bar has come, outlined while it
/// waits, ringed white while latched.
struct FxPad: View {
  let label: String
  let active: FxActive?
  let onTap: () -> Void

  var body: some View {
    let on = active.map { !$0.pending } ?? false
    Button(action: onTap) {
      Text(label).font(.system(size: 14)).foregroundStyle(on ? Color.black : Color.white)
        .padding(12).frame(minWidth: 96, minHeight: 56)
        .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
          if active?.pending == true {
            RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent, lineWidth: 2)
          } else if active?.latched == true {
            RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 2)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label + padState(active))
    .accessibilityHint(active != nil ? "let go on the bar" : "engage on the bar")
  }
}

/// A transition: on at the press (landing on the next bar), off at the release. Tape stop and
/// the freeze hold until the finger lifts; a riser runs its bars; a cut ends by itself. Each pad
/// is its own gesture, so two hands hold two pads.
struct HoldPad: View {
  let label: String
  let active: FxActive?
  let onPress: () -> Void
  let onRelease: () -> Void
  @State private var down = false

  var body: some View {
    let on = down || (active.map { !$0.pending } ?? false)
    Text(label).font(.system(size: 14)).foregroundStyle(on ? Color.black : Color.white)
      .padding(12).frame(minWidth: 96, minHeight: 56)
      .background(on ? DJTheme.accent : DJTheme.surface2, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        if active?.pending == true { RoundedRectangle(cornerRadius: 12).stroke(DJTheme.accent, lineWidth: 2) }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !down {
              down = true
              onPress()
            }
          }
          .onEnded { _ in
            down = false
            onRelease()
          }
      )
      .accessibilityElement()
      .accessibilityLabel(label + ", hold" + padState(active))
      .accessibilityAddTraits(.isButton)
      // VoiceOver can't hold: a double-tap fires it for a second
      .accessibilityAction(named: "fire") {
        onPress()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { onRelease() }
      }
  }
}

/// The one-knob filter under a hand: left low-pass, right high-pass, and back to open on release.
struct FilterKnob: View {
  let model: RustDJModel
  let deck: String
  @State private var v = 0.5

  var body: some View {
    HStack(spacing: 8) {
      Text("Filter").font(.system(size: 14)).frame(minWidth: 56, alignment: .leading)
      Text("low").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
      Slider(
        value: Binding(
          get: { v },
          set: {
            v = $0
            model.trickKnob(deck, $0)
          }),
        in: 0...1,
        onEditingChanged: { editing in
          if !editing {
            v = 0.5
            model.trickKnob(deck, 0.5)
          }
        }
      )
      .accessibilityLabel("Filter, low-pass to high-pass, springs back open")
      Text("high").font(.system(size: 11)).foregroundStyle(DJTheme.dim)
    }
  }
}
