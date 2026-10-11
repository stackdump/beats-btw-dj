import Dispatch
import Foundation

@testable import DJCore

// Two-thread stress for the macro mirror's seqlock. Foundation threads live here, away from the
// files that `import Testing`.

private final class MacroStressDone: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  func set() {
    lock.lock()
    on = true
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return on
  }
}

struct MacroMirrorStressReport {
  var reads = 0
  var failedReads = 0
  var torn = 0  // a record whose words, mask and generation do not all name the same number
  var backwards = 0  // a later read that returned an older record
  var changesSeen = 0
}

/// The record number `n` as the writer publishes it: the mask is `n`, the generation is `n`, and
/// word `k` is `n * C + k`.
private func word(_ n: Int, _ k: Int) -> UInt64 {
  UInt64(truncatingIfNeeded: n) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(k)
}

func stressMacroMirror(publishes: Int) -> MacroMirrorStressReport {
  let mirror = MacroMirror()
  let done = MacroStressDone()
  let words = NetMacro.allCases.count * MacroSnapshot.wordsPerMacro
  Thread.detachNewThread {
    for n in 1...publishes {
      var s = MacroSnapshot()
      s.mask = UInt32(truncatingIfNeeded: n)
      for k in 0..<words { s.held[k] = word(n, k) }
      mirror.publish(s, generation: Int32(truncatingIfNeeded: n))
    }
    done.set()
  }
  var report = MacroMirrorStressReport()
  var last = 0
  while true {
    let finished = done.isSet
    guard let r = mirror.read() else {
      report.failedReads += 1
      if finished { break }
      continue
    }
    if r.generation != 0 {  // 0 is the state before the first publish
      report.reads += 1
      let n = Int(r.generation)
      var ok = r.snapshot.mask == UInt32(truncatingIfNeeded: n)
      for k in 0..<words where r.snapshot.held[k] != word(n, k) { ok = false }
      if !ok { report.torn += 1 }
      if n < last { report.backwards += 1 }
      if n != last { report.changesSeen += 1 }
      last = n
    }
    if finished { break }
  }
  return report
}
