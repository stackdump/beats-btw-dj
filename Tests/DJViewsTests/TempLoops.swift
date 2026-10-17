import DJCore
import Foundation

// Kept out of the Testing files: importing Foundation next to Testing needs a cross-import
// overlay Command Line Tools doesn't ship (see TempFavorites.swift).

/// A loop library in a fresh temporary directory (view tests).
func tempLoopLibrary() -> LoopLibrary {
  LoopLibrary(
    dir: FileManager.default.temporaryDirectory
      .appendingPathComponent("loops-\(UUID().uuidString)", isDirectory: true))
}

func removeLoopLibrary(_ lib: LoopLibrary) { try? FileManager.default.removeItem(at: lib.dir) }

func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func fileName(_ url: URL) -> String { url.lastPathComponent }

/// The files in a library's `removed/`, sorted.
func removedLoopFiles(_ lib: LoopLibrary) -> [String] {
  let removed = lib.dir.appendingPathComponent("removed").path
  return ((try? FileManager.default.contentsOfDirectory(atPath: removed)) ?? []).sorted()
}

/// Hold `queue` (nothing queued after this runs) until the returned function is called.
func holdQueue(_ queue: DispatchQueue) -> () -> Void {
  let gate = DispatchSemaphore(value: 0)
  queue.async { gate.wait() }
  return { gate.signal() }
}

/// Did an observed property change (`withObservationTracking`'s `onChange`, which may run on
/// any thread)?
final class ChangeFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  var changed: Bool { lock.withLock { fired } }
  func set() { lock.withLock { fired = true } }
}
