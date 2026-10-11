import Foundation

/// Poll until `cond` holds or `timeout` seconds pass. For things that arrive on another
/// thread (AVAudioEngine delivers tap buffers asynchronously). Kept out of the files that
/// `import Testing`: Foundation next to Testing needs the Xcode-only overlay.
func waitUntil(timeout: Double = 15, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(timeout)
  while Date() < end {
    if cond() { return true }
    Thread.sleep(forTimeInterval: 0.005)
  }
  return cond()
}

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
