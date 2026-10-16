import Foundation
import IOKit.pwr_mgt

// IOKit and Foundation live here, not next to Testing (no _Testing_Foundation under the
// Command Line Tools).

/// The types of the power assertions this process holds now (`pmset -g assertions`).
func ownPowerAssertionTypes() -> [String] {
  var out: Unmanaged<CFDictionary>?
  guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess,
    let byPID = out?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
    let mine = byPID[NSNumber(value: ProcessInfo.processInfo.processIdentifier)]
  else { return [] }
  return mine.compactMap { $0[kIOPMAssertionTypeKey] as? String }
}

/// A throwaway defaults domain, so a test's toggles never reach the app's.
func scratchDefaults() -> UserDefaults {
  let name = "dj-vevr-se.tests.\(UUID().uuidString)"
  let d = UserDefaults(suiteName: name)!
  d.removePersistentDomain(forName: name)
  return d
}
