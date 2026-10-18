import AppKit
import SwiftUI

/// A SwiftUI colour as 0…255 RGB, the way `renderPixels` reads pixels (FxUnitViewTests).
func NSColorRGB(_ c: Color) -> (Int, Int, Int) {
  guard let n = NSColor(c).usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
  return (
    Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()),
    Int((n.blueComponent * 255).rounded())
  )
}
