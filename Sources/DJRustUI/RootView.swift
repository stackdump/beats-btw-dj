import DJRust
import SwiftUI

// The shell of djandroid's DeckScreen.kt: the top bar, the seven tabs and a horizontal pager of
// pages, each one vertical scroll of play cards (DESIGN §2). Utilities live behind the menu
// (MenuSheet.swift), never on a page.

/// The screens, in their order (DESIGN §2): five-to-seven-letter labels so seven fit a phone.
enum Page: String, CaseIterable, Identifiable {
  case deckA = "Deck A", mix = "Mix", deckB = "Deck B", wheel = "Wheel", vox = "Vox"
  case effects = "Effects", inserts = "Inserts"
  var id: String { rawValue }
  var deck: String? { self == .deckA ? "A" : self == .deckB ? "B" : nil }

  /// A wide window (`wideFrom` points and up: the Mac's window widened, an iPad Pro in landscape)
  /// shows both decks with the mixer between them on one "Decks" page; narrower, the seven tabs.
  /// (`DJ_WIDE_FROM=<points>`, a launch environment, moves it: screenshots of the wide layout.)
  static let wideFrom: CGFloat = ProcessInfo.processInfo.environment["DJ_WIDE_FROM"].flatMap(Double.init).map { CGFloat($0) } ?? 1100
  static func pages(wide: Bool) -> [Page] { wide ? [.deckA, .wheel, .vox, .effects, .inserts] : allCases }
  func label(wide: Bool) -> String { wide && self == .deckA ? "Decks" : rawValue }
  /// Where a page lives in the wide layout (Mix and Deck B are columns of Decks).
  func wide(_ on: Bool) -> Page { on && (self == .mix || self == .deckB) ? .deckA : self }
}

public struct DJRustRoot: View {
  @State private var model: RustDJModel
  /// `DJ_PAGE="Effects"` (a launch environment, for screenshots): open on that page.
  @State private var page: Page? = ProcessInfo.processInfo.environment["DJ_PAGE"].flatMap(Page.init(rawValue:)) ?? .deckA

  public init(model: RustDJModel) { _model = State(initialValue: model) }

  public var body: some View {
    ZStack {
      DJTheme.surface0.ignoresSafeArea()
      if model.starting {
        VStack(spacing: 12) {
          ProgressView()
          Text("starting the engine…").foregroundStyle(DJTheme.dim)
        }
      } else {
        GeometryReader { g in
          let wide = g.size.width >= Page.wideFrom
          VStack(spacing: 0) {
            VStack(spacing: 8) {
              TopBar(model: model)
              PageTabs(model: model, pages: Page.pages(wide: wide), wide: wide, current: (page ?? .deckA).wide(wide)) { p in
                withAnimation { page = p }
              }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            pager(wide: wide)
          }
          .onChange(of: wide, initial: true) { _, w in if let p = page, p.wide(w) != p { page = p.wide(w) } }
        }
      }
    }
    .preferredColorScheme(.dark)
    .tint(DJTheme.accent)
    .alert(
      "Something went wrong",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }

  /// A horizontal pager: swipe (or tap a tab) between pages; each page scrolls on its own.
  private func pager(wide: Bool) -> some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(Page.pages(wide: wide)) { p in
          Group {
            if wide && p == .deckA {
              decks
            } else {
              ScrollView(.vertical) {
                pageBody(p).padding(.horizontal, 16).padding(.vertical, 8)
                  .frame(maxWidth: 720).frame(maxWidth: .infinity)
              }
            }
          }
          .containerRelativeFrame(.horizontal)
          .id(p)
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $page)
    .scrollIndicators(.hidden)
  }

  /// Deck A, the mixer and Deck B side by side, each its own column of cards.
  private var decks: some View {
    HStack(alignment: .top, spacing: 16) {
      column { DeckPage(model: model, deck: "A") }
      column { MixPage(model: model) }.frame(maxWidth: 420)
      column { DeckPage(model: model, deck: "B") }
    }
    .padding(.horizontal, 16)
  }

  private func column<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    ScrollView(.vertical) { c().padding(.vertical, 8).frame(maxWidth: 620) }
      .scrollIndicators(.hidden).frame(maxWidth: .infinity)
  }

  @ViewBuilder private func pageBody(_ p: Page) -> some View {
    switch p {
    case .deckA, .deckB: DeckPage(model: model, deck: p.deck!)
    case .mix: MixPage(model: model)
    case .effects: FxPage(model: model)
    case .vox: VoxPage(model: model)
    case .inserts: InsertsPage(model: model)
    case .wheel: WheelPage(model: model)
    default: NotPortedPage(page: p)
    }
  }
}

/// The pages' names; a deck tab's dot lights while its deck plays. Tap one to go there.
struct PageTabs: View {
  let model: RustDJModel
  var pages = Page.allCases
  var wide = false
  let current: Page
  let onPick: (Page) -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(pages) { p in
        // the wide Decks tab lights for either deck
        let lit = model.isLit(p) || (wide && p == .deckA && model.isLit(.deckB))
        let selected = p == current
        Button {
          onPick(p)
        } label: {
          // the dot sits above the name, so a lit tab's name fits as well as an unlit one
          VStack(spacing: 4) {
            Circle().fill(lit ? DJTheme.accent : .clear).frame(width: 6, height: 6)
            Text(p.label(wide: wide)).font(.system(size: 12, weight: selected ? .medium : .regular))
              .foregroundStyle(selected ? DJTheme.accent : DJTheme.dim).lineLimit(1).fixedSize()
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(selected ? DJTheme.surface2 : .clear, in: RoundedRectangle(cornerRadius: 12))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(p.label(wide: wide) + (lit ? ", playing" : ""))
      }
    }
  }
}

extension RustDJModel {
  /// A tab's dot: its deck plays, or its page has something on (djandroid PageTabs).
  func isLit(_ p: Page) -> Bool {
    switch p {
    case .deckA, .deckB: decks[p.deck!]?.deck?.playing == true
    case .effects: fxActive.values.contains { !$0.isEmpty }
    case .vox: vox.state?.on == true
    case .inserts: inserts.anyOn
    case .wheel: wheel.moving
    default: false
    }
  }
}

/// A page whose port hasn't landed: says so in place, in Dim (state, not an info card).
struct NotPortedPage: View {
  let page: Page
  var body: some View {
    Text("\(page.rawValue): not ported yet (docs/ANDROID-PORT.md)")
      .font(.system(size: 14)).foregroundStyle(DJTheme.dim)
      .frame(maxWidth: .infinity, minHeight: 120)
  }
}
