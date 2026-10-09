import DJCore
import SwiftUI

// The meta-net (SPEC mode 8). Placeholder until its commit: draws nothing. The slot, its place in
// the container (inside it, under the pulses and the panels) and its init are final.

struct StageMetaLayer: View {
  let context: StageContext

  var body: some View {
    Color.clear.allowsHitTesting(false)
  }
}
