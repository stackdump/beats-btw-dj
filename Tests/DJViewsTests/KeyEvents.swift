import AppKit

// Kept out of the Testing files (Foundation next to Testing needs an overlay CLT lacks).

/// A key-down event for `keyCode` (123 ←, 124 →, 125 ↓, 126 ↑), with optional modifiers.
func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
    keyCode: keyCode)!
}

let commandKey = NSEvent.ModifierFlags.command

/// A fresh id for a hovered list.
func newListID() -> UUID { UUID() }
