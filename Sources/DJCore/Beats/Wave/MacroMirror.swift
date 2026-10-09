import Synchronization

// What the audio thread tells the display about running macros (SPEC mode 26): which of the
// `NetMacro`s are in effect and which nets each of them is holding muted. The numbers are built
// once per render block from timers the executor already keeps (WaveGraph's tick-locked
// restores, the beat repeater, the runner's tempo effect), published as one consistent record
// through `MacroMirror` and read on the main thread (`WaveDeckSource.activeMacros`,
// `rolesHeld(by:among:)`). Nothing here allocates on the audio thread; nothing is guessed from
// the UI side.
//
// Ownership. A net is muted at most once: `fireMute` skips a net that is already muted, so the
// timer that will restore it belongs to exactly one macro and carries that macro's tag. The
// held sets are therefore kept per macro (a macro fired over another one's mutes is shown
// holding only what it muted itself).
//
// Which project. The record carries the generation of the graph the audio thread was running
// when it was built. Net indices mean something only in that graph, and a project handed over
// while a macro runs is installed only at the next bar, so the display resolves roles through
// the latest project's tables only when the generations agree.

/// One block's worth of macro state: `mask` bit `k` is `NetMacro(rawValue: k)`; `held` is a
/// bitset over the first 256 nets for each macro, four words each (macro `k`, net `i`: bit
/// `i % 64` of word `4k + i / 64`).
struct MacroSnapshot: BitwiseCopyable {
  /// Words per macro: 256 nets, like the mute mirror.
  static let wordsPerMacro = 4
  /// How many macros the record has room for.
  static let capacity = 16

  var mask: UInt32 = 0
  var held = SIMD64<UInt64>(repeating: 0)

  /// Mark net `i` as held muted by macro `slot` (`NetMacro.rawValue`). Nets past 255 are not
  /// tracked, like the mute mirror.
  mutating func hold(net i: Int, slot: Int) {
    guard i >= 0, i < 256, slot >= 0, slot < Self.capacity else { return }
    held[slot * Self.wordsPerMacro + i / 64] |= 1 << UInt64(i % 64)
  }

  /// Is net `i` held by `macro`?
  func isHeld(net i: Int, by macro: NetMacro) -> Bool {
    guard i >= 0, i < 256 else { return false }
    return held[Int(macro.rawValue) * Self.wordsPerMacro + i / 64] & (1 << UInt64(i % 64)) != 0
  }

  /// Is net `i` held by any macro?
  func isHeld(net i: Int) -> Bool {
    guard i >= 0, i < 256 else { return false }
    for k in 0..<Self.capacity
    where held[k * Self.wordsPerMacro + i / 64] & (1 << UInt64(i % 64)) != 0 {
      return true
    }
    return false
  }
}

/// The published record: the audio thread (the only writer) fills it once per render block, any
/// thread reads it, and a reader never sees half of one block's record and half of another's.
/// A seqlock: the writer makes the sequence odd, writes, makes it even; a reader that finds it
/// odd, or changed after its copy, tries again. All the words are atomics, so no read races a
/// write; no allocation, no lock.
final class MacroMirror: @unchecked Sendable {
  struct Read {
    var snapshot = MacroSnapshot()
    /// `WaveProject.generation` of the graph the record was built from (0: none yet).
    var generation: Int32 = 0
  }

  private let sequence = Atomic<UInt32>(0)
  private let maskBits = Atomic<UInt32>(0)
  private let generationBits = Atomic<Int32>(0)
  private let words: UnsafeMutablePointer<Atomic<UInt64>>
  /// Words in use: every macro of the catalogue has its four.
  private let count: Int

  init() {
    // taken here, on the creating (main) thread: the catalogue array is not touched later
    count = NetMacro.allCases.count * MacroSnapshot.wordsPerMacro
    precondition(count <= MacroSnapshot.capacity * MacroSnapshot.wordsPerMacro)
    words = .allocate(capacity: count)
    for i in 0..<count { (words + i).initialize(to: Atomic<UInt64>(0)) }
  }

  deinit {
    words.deinitialize(count: count)
    words.deallocate()
  }

  /// Audio thread, once per render block.
  func publish(_ s: MacroSnapshot, generation: Int32) {
    let seq = sequence.load(ordering: .relaxed)
    sequence.store(seq &+ 1, ordering: .relaxed)  // odd: a write is in progress
    atomicMemoryFence(ordering: .releasing)  // ...and that is visible before any word changes
    maskBits.store(s.mask, ordering: .relaxed)
    generationBits.store(generation, ordering: .relaxed)
    for i in 0..<count { words[i].store(s.held[i], ordering: .relaxed) }
    sequence.store(seq &+ 2, ordering: .releasing)  // even: the record is whole
  }

  /// The latest whole record; nil if a writer kept getting in the way (the caller keeps its last).
  func read() -> Read? {
    for _ in 0..<16 {
      let before = sequence.load(ordering: .acquiring)
      if before & 1 != 0 { continue }
      var r = Read()
      r.snapshot.mask = maskBits.load(ordering: .relaxed)
      r.generation = generationBits.load(ordering: .relaxed)
      for i in 0..<count { r.snapshot.held[i] = words[i].load(ordering: .relaxed) }
      atomicMemoryFence(ordering: .acquiring)
      if sequence.load(ordering: .relaxed) == before { return r }
    }
    return nil
  }
}

extension NetMacro {
  /// What a mute timer carries to say which macro owns it: the raw value plus one, so that 0
  /// means "no macro".
  var tag: UInt8 { rawValue + 1 }
  /// Its bit in `MacroSnapshot.mask`.
  var bit: UInt32 { 1 << UInt32(rawValue) }
}
