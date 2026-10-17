import AppKit
import SwiftUI

/// Arrow keys for whatever list of choices the mouse is over: ← / ↑ pick the previous choice,
/// → / ↓ the next one, without clicking into the list first. A list opts in with
/// `.arrowKeys(...)`; hovering it makes it the arrows' target, leaving it hands them back.
///
/// The keys are read with a local key-down monitor (the app's own events, no permissions),
/// and only taken when a list is hovered and no text field is being typed into, so arrows
/// still move the cursor in a search or seed field.
@MainActor
final class HoverKeys {
  static let shared = HoverKeys()

  /// Hovered lists, innermost last (a list inside a hovered panel wins over the panel).
  private var hovered: [(id: UUID, step: (Int) -> Void, activate: (() -> Void)?)] = []
  private var monitor: Any?

  /// Start listening (idempotent). The app calls it once its window is up.
  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated { HoverKeys.shared.handle(event) } ? nil : event
    }
  }

  /// `activate`: what Return / Space do while this list is hovered (nil: they pass through).
  func enter(_ id: UUID, step: @escaping (Int) -> Void, activate: (() -> Void)? = nil) {
    hovered.removeAll { $0.id == id }
    hovered.append((id, step, activate))
  }

  func leave(_ id: UUID) { hovered.removeAll { $0.id == id } }

  /// Keep a hovered list's handler current (its selection changed while hovered).
  func update(_ id: UUID, step: @escaping (Int) -> Void, activate: (() -> Void)? = nil) {
    if let i = hovered.firstIndex(where: { $0.id == id }) {
      hovered[i].step = step
      hovered[i].activate = activate
    }
  }

  /// Was the event an arrow (or, for a list that takes it, Return / Space) for a hovered list,
  /// and so used up?
  func handle(_ event: NSEvent) -> Bool {
    guard let target = hovered.last else { return false }
    // typing in a text field: its keys, not ours
    if event.window?.firstResponder is NSText { return false }
    if let delta = Self.delta(event) {
      target.step(delta)
      return true
    }
    guard let activate = target.activate, Self.isActivate(event) else { return false }
    activate()
    return true
  }

  /// Return, keypad Enter or Space, with no modifier but Shift.
  static func isActivate(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
      return false
    }
    return [36, 76, 49].contains(event.keyCode)
  }

  /// -1 for ← / ↑, +1 for → / ↓; nil for anything else (or with ⌘ ⌥ ⌃ held).
  static func delta(_ event: NSEvent) -> Int? {
    guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
      return nil
    }
    switch event.keyCode {
    case 123, 126: return -1  // ←, ↑
    case 124, 125: return 1  // →, ↓
    default: return nil
    }
  }

  /// The choice `delta` away from `current` in `items`: stops at either end; with nothing
  /// current, → / ↓ start at the first and ← / ↑ at the last.
  static func step<T: Equatable>(_ items: [T], from current: T?, by delta: Int) -> T? {
    guard !items.isEmpty else { return nil }
    guard let current, let i = items.firstIndex(of: current) else {
      return delta > 0 ? items.first : items.last
    }
    return items[min(items.count - 1, max(0, i + delta))]
  }
}

private struct ArrowKeysModifier<T: Equatable>: ViewModifier {
  let items: [T]
  let current: T?
  let select: (T) -> Void
  var activate: (() -> Void)?
  @State private var id = UUID()
  @State private var inside = false

  private func step(_ delta: Int) {
    if let next = HoverKeys.step(items, from: current, by: delta), next != current { select(next) }
  }

  func body(content: Content) -> some View {
    content
      .onHover { on in
        inside = on
        if on {
          HoverKeys.shared.enter(id, step: step, activate: activate)
        } else {
          HoverKeys.shared.leave(id)
        }
      }
      .onChange(of: current) {
        if inside { HoverKeys.shared.update(id, step: step, activate: activate) }
      }
      .onChange(of: items) {
        if inside { HoverKeys.shared.update(id, step: step, activate: activate) }
      }
      .onDisappear { HoverKeys.shared.leave(id) }
  }
}

extension View {
  /// While the mouse is over this view, the arrow keys move the choice in `items` from
  /// `current` and call `select` with the new one.
  func arrowKeys<T: Equatable>(_ items: [T], current: T?, select: @escaping (T) -> Void)
    -> some View
  {
    modifier(ArrowKeysModifier(items: items, current: current, select: select))
  }

  /// The same, and Return / Space call `activate` (on the current choice) while hovered.
  func arrowKeys<T: Equatable>(
    _ items: [T], current: T?, select: @escaping (T) -> Void, activate: @escaping () -> Void
  ) -> some View {
    modifier(
      ArrowKeysModifier(items: items, current: current, select: select, activate: activate))
  }
}
