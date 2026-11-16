import Foundation

/// Holds the Wheel's instrument picker still on screen across a switch (djandroid WheelPage.kt
/// `PickerAnchor`, line for line). The cards above it (the drawing, Play, Tempo) change height
/// with the instrument: without it the next tap lands on another tile than the one aimed at.
///
/// `hold` at the tap notes how far down the viewport the picker sits; once the picked
/// instrument's layout places it, `placed` scrolls so it sits there again, and keeps doing so for
/// `settleMs` (a card above can change again a poll later, e.g. the sync slider once the new
/// wheel's tempo is read). The target is absolute (where the picker is in the page, less that
/// offset), so a correction asked for twice before the first lands is the same correction.
/// Outside the window it never touches the scroll.
public final class PickerAnchor {
  public static let settleMs: Int64 = 800

  private var offset: Double?
  private var heldAt: Double?
  private var picked: String?
  private var until: Int64 = 0

  public init() {}

  public func hold(_ id: String) {
    heldAt = offset
    picked = id
    until = 0
  }

  /// `contentY`: the picker's top in the page; `scroll`: the page's scroll now.
  public func placed(
    contentY: Double, scroll: Double, id: String?, nowMs: Int64 = WheelLog.now(), scrollTo: (Double) -> Void
  ) {
    if let at = heldAt, let id, id == picked {
      if until == 0 { until = nowMs + Self.settleMs }
      if nowMs <= until {
        let target = max(0, contentY - at)
        if abs(target - scroll) >= 0.5 { scrollTo(target) }
      } else {
        heldAt = nil
        picked = nil
      }
    }
    offset = contentY - scroll
  }
}

/// The SwiftUI side of the anchor: the Wheel page reports where the picker sits in the page and
/// which instrument is shown, the pager's scroll view its offset and how to scroll it; each
/// report runs `placed` with the latest of all three (Compose's `onGloballyPositioned` fires on
/// either change, as these do).
@MainActor public final class PickerScroll {
  public let anchor = PickerAnchor()
  private var contentY: Double?
  private var scroll: Double = 0
  private var id: String?
  /// Set by the scroll view that holds the Wheel page.
  public var scrollTo: (Double) -> Void = { _ in }

  public init() {}

  public func hold(_ id: String) { anchor.hold(id) }

  public func picker(at y: Double, id: String?) {
    contentY = y
    self.id = id
    update()
  }

  public func shown(_ id: String?) {
    self.id = id
    update()
  }

  public func scrolled(to y: Double) {
    scroll = y
    update()
  }

  private func update() {
    guard let y = contentY else { return }
    anchor.placed(contentY: y, scroll: scroll, id: id) { [scrollTo] t in scrollTo(t) }
  }
}
