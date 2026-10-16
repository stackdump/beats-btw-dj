import Foundation

/// Keeps the display from idling to sleep while held: a `ProcessInfo` activity with
/// `.idleDisplaySleepDisabled` (a PreventUserIdleDisplaySleep power assertion; `pmset -g
/// assertions` lists it under DJApp). The system can still sleep on the lid or the menu.
@MainActor
final class ScreenWakeLock {
  private var activity: NSObjectProtocol?

  var isHeld: Bool { activity != nil }

  func set(_ on: Bool) {
    if on, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleDisplaySleepDisabled, .userInitiatedAllowingIdleSystemSleep],
        reason: "DJApp: keep the screen awake")
    } else if !on, let a = activity {
      ProcessInfo.processInfo.endActivity(a)
      activity = nil
    }
  }
}
