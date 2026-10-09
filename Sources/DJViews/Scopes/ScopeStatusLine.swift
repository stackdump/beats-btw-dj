import SwiftUI

// The panel header's status line, which a mode can speak for (scope.js `updateStatus`: the raster
// view replaces the kernel status with "raster · loop cycle · 12 bars · 340 events · 8 ms").
//
// The host (`ScopePanelView`) owns one `ScopeStatusLine`, shows `text ?? feed.statusText` in its
// header, and hands the line to the mode view through the environment. A mode that has something
// to say calls `set(_:owner:)` (every frame is fine: it only stores a string), a mode that does not
// says nothing and the host's own status stays. The header re-reads it a few times a second, so
// nothing here is observed or published. The owner is the mode's model: `clear(owner:)` from
// `onDisappear` takes the text away again, but only if it is still that owner's (a new view of
// the next source may already have written its own).

@MainActor
final class ScopeStatusLine {
  private(set) var text: String?
  private weak var owner: AnyObject?

  init() {}

  /// Show `text` (nil: show the host's own) on behalf of `owner`.
  func set(_ text: String?, owner: AnyObject) {
    self.owner = owner
    self.text = text
  }

  /// Take `owner`'s text away; nothing happens if somebody else has spoken since.
  func clear(owner: AnyObject) {
    guard self.owner === owner else { return }
    self.owner = nil
    text = nil
  }
}

private struct ScopeStatusLineKey: EnvironmentKey {
  static var defaultValue: ScopeStatusLine? { nil }
}

extension EnvironmentValues {
  /// The panel's status line; nil outside a `ScopePanelView`.
  var scopeStatusLine: ScopeStatusLine? {
    get { self[ScopeStatusLineKey.self] }
    set { self[ScopeStatusLineKey.self] = newValue }
  }
}
