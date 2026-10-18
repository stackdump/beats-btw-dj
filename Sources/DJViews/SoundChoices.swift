import DJCore
import SwiftUI

/// The deck's sound section: the palette chooser on top (a card per `SoundPalette`: icon, name,
/// what it sounds like; greyed out with its reason when it can't play here), then — folded by
/// default — "fine-tune": each role with what the palette picked for it, the palette's other
/// options and the role's instruments to override it with, a "↺ palette" reset, and the drums'
/// kits. Every choice is a poke (`DeckAction.setPalette` / `setRoleVoice` / `setKit`) that swaps
/// at the next bar on the same song and is carried into every new track; a long press (or
/// right-click) on an instrument opens its channel's sound (`VoiceEditor`).
struct SoundChoices: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color
  @AppStorage private var fineTune: Bool
  /// The sound panel open: its channel, and the button it hangs from.
  @State private var editing: Editing?

  struct Editing: Equatable {
    var channel: Int
    var anchor: String
  }

  init(name: String, state: DeckState, model: AppModel, tint: Color) {
    self.name = name
    self.state = state
    self.model = model
    self.tint = tint
    _fineTune = AppStorage(wrappedValue: false, "fineTune.\(name)")
  }

  var body: some View {
    if state.isNet {
      let cards = PaletteCard.cards(current: state.palette)
      VStack(alignment: .leading, spacing: DJStyle.s) {
        Text("PALETTE").font(DJStyle.sectionLabel).foregroundStyle(.secondary)
        PaletteChooser(cards: cards, tint: tint) { model.setPalette(name, $0) }
        let current = cards.first(where: \.selected)
        DisclosureGroup(isExpanded: $fineTune) {
          FineTune(
            name: name, state: state, model: model, tint: tint, editing: $editing)
        } label: {
          Text("Fine-tune \(current?.label ?? "the palette")")
            .font(.caption).foregroundStyle(.secondary)
        }
        .help("What the palette picked for each role; override one, or put it back")
      }
    }
  }
}

/// The palettes as cards in a wrapping row; the current one lit. Arrow keys move along the
/// ones that can play while the row is hovered.
struct PaletteChooser: View {
  let cards: [PaletteCard]
  let tint: Color
  let pick: (String) -> Void

  var body: some View {
    let playable = cards.filter { $0.unavailable == nil }.map(\.id)
    FlowRow(spacing: DJStyle.xs) {
      ForEach(cards) { c in PaletteCardView(card: c, tint: tint) { pick(c.id) } }
    }
    .arrowKeys(playable, current: cards.first(where: \.selected)?.id) { pick($0) }
  }
}

struct PaletteCardView: View {
  let card: PaletteCard
  let tint: Color
  let action: () -> Void

  static let width: CGFloat = 132

  var body: some View {
    let accent = Color(hex: card.color) ?? tint
    Button(action: action) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(card.icon)
          Text(card.label).font(.caption.weight(.semibold)).lineLimit(1)
          if card.localOnly { Image(systemName: "lock.fill").font(.system(size: 8)) }
        }
        Text(card.unavailable ?? card.description)
          .font(.system(size: 9)).foregroundStyle(.secondary)
          .lineLimit(3).multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .padding(6)
      .frame(width: Self.width, height: 64, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(card.selected ? accent.opacity(0.28) : Color.secondary.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(card.selected ? accent : accent.opacity(0.35), lineWidth: card.selected ? 2 : 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(card.unavailable != nil)
    .opacity(card.unavailable == nil ? 1 : 0.45)
    .help(
      card.unavailable.map { "\(card.label) can't play here: \($0)" }
        ?? "\(card.description) Every role from \(card.label) (your overrides keep theirs), at"
        + " the next bar; new tracks on this deck keep it"
        + (card.localOnly ? ". Local only: a set that plays it is never published" : ""))
  }
}

/// Each role the track plays: what the palette picked, its options, its instruments.
struct FineTune: View {
  let name: String
  let state: DeckState
  let model: AppModel
  let tint: Color
  @Binding var editing: SoundChoices.Editing?
  /// Roles showing every instrument (or, for the drums, every installed kit) too.
  @State private var more: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(state.roleSounds) { row in roleRow(row) }
      Text(
        "Overrides stay through Next, new seeds and Wander until reset. Hold an instrument (or"
          + " right-click) to shape its sound, live."
      )
      .font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.top, 4)
  }

  @ViewBuilder private func roleRow(_ row: RoleSoundRow) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(row.role == "kit" ? "drums" : row.role).font(.caption2.weight(.semibold))
        Text("plays \(row.playing)").font(.caption2).foregroundStyle(.secondary)
        if row.isOverridden {
          Text("your pick").font(.caption2).foregroundStyle(tint)
          Button("↺ palette") { model.setRoleVoice(name, row.role, nil) }
            .controlSize(.mini)
            .help("Back to the palette's own pick for \(row.role)")
        }
        Spacer()
        Button(
          more.contains(row.role) ? "less" : (row.role == "kit" ? "all kits…" : "instruments…")
        ) {
          if more.contains(row.role) { more.remove(row.role) } else { more.insert(row.role) }
        }
        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
        .help(
          row.role == "kit" ? "Every kit installed on this Mac" : "Every instrument for \(row.role)"
        )
      }
      FlowRow(spacing: 4) {
        ForEach(row.choices) { c in
          ChoiceButton(label: c.label, selected: c.selected, tint: tint) {
            model.setRoleVoice(name, row.role, c.option)
          }
          .disabled(c.unavailable != nil)
          .help(c.unavailable.map { "Not on this Mac: \($0)" } ?? "\(row.role): \(c.option)")
        }
      }
      .arrowKeys(
        row.choices.filter { $0.unavailable == nil }.map(\.option),
        current: row.choices.first(where: \.selected)?.option
      ) { model.setRoleVoice(name, row.role, $0) }
      if more.contains(row.role) {
        if row.role == "kit" {
          kits(row)
        } else if let v = state.voices.first(where: { row.channels.contains($0.channel) }) {
          instruments(row, v)
        }
      }
    }
  }

  private func kits(_ row: RoleSoundRow) -> some View {
    FlowRow(spacing: 4) {
      ForEach(model.drumKits) { k in
        ChoiceButton(label: k.label, selected: row.kitPick == k.id, tint: tint) {
          model.setKit(name, row.kitPick == k.id ? nil : k.id)
        }
        .help("\(k.name) from \(k.bank): played from this Mac, swaps at the next bar")
      }
    }
  }

  private func instruments(_ row: RoleSoundRow, _ v: RoleVoice) -> some View {
    FlowRow(spacing: 4) {
      ForEach(v.options, id: \.self) { i in
        instrument(i, row, v)
        ForEach(model.variations[i] ?? [], id: \.name) { variation in
          ChoiceButton(
            label: variation.label(i),
            selected: i == v.instrument
              && model.currentVariation(i, state.voiceSettings[v.channel])?.name == variation.name,
            tint: tint
          ) {
            Task { await model.applyVariation(name, channel: v.channel, instrument: i, variation) }
          }
          .help("\(i) with its saved sound \"\(variation.name)\"")
        }
      }
    }
  }

  private func instrument(_ i: String, _ row: RoleSoundRow, _ v: RoleVoice) -> some View {
    let current = row.picked == i || row.override == "inst:\(i)"
    let setting = state.voiceSettings[v.channel]
    let tweaked =
      i == v.instrument && setting.map { !$0.isDefault && $0.instrument == i } == true
      && model.currentVariation(i, setting) == nil
    return InstrumentButton(
      label: tweaked ? "\(i) ✎" : i, selected: current, tint: tint,
      pick: {
        guard !current else { return }
        model.setRoleVoice(name, row.role, "inst:\(i)")
      },
      edit: { editing = SoundChoices.Editing(channel: v.channel, anchor: i) }
    )
    .popover(
      isPresented: Binding(
        get: { editing == SoundChoices.Editing(channel: v.channel, anchor: i) },
        set: { if !$0 { editing = nil } })
    ) {
      VoiceEditor(deck: name, role: v.role, channel: v.channel, model: model, tint: tint)
    }
  }
}

extension Color {
  /// `#RRGGBB`.
  init?(hex: String) {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    self.init(
      red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255)
  }
}

extension AppModel {
  /// The kits installed on this Mac (scanned once).
  var drumKits: [DrumKit] { DrumKits.installed }

  /// Why each palette can't play here (nil: it can), looked at once per launch.
  static var paletteUnavailable: [String: String?] { PaletteCard.unavailableHere }

  /// Play deck `deck`'s drums on `kit` (nil = the palette's kit), at the next bar (recorded).
  func setKit(_ deck: String, _ kit: String?) {
    engine?.perform(.setKit(deck: deck, kit: kit))
    refreshSound(deck)
  }

  /// Play deck `deck`'s track from `palette` (nil = the default), at the next bar (recorded).
  func setPalette(_ deck: String, _ palette: String?) {
    engine?.perform(.setPalette(deck: deck, palette: palette))
    refreshSound(deck)
  }

  /// Play `role` on deck `deck` with a palette option (nil = the palette's pick again), at the
  /// next bar (recorded).
  func setRoleVoice(_ deck: String, _ role: String, _ voice: String?) {
    engine?.perform(.setRoleVoice(deck: deck, role: role, voice: voice))
    refreshSound(deck)
  }

  /// The sound section's state without a whole poll.
  func refreshSound(_ deck: String) {
    guard let d = engine?[deck] else { return }
    decks[deck]?.kit = d.kit
    decks[deck]?.palette = d.palette
    decks[deck]?.roleSounds = d.roleSounds
  }

  /// What a Generate from the panel composes: `spec` with the deck's sound choices (its palette,
  /// kit, role overrides) carried over, then `palette` if one was chosen there.
  func generateSpec(_ deck: String, _ spec: TrackSpec, palette: String?) -> TrackSpec {
    var s = spec
    if let current = engine?[deck]?.currentSpec { s = s.carryingSound(from: current) }
    if let palette { s = s.withPalette(palette) }
    return s
  }
}
