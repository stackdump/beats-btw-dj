import DJCore
import SwiftUI

/// Bands mode. PLACEHOLDER: the mode agent replaces this file wholesale. Keep the type name and
/// the initialiser `init(feed:measured:hub:)` (the host `ScopePanelView` depends on nothing else),
/// draw through `ScopeCanvas(hub:)`, and read only from `feed`.
struct ScopeBandsView: View {
  let feed: ScopeFeed
  let measured: Bool
  let hub: ScopeHub

  init(feed: ScopeFeed, measured: Bool, hub: ScopeHub) {
    self.feed = feed
    self.measured = measured
    self.hub = hub
  }

  var body: some View {
    ScopePlaceholder(kind: .bands, feed: feed, measured: measured, hub: hub)
  }
}
