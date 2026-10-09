import DJCore
import SwiftUI

// StageView: the full-window Stage (SPEC modes 7, 8, 13, 20 and the host every later stage mode
// plugs into).
//
//   StageView(model:)           the live view: a TimelineView paced by the perf level that
//                               advances the model once per drawn frame and draws the scene.
//                               It acquires the feed on appear and releases it on disappear, so
//                               the taps are on only while the window is up.
//   StageScene(model:context:)  one frame drawn from a given context: background, the layer
//                               stack (StageLayerRegistry.swift), then the chrome. This is what
//                               tests render (a fixed-size container, no timeline), and what
//                               the live view draws every frame.
//
// The app shows it in its own window (`Window(StageWindow.title, id: StageWindow.id)`, opened by
// the "Stage" button next to "Scopes"); `StageWindowView` is that window's content.
//
// Keys (focus is taken on appear): Esc closes the help sheet, else the window; the arrow keys and
// T are forwarded to the layers (solo visualizer cycling, card flash). The toolbar starts folded
// into one dot, as stage.js does.
//
// The feed is held between `onAppear` and `onDisappear` (a test mounts the view in an unshown
// window and checks both). That `onDisappear` also runs when the app's `Window` scene is CLOSED
// with the red button is the one thing no offscreen test can show: look at
// `hub.activeFeeds` (or the tap) after closing the window.

/// The app's Stage window: one id for the scene (`DJApp`) and the button that opens it.
public enum StageWindow {
  public static let id = "stage"
  public static let title = "Stage"

  /// Can the Stage window show anything yet? Its model appears with the audio engine.
  @MainActor
  public static func canOpen(_ app: AppModel) -> Bool { app.stageModel != nil }
}

public struct StageView: View {
  let model: StageModel
  @State private var helpOpen = false
  /// The timeline's frame cap in seconds, 0 for the display's rate. The perf level
  /// (`ScopeHub.vizLevel`) is not observable, so the frame that sees it change re-paces the
  /// timeline through `onChange` (state may not be written while a frame is being built).
  @State private var interval: Double
  @FocusState private var focused: Bool
  @Environment(\.dismissWindow) private var dismissWindow

  public init(model: StageModel) {
    self.model = model
    _interval = State(initialValue: model.minFrameInterval)
  }

  public var body: some View {
    GeometryReader { geo in
      TimelineView(.animation(minimumInterval: interval > 0 ? interval : nil)) { timeline in
        let ctx = model.frame(
          now: timeline.date.timeIntervalSinceReferenceDate, width: geo.size.width,
          height: geo.size.height)
        StageScene(model: model, context: ctx, helpOpen: $helpOpen)
          .onChange(of: ctx.vizLevel) { interval = model.minFrameInterval }
      }
    }
    .background(StagePalette.background.color)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear {
      model.attach()
      focused = true
    }
    .onDisappear { model.detach() }
    .onKeyPress(.escape) {
      if helpOpen {
        helpOpen = false
      } else {
        dismissWindow(id: StageWindow.id)
      }
      return .handled
    }
    .onKeyPress(.leftArrow) { model.handleKey(.left) ? .handled : .ignored }
    .onKeyPress(.rightArrow) { model.handleKey(.right) ? .handled : .ignored }
    .onKeyPress(characters: CharacterSet(charactersIn: "tT")) { _ in
      model.handleKey(.t) ? .handled : .ignored
    }
  }
}

/// One frame of the stage, drawn from `context`.
struct StageScene: View {
  let model: StageModel
  let context: StageContext
  @Binding var helpOpen: Bool

  init(model: StageModel, context: StageContext, helpOpen: Binding<Bool> = .constant(false)) {
    self.model = model
    self.context = context
    _helpOpen = helpOpen
  }

  var body: some View {
    ZStack {
      StagePalette.background.color
      StageLayerStack(context: context, models: model.layers)
      StageChrome(model: model, context: context, helpOpen: $helpOpen)
    }
    .clipped()
  }
}

/// The window content of the app's Stage window.
public struct StageWindowView: View {
  let app: AppModel

  public init(app: AppModel) { self.app = app }

  public var body: some View {
    if let model = app.stageModel {
      StageView(model: model)
    } else {
      ZStack {
        StagePalette.background.color
        Text("Starting the audio engine…")
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(Color.white.opacity(0.5))
      }
    }
  }
}
