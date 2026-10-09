import DJCore
import SwiftUI

// ScopePanelView: the host of the analytic scope modes (scope.js `renderScopePanel`).
//
// A header (view picker, source picker A | B | Master, "measured" toggle for the views that have
// a measured half, a status line) over the body of the selected mode. The host owns the
// subscription: it acquires the feed of the selected source while it is on screen and moves the
// subscription when the source changes, so the taps run only while a panel is visible (the
// bookkeeping is `ScopeSubscription`, in DJCore, where it is tested against a real hub).
//
// THE MODE VIEW CONTRACT
// ----------------------
// The body is one view per `ScopeKind`, each in its own file:
//
//   ScopeLiveView.swift    ScopeSpectroView.swift    ScopeBandsView.swift    ScopeRasterView.swift
//
// and every one has exactly this shape:
//
//   struct ScopeLiveView: View {
//     init(feed: ScopeFeed, measured: Bool, hub: ScopeHub)
//     var body: some View
//   }
//
// This host depends on nothing but the type name and that initialiser, so a mode can be
// reworked inside its own file without touching anything else. Inside a mode view:
//   * draw through `ScopeCanvas(hub: hub) { ctx, size in … }` (it paces the frames, pumps the
//     hub, fills the background); never start your own timeline;
//   * read only from `feed` (see ScopeFeed.swift for the time-base contract) — never from the
//     engine or the decks. The song's `Project` (for a mode that walks the whole arrangement) is
//     `feed.leadProject`;
//   * keep per-mode accumulated state in a reference-type model created with the view
//     (`@State private var model = …`) and reset it when `feed.generation` changes. Generation
//     numbers are unique across feeds, and the host gives the body a new identity for every
//     feed, so a switch of source (A, B, Master) always arrives as a fresh view *and* a changed
//     generation; a fire cursor (`fireLog.numbers(since:)`) never outlives either;
//   * `measured` is the panel's measured toggle (only spectro and bands show it);
//   * the panel hands the body the height `ScopeKind.viewHeight` computes; fill it.
// A mode that needs another input in the future gets it from the environment, not from a new
// initialiser parameter.
//
// THE STAGE
// ---------
// The stage (SPEC modes 7…21: constellation, corona, sonar … over the whole window) is not a
// `ScopeKind`; it is its own window (`Sources/DJViews/Scopes/Stage`), opened by the "Stage"
// button next to the "Scopes" toggle in `ContentView`. Source selection and feeds are shared: the
// stage takes `hub.feed(.master)` / `hub.feed(.deck(…))` like this panel.

struct ScopePanelView: View {
  let hub: ScopeHub
  @Binding var kind: ScopeKind
  @Binding var source: ScopeSource
  @Binding var measured: Bool
  /// The height the panel's rule works from (scope.js `window.innerHeight`; nil: unknown, treated
  /// as 800). The app passes the screen's usable height, not the window's: the window grows with
  /// the panel, and a rule that read it would chase its own tail.
  var windowHeight: Double?

  @State private var subscription = ScopeSubscription()
  /// A mode's own status text (the raster's "raster · loop cycle · ..."); see ScopeStatusLine.
  @State private var statusLine: ScopeStatusLine
  /// Tests hand in a raster controller that has already settled (a rendered frame cannot wait
  /// for the background compute); the app leaves it nil and the raster view makes its own.
  private let rasterController: RasterController?

  init(
    hub: ScopeHub, kind: Binding<ScopeKind>, source: Binding<ScopeSource>,
    measured: Binding<Bool>, windowHeight: Double? = nil, statusLine: ScopeStatusLine? = nil,
    rasterController: RasterController? = nil
  ) {
    self.hub = hub
    _kind = kind
    _source = source
    _measured = measured
    self.windowHeight = windowHeight
    _statusLine = State(initialValue: statusLine ?? ScopeStatusLine())
    self.rasterController = rasterController
  }

  private var feed: ScopeFeed { hub.feed(source) }

  /// Lanes the height rule counts: the raster draws the lead deck's lanes only, not the master's
  /// two decks' together.
  private func heightLanes(for kind: ScopeKind) -> Int {
    kind == .raster ? feed.laneSet.lanes.count : feed.lanes.count
  }

  var body: some View {
    // The header and the height follow the lane count and status at a leisurely rate; the body
    // has its own per-frame timeline.
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let _ = hub.pump()
      VStack(spacing: 4) {
        header
        body(for: kind)
          .id(ObjectIdentifier(feed))  // a feed switch is a fresh mode view, never reused state
          .environment(\.scopeStatusLine, statusLine)
          .frame(
            height: kind.height(
              measured: measured, laneCount: heightLanes(for: kind), windowHeight: windowHeight)
          )
          .clipShape(RoundedRectangle(cornerRadius: 4))
      }
    }
    .onAppear { subscription.move(to: feed) }
    .onChange(of: source) { subscription.move(to: feed) }
    .onDisappear { subscription.release() }
  }

  @ViewBuilder private func body(for kind: ScopeKind) -> some View {
    switch kind {
    case .live: ScopeLiveView(feed: feed, measured: measured, hub: hub)
    case .spectro: ScopeSpectroView(feed: feed, measured: measured, hub: hub)
    case .bands: ScopeBandsView(feed: feed, measured: measured, hub: hub)
    case .raster:
      if let rasterController {
        ScopeRasterView(feed: feed, measured: measured, hub: hub, raster: rasterController)
      } else {
        ScopeRasterView(feed: feed, measured: measured, hub: hub)
      }
    }
  }

  private var header: some View {
    ScopePanelHeader(
      hub: hub, kind: $kind, source: $source, measured: $measured,
      status: statusLine.text ?? feed.statusText)
  }
}

/// The panel's header row: the view picker, the source picker, the "measured" toggle, the quality
/// menu and the status line. The pills never shrink; the status line, the one thing that can be
/// cut, is what gives way when the window is narrow (the main window is at least 720 pt wide).
struct ScopePanelHeader: View {
  let hub: ScopeHub
  @Binding var kind: ScopeKind
  @Binding var source: ScopeSource
  @Binding var measured: Bool
  let status: String

  var body: some View {
    HStack(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(ScopeKind.allCases) { k in
          pill(k.title, on: kind == k, help: k.help) { kind = k }
        }
        Spacer().frame(width: 10)
        ForEach(hub.sources, id: \.self) { s in
          pill(sourceTitle(s), on: source == s, help: "Show \(s.label)") { source = s }
        }
        if kind.supportsMeasured {
          Spacer().frame(width: 10)
          pill(
            measured ? "✓ measured" : "measured", on: measured,
            help:
              "Also read the audio through an analyser: measured bands / spectrogram beside the model"
          ) { measured.toggle() }
        }
        // The adaptive visual level (SPEC mode 27).
        Spacer().frame(width: 10)
        VizQualityMenu(perf: hub.perf)
      }
      .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 8)
      // On the window's own background, not the scope's: a scheme-aware colour.
      Text(status)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(-1)
    }
  }

  private func sourceTitle(_ s: ScopeSource) -> String {
    switch s {
    case .deck(let n): n
    case .master: "Master"
    }
  }

  /// A plain-SwiftUI button (no AppKit control, so it also renders offscreen).
  private func pill(_ title: String, on: Bool, help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(on ? Color.white : ScopeColors.text.color)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(on ? Color.accentColor : ScopeColors.grid.color))
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
