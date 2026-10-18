import Darwin
import Foundation

// Counts malloc-family allocations made by the calling thread while a closure runs,
// via libsystem_malloc's `malloc_logger` hook. Kept out of files that `import Testing`
// (Foundation next to Testing needs the Xcode-only overlay).
//
// This is how the "audio thread must not allocate" contract is *measured*, not
// asserted: render a few thousand blocks and expect zero allocations.
//
// `countAllocations(stacks: true)` also keeps the call stacks of the first `maxStacks`
// offending calls, so an occasional failure says where it came from. The hook runs inside
// malloc: it may not allocate or lock, so it only copies return addresses (`backtrace`, which
// walks frame pointers) into storage allocated up front; they are symbolicated after the
// hook is disarmed.

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let stackLoggingTypeAlloc: UInt32 = 2
private let stackLoggingTypeDealloc: UInt32 = 4

/// Stacks kept per measurement, and frames per stack.
public let maxStacks = 8
private let maxFrames = 48

// Storage the hook can touch without allocating or locking.
// [allocs, frees, stacks kept, recording?, inside the hook?]
nonisolated(unsafe) private let counters = UnsafeMutablePointer<Int>.allocate(capacity: 5)
nonisolated(unsafe) private let armed = UnsafeMutablePointer<pthread_t?>.allocate(capacity: 1)
// maxStacks × maxFrames return addresses, with each stack's depth, kind (type bits) and
// size / pointer argument.
nonisolated(unsafe) private let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
  capacity: maxStacks * maxFrames)
nonisolated(unsafe) private let depths = UnsafeMutablePointer<Int32>.allocate(capacity: maxStacks)
nonisolated(unsafe) private let kinds = UnsafeMutablePointer<UInt32>.allocate(capacity: maxStacks)
nonisolated(unsafe) private let args = UnsafeMutablePointer<UInt>.allocate(capacity: maxStacks)

private let hook: MallocLogger = { type, _, a2, a3, _, _ in
  guard let t = armed.pointee, pthread_equal(t, pthread_self()) != 0 else { return }
  // Only the armed thread gets here, so a plain flag is enough against re-entry (should
  // `backtrace` ever allocate, that allocation is neither counted nor recorded).
  guard counters[4] == 0 else { return }
  let alloc = type & stackLoggingTypeAlloc != 0
  let dealloc = type & stackLoggingTypeDealloc != 0
  guard alloc || dealloc else { return }
  if alloc { counters[0] += 1 }
  if dealloc { counters[1] += 1 }
  guard counters[3] != 0, counters[2] < maxStacks else { return }
  counters[4] = 1
  let k = counters[2]
  depths[k] = backtrace(frames + k * maxFrames, Int32(maxFrames))
  kinds[k] = type
  // malloc: a2 = size; free: a2 = pointer; realloc: a2 = old pointer, a3 = new size
  args[k] = alloc && dealloc ? a3 : a2
  counters[2] = k + 1
  counters[4] = 0
}

nonisolated(unsafe) private var installed = false
private let gate = NSLock()  // one measurement at a time: the hook state is process-global

public struct AllocationReport: Sendable {
  public var allocations: Int
  public var frees: Int
  /// With `stacks: true`: the first `maxStacks` offending calls, symbolicated, one string
  /// each ("#1 malloc 64 bytes" / "#2 free" / "#3 realloc to …", then a frame per line).
  public var stacks: [String] = []

  /// The stacks as one block of text for a failure message ("" when none were kept).
  public var stackText: String {
    stacks.isEmpty ? "" : "\n" + stacks.joined(separator: "\n\n")
  }
}

/// Run `body` and report malloc/free calls made on this thread. One counter at a time:
/// tests that use it must not run it concurrently on the same process. `stacks: true` also
/// returns where the first few came from (`AllocationReport.stacks`).
public func countAllocations(stacks: Bool = false, _ body: () -> Void) -> AllocationReport {
  gate.lock()
  defer { gate.unlock() }
  if !installed {
    installed = true
    counters.initialize(repeating: 0, count: 5)
    armed.initialize(to: nil)
    frames.initialize(repeating: nil, count: maxStacks * maxFrames)
    depths.initialize(repeating: 0, count: maxStacks)
    kinds.initialize(repeating: 0, count: maxStacks)
    args.initialize(repeating: 0, count: maxStacks)
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") {
      sym.assumingMemoryBound(to: MallocLogger?.self).pointee = hook
    }
  }
  counters[0] = 0
  counters[1] = 0
  counters[2] = 0
  counters[3] = stacks ? 1 : 0
  counters[4] = 0
  armed.pointee = pthread_self()
  body()
  armed.pointee = nil
  var report = AllocationReport(allocations: counters[0], frees: counters[1])
  if stacks {
    report.stacks = (0..<counters[2]).map { symbolicate($0) }
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
  var lines = ["#\(k + 1) \(what)"]
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
