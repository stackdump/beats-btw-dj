import Foundation

@testable import DJCore

// Foundation-side helpers for the perf-monitor tests (a file that imports Testing cannot import
// Foundation under Command Line Tools only).

/// A steady clock a test moves by hand.
final class FakeClock: @unchecked Sendable {
  var now: Double
  init(_ start: Double = 1000) { now = start }
  func advance(ms: Double) { now += ms / 1000 }
}

/// Let the main run loop run (timers fire) for a while.
@MainActor
func spinMainRunLoop(seconds: Double) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// A preference store over a throw-away `UserDefaults` suite, and the suite's name for cleanup.
func scratchDefaultsStore() -> (store: PerfPreferenceStore, read: () -> String?, clean: () -> Void)
{
  let name = "dj-vevr-se.perf-tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  return (
    PerfPreferenceStore.userDefaults(defaults),
    { defaults.string(forKey: PerfPreferenceStore.key) },
    { defaults.removePersistentDomain(forName: name) }
  )
}
