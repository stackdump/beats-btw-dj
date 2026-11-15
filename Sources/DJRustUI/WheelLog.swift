import Foundation
import os

/// The Wheel's field log (djandroid WheelLog.kt): one structured line per step of what it does
/// that can go wrong — an instrument switch above all: from/to, what was restored, the routes it
/// plays through, timings, failures — on in release.
///
/// Android writes logcat (tag `djwheel`) plus a file of its own so the lines outlive logcat's
/// ring. Apple's unified log keeps `.notice` and above on disk by itself, so here it is one
/// `Logger` (subsystem `io.bitwrap.beats-btw-dj`, category `wheel`) and no file. Read it with
///
///     log show --last 1h --predicate 'subsystem == "io.bitwrap.beats-btw-dj" && category == "wheel"'
///     xcrun simctl spawn booted log stream --predicate 'category == "wheel"'     # simulator, live
///     sudo log collect --device-udid <id> --last 1h    # an iPad, then `log show` the .logarchive
///
/// or Console.app with the iPad selected, filtered on `category:wheel`. Lines read
/// `event key=value key=value …` (values with spaces are quoted), as Kotlin's.
public enum WheelLog {
  /// One subsystem on the Mac (unbundled `swift run`) and the iPad, so one predicate finds both.
  public static let subsystem = "io.bitwrap.beats-btw-dj"
  public static let category = "wheel"
  private static let log = Logger(subsystem: subsystem, category: category)

  /// An INFO line (Kotlin `Log.INFO`): `.notice`, the lowest level the unified log keeps on disk.
  public static func i(_ event: String, _ kv: KeyValuePairs<String, Any?> = [:]) {
    let text = line(event, Array(kv))
    log.notice("\(text, privacy: .public)")
  }

  /// A WARN line: `.error` (Apple's `warning` is the same level), kept, and highlighted in Console.
  public static func w(_ event: String, _ kv: KeyValuePairs<String, Any?> = [:]) {
    let text = line(event, Array(kv))
    log.error("\(text, privacy: .public)")
  }

  /// `event k=v …`: the line as logged (for tests). nil is "-"; a value that is empty or holds a
  /// space, a `"` or an `=` is quoted, its `"` turned into `'`.
  public static func line(_ event: String, _ kv: [(key: String, value: Any?)]) -> String {
    var s = event
    for (k, v) in kv {
      s += " \(k)="
      let t = v.map(describe) ?? "-"
      if t.isEmpty || t.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" }) {
        s += "\"" + t.replacingOccurrences(of: "\"", with: "'") + "\""
      } else {
        s += t
      }
    }
    return s
  }

  /// Kotlin's `toString()`; an optional (however deeply wrapped in `Any`) that holds nil is "-".
  private static func describe(_ v: Any) -> String {
    let m = Mirror(reflecting: v)
    if m.displayStyle == .optional {
      guard let inner = m.children.first?.value else { return "-" }
      return describe(inner)
    }
    return "\(v)"
  }

  /// Milliseconds on a monotonic clock (Kotlin `SystemClock.elapsedRealtime()`).
  public static func now() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
}
