// ScopeSubscription: the bookkeeping of "which feed is this panel listening to".
//
// A scope panel acquires the feed of its selected source while it is on screen, moves the
// subscription when the source changes and drops it when it goes away. That is what keeps the
// taps off in an idle app, so it lives here, away from SwiftUI, where a test can drive it against
// a real hub (offscreen rendering never runs `onAppear` / `onDisappear`).
//
//   let subscription = ScopeSubscription()
//   subscription.move(to: hub.feed(source))   // appear, and on every source change
//   subscription.release()                    // disappear
//
// It holds exactly one acquire at a time. It has no `deinit` release (a `@MainActor` class's
// deinit cannot touch main-actor state): whoever owns it calls `release()` when it goes away.

@MainActor
public final class ScopeSubscription {
  /// The feed currently held (acquired once by this subscription), if any.
  public private(set) var feed: ScopeFeed?

  public init() {}

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
