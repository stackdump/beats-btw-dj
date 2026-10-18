import Darwin
import Foundation

// Counts malloc-family allocations made by the calling thread while a closure runs,
// via libsystem_malloc's `malloc_logger` hook. Kept out of files that `import Testing`
// (Foundation next to Testing needs the Xcode-only overlay).
//
// This is how the "audio thread must not allocate" contract is *measured*, not
// asserted: render a few thousand blocks and expect zero allocations.
//
// `countAllocations(stacks: true)` also records the call stack of every offending call, kept
// as up to `maxStacks` distinct stacks with a hit count each (calls whose stack is new once
// those are full only count as `unrecorded`), so an occasional failure says where every one of
// its calls came from. The hook runs inside malloc: it may not allocate or lock, so it only
// copies return addresses (`backtrace`, which walks frame pointers) into storage allocated up
// front and compares them with `memcmp`; they are symbolicated after the hook is disarmed.

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let stackLoggingTypeAlloc: UInt32 = 2
private let stackLoggingTypeDealloc: UInt32 = 4

/// Distinct stacks kept per measurement, and frames per stack.
public let maxStacks = 16
private let maxFrames = 48

// Storage the hook can touch without allocating or locking.
// [allocs, frees, distinct stacks kept, recording?, inside the hook?, nested hook entries,
//  calls not in a kept stack]
private let counterCount = 7
nonisolated(unsafe) private let counters = UnsafeMutablePointer<Int>.allocate(
  capacity: counterCount)
nonisolated(unsafe) private let armed = UnsafeMutablePointer<pthread_t?>.allocate(capacity: 1)
// (maxStacks + 1 scratch) × maxFrames return addresses, with each stack's depth, kind (type
// bits), first size / pointer argument and hit count.
nonisolated(unsafe) private let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
  capacity: (maxStacks + 1) * maxFrames)
nonisolated(unsafe) private let depths = UnsafeMutablePointer<Int32>.allocate(
  capacity: maxStacks + 1)
nonisolated(unsafe) private let kinds = UnsafeMutablePointer<UInt32>.allocate(capacity: maxStacks)
nonisolated(unsafe) private let args = UnsafeMutablePointer<UInt>.allocate(capacity: maxStacks)
nonisolated(unsafe) private let hits = UnsafeMutablePointer<Int>.allocate(capacity: maxStacks)

private let hook: MallocLogger = { type, _, a2, a3, _, _ in
  guard let t = armed.pointee, pthread_equal(t, pthread_self()) != 0 else { return }
  // Only the armed thread gets here, so a plain flag is enough against re-entry. Should
  // `backtrace` ever allocate, that allocation is not counted but shows as `nested`.
  guard counters[4] == 0 else {
    counters[5] += 1
    return
  }
  let alloc = type & stackLoggingTypeAlloc != 0
  let dealloc = type & stackLoggingTypeDealloc != 0
  guard alloc || dealloc else { return }
  if alloc { counters[0] += 1 }
  if dealloc { counters[1] += 1 }
  guard counters[3] != 0 else { return }
  counters[4] = 1
  let kept = counters[2]
  // capture into the next free slot (or the scratch slot once all are kept)
  let slot = min(kept, maxStacks)
  let base = frames + slot * maxFrames
  let depth = backtrace(base, Int32(maxFrames))
  depths[slot] = depth
  let bytes = Int(depth) * MemoryLayout<UnsafeMutableRawPointer?>.stride
  var match = -1
  var k = 0
  while k < kept {
    if kinds[k] == type && depths[k] == depth && memcmp(frames + k * maxFrames, base, bytes) == 0 {
      match = k
      break
    }
    k += 1
  }
  if match >= 0 {
    hits[match] += 1
  } else if kept < maxStacks {
    kinds[kept] = type
    // malloc: a2 = size; free: a2 = pointer; realloc: a2 = old pointer, a3 = new size
    args[kept] = alloc && dealloc ? a3 : a2
    hits[kept] = 1
    counters[2] = kept + 1
  } else {
    counters[6] += 1
  }
  counters[4] = 0
}

nonisolated(unsafe) private var installed = false
private let gate = NSLock()  // one measurement at a time: the hook state is process-global

public struct AllocationReport: Sendable {
  public var allocations: Int
  public var frees: Int
  /// With `stacks: true`: each distinct stack of the offending calls, symbolicated, one string
  /// each ("#1 malloc 64 bytes ×20" / "#2 free ×3" / "#3 realloc to … ×1", then a frame per
  /// line), in the order first seen.
  public var stacks: [String] = []
  /// With `stacks: true`: whether each of `stacks` is frees only.
  public var stackIsFree: [Bool] = []
  /// With `stacks: true`: offending calls whose stack was new after `maxStacks` were kept.
  public var unrecorded = 0
  /// Hook entries from inside the hook itself (`backtrace` allocating): should stay 0.
  public var nested = 0

  /// The stacks as one block of text for a failure message ("" when none were kept).
  public var stackText: String {
    stacks.isEmpty
      ? ""
      : "\n" + stacks.joined(separator: "\n\n")
        + (unrecorded > 0 ? "\n\n(\(unrecorded) more calls on stacks not kept)" : "")
  }

  /// No frees, or (with `stacks: true`) every free on a kept stack that `allowed` accepts.
  /// Needs every offending call classified: false when some went unrecorded.
  public func freesAreOnly(_ allowed: (String) -> Bool) -> Bool {
    if frees == 0 { return true }
    guard !stacks.isEmpty, unrecorded == 0 else { return false }
    return zip(stacks, stackIsFree).allSatisfy { !$1 || allowed($0) }
  }

  /// No frees but AudioToolbox reclaiming its parameter-listener map's nodes, which a sampler's
  /// render can do when another engine's units were torn down while it walked the map
  /// (`ListenerMap::NotifyParameterChange` → `node_allocator::end_traversal` → `free_node`).
  /// Needs `countAllocations(stacks: true)`.
  public var freesAreOnlyListenerMapReclamation: Bool {
    freesAreOnly { $0.contains("ListenerMap") && $0.contains("end_traversal") }
  }
}

/// Run `body` and report malloc/free calls made on this thread. One counter at a time:
/// tests that use it must not run it concurrently on the same process. `stacks: true` also
/// returns where they came from (`AllocationReport.stacks`).
public func countAllocations(stacks: Bool = false, _ body: () -> Void) -> AllocationReport {
  gate.lock()
  defer { gate.unlock() }
  if !installed {
    installed = true
    counters.initialize(repeating: 0, count: counterCount)
    armed.initialize(to: nil)
    frames.initialize(repeating: nil, count: (maxStacks + 1) * maxFrames)
    depths.initialize(repeating: 0, count: maxStacks + 1)
    kinds.initialize(repeating: 0, count: maxStacks)
    args.initialize(repeating: 0, count: maxStacks)
    hits.initialize(repeating: 0, count: maxStacks)
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") {
      sym.assumingMemoryBound(to: MallocLogger?.self).pointee = hook
    }
  }
  for i in 0..<counterCount { counters[i] = 0 }
  counters[3] = stacks ? 1 : 0
  armed.pointee = pthread_self()
  body()
  armed.pointee = nil
  var report = AllocationReport(allocations: counters[0], frees: counters[1])
  report.nested = counters[5]
  if stacks {
    report.stacks = (0..<counters[2]).map { symbolicate($0) }
    report.stackIsFree = (0..<counters[2]).map { kinds[$0] & stackLoggingTypeAlloc == 0 }
    report.unrecorded = counters[6]
  }
  return report
}

/// Off the hook: stack `k` as text, Swift names demangled.
private func symbolicate(_ k: Int) -> String {
  let type = kinds[k]
  let alloc = type & stackLoggingTypeAlloc != 0
  let dealloc = type & stackLoggingTypeDealloc != 0
  let what =
    alloc && dealloc
    ? "realloc to \(args[k]) bytes" : alloc ? "malloc \(args[k]) bytes" : "free"
  var lines = ["#\(k + 1) \(what) ×\(hits[k])"]
  // frame 0 is the hook itself; the malloc frames come next
  for i in 1..<max(1, Int(depths[k])) {
    guard let pc = frames[k * maxFrames + i] else { continue }
    var info = Dl_info()
    guard dladdr(pc, &info) != 0 else {
      lines.append("  \(pc)")
      continue
    }
    let image = info.dli_fname.map {
      URL(fileURLWithPath: String(cString: $0)).lastPathComponent
    }
    let name = info.dli_sname.map { demangle(String(cString: $0)) } ?? "\(pc)"
    let offset = info.dli_saddr.map { UnsafeRawPointer($0).distance(to: pc) } ?? 0
    lines.append("  \(image ?? "?")  \(name) + \(offset)")
  }
  return lines.joined(separator: "\n")
}

private typealias SwiftDemangle =
  @convention(c) (
    UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
  ) -> UnsafeMutablePointer<CChar>?

private let swiftDemangle: SwiftDemangle? = dlsym(
  UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle"
).map { unsafeBitCast($0, to: SwiftDemangle.self) }

private func demangle(_ symbol: String) -> String {
  guard let swiftDemangle, symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else {
    return symbol
  }
  return symbol.withCString { s in
    guard let out = swiftDemangle(s, strlen(s), nil, nil, 0) else { return symbol }
    defer { free(out) }
    return String(cString: out)
  }
}
