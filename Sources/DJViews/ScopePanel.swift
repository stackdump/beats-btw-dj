import DJCore
import SwiftUI

/// A scope for one source (deck A, deck B or the master): a header with the mode picker
/// and a close button, and below it whatever `ScopeRegistry` has for the chosen mode.
public struct ScopePanel: View {
  @Bindable var feed: ScopeFeed
  var close: () -> Void

  public init(feed: ScopeFeed, close: @escaping () -> Void = {}) {
    self.feed = feed
    self.close = close
  }

  public var body: some View {
    VStack(spacing: 4) {
      HStack {
        Text(feed.source.title).font(.caption.bold())
        Picker("Mode", selection: $feed.mode) {
          ForEach(ScopeMode.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
        Spacer()
        Button(action: close) { Image(systemName: "chevron.up") }
          .buttonStyle(.borderless).help("Collapse")
      }
      ScopeRegistry.view(for: feed.mode, feed: feed)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 160)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    .accessibilityLabel("scope \(feed.source.title)")
  }
}
