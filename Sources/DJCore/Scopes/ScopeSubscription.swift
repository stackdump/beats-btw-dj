// ScopeSubscription: the bookkeeping of "which feed is this panel listening to".
//
// A scope panel acquires the feed of its selected source while it is on screen, moves the
// subscription when the source changes and drops it when it goes away. That is what keeps the
// taps off in an idle app, so it lives here, away from SwiftUI, where a test can drive it against
// a real hub (offscreen rendering never runs `onAppear` / `onDisappear`).
//
//   let subscription = ScopeSubscription()
//   subscription.move(to: hub.feed(source))   // appear, and on every source change
//   subscription.syncMeasured(measured, hub: hub)   // appear, and on a change of source or flag
//   subscription.release()                    // disappear (after syncMeasured(false, ...))
//
// It holds exactly one acquire at a time. It has no `deinit` release (a `@MainActor` class's
// deinit cannot touch main-actor state): whoever owns it calls `release()` when it goes away.

@MainActor
public final class ScopeSubscription {
  /// The feed currently held (acquired once by this subscription), if any.
  public private(set) var feed: ScopeFeed?
  /// The feed the hub has been told to read for "measured" on this subscription's behalf.
  public private(set) var measuredFeed: ScopeFeed?

  public init() {}

  /// Make `hub` read the held feed on every pump exactly while `on` (the panel's "measured" flag),
  /// in whichever view is showing: scope.js reads the analyser in `frame()` once `s.measured` is
  /// ticked, not only in the views that draw the measured half. Follows the held feed when it
  /// moves; call it after `move(to:)` and whenever the flag changes, and with `false` before
  /// `release()` or when the panel goes away.
  public func syncMeasured(_ on: Bool, hub: ScopeHub) {
    let want = on ? feed : nil
    if measuredFeed === want { return }
    if let old = measuredFeed { hub.setMeasured(false, for: old) }
    if let new = want { hub.setMeasured(true, for: new) }
    measuredFeed = want
  }

  /// Hold `new` instead of whatever is held: acquire it, then release the old one (so a tap the
  /// two share is never switched off and on). The same feed again does nothing; nil releases.
  public func move(to new: ScopeFeed?) {
    if feed === new { return }
    let old = feed
    feed = new
    new?.acquire()
    old?.release()
  }

  /// Let go of the held feed. Safe to repeat.
  public func release() { move(to: nil) }
}
