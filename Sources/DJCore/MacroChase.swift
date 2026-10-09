import Foundation

// SPEC mode 26: the macro chase pulse (lib/ui/controllers.js `macroPulse`, lib/macros/runtime.js
// `executeMacro` call sites, petri-note.css `.pn-pulsing`, `.pn-pulsing-hot`, `.pn-macro-btn.running`,
// `@keyframes pn-macro-pulse`).
//
// In beats, firing a mute macro lights the mute buttons it touches in a "running light": every
// target glows dimly (`pn-pulsing`) and one at a time, 120 ms each, glows hard (`pn-pulsing-hot`),
// until the macro's duration is over; the macro's own button shows `running` meanwhile.
//
// Here the same thing for the role toggles of a deck's `NetPanel`, driven by what the engine says
// (`Deck.macroActivity`: which macros are in effect, which roles they are holding muted), never
// by a UI timer that guesses how long a macro lasts. The model is pure arithmetic over an injected
// `dt`; the views draw its state.

extension NetMacro {
  /// The catalogue's selector for the macros whose UI the JS chases: the `mute` kind
  /// (`drop`, `breakdown`, `solo-drums`, `cut`; catalog.js `MACRO_TARGETS`). The compound macro
  /// (`double-drop`), the beat repeat and the tempo macros never call `macroPulse` in the JS, so
  /// they show the macro button running and no chase: nil. Whether a macro chases is this
  /// being non-nil; *which* roles it chases is what the engine says it muted
  /// (`WaveDeckSource.rolesHeld(by:among:)`), which is the selector's pick minus anything that
  /// was already muted when it fired, as `macro.targets(el)` is in the JS at fire time.
  public var chaseTargets: MacroTargets? {
    switch self {
    case .drop, .soloDrums: .nonDrums
    case .breakdown: .drumsOnly
    case .cut: .everything
    case .doubleDrop, .beatRepeat, .halfTime, .tapeStop, .tempoAnchor: nil
    }
  }
}

/// What the engine says is running on one deck, read from its mirrors.
public struct MacroActivity: Equatable, Sendable {
  /// The macros in effect, in catalogue order.
  public var running: [NetMacro]
  /// For each running macro that chases, the roles it is holding muted, in mixer order.
  public var targets: [NetMacro: [String]]

  public static let idle = MacroActivity(running: [], targets: [:])

  public init(running: [NetMacro], targets: [NetMacro: [String]]) {
    self.running = running
    self.targets = targets
  }
}

extension Deck {
  /// The macros the engine reports in effect on this deck and, for the ones the JS chases, the
  /// roles each holds muted: a role is a target of a macro while a net of it waits for that
  /// macro's own restore (so a macro fired over another one's mutes chases only what it muted
  /// itself). Main thread.
  public var macroActivity: MacroActivity {
    guard mode == .net else { return .idle }
    let running = wave.activeMacros
    guard !running.isEmpty else { return .idle }
    let roles = self.roles
    var targets: [NetMacro: [String]] = [:]
    for m in running where m.chaseTargets != nil {
      targets[m] = wave.rolesHeld(by: m, among: roles)
    }
    return MacroActivity(running: running, targets: targets)
  }
}

/// One macro's chase: its targets, and where the running light is.
///
/// `macroPulse`: `BLINK = 120`; the first frame lights element 0 at once, then every 120 ms the
/// hot one moves on, wrapping round the targets. A chase ends when its macro does (the board
/// drops it), where the JS also stops it at `durationMs` by its own timer.
public struct MacroChase: Equatable, Sendable {
  /// 120 ms per step.
  public static let step = 0.12

  public let macro: NetMacro
  /// The roles being chased, in order (the engine's held set as of the last update).
  public private(set) var targets: [String]
  /// Seconds since the chase began.
  public private(set) var elapsed = 0.0

  public init(macro: NetMacro, targets: [String]) {
    self.macro = macro
    self.targets = targets
  }

  /// Let `dt` seconds pass. Negative or non-finite `dt` is ignored.
  public mutating func advance(by dt: Double) {
    if dt.isFinite && dt > 0 { elapsed += dt }
  }

  /// The engine's held set changed (a mute landed late, a restore came early): follow it,
  /// keep the running light where it is.
  public mutating func retarget(_ roles: [String]) { targets = roles }

  /// How many 120 ms boundaries have passed (0 in the first step). A hair of tolerance so that
  /// a clock that adds 0.04 three times sits on the boundary, not just under it.
  public var steps: Int { Int((elapsed + 1e-9) / Self.step) }

  /// The index of the hot target; nil with no targets.
  public var hotIndex: Int? { targets.isEmpty ? nil : steps % targets.count }

  public var hot: String? { hotIndex.map { targets[$0] } }
}

/// How one role toggle is lit.
public enum MacroPulseLevel: Equatable, Sendable {
  case none
  /// `.pn-pulsing`: touched by a running macro.
  case dim
  /// `.pn-pulsing-hot`: the running light is on it.
  case hot
}

/// What the views draw for a deck: which macros are running, which roles pulse, which is hot.
public struct MacroPulseState: Equatable, Sendable {
  public var running: Set<NetMacro> = []
  public var pulsing: Set<String> = []
  public var hot: Set<String> = []

  public init(running: Set<NetMacro> = [], pulsing: Set<String> = [], hot: Set<String> = []) {
    self.running = running
    self.pulsing = pulsing
    self.hot = hot
  }

  public func isRunning(_ m: NetMacro) -> Bool { running.contains(m) }

  public func level(of role: String) -> MacroPulseLevel {
    if hot.contains(role) { return .hot }
    return pulsing.contains(role) ? .dim : .none
  }
}

/// The chases of one deck. `update` takes what the engine says and the time that passed; a
/// macro that appears starts a chase, one that disappears loses it.
public struct MacroChaseBoard: Equatable, Sendable {
  /// Running chases, in the order the macros appeared.
  public private(set) var chases: [MacroChase] = []
  public private(set) var running: [NetMacro] = []

  public init() {}

  public mutating func update(_ activity: MacroActivity, dt: Double) {
    running = activity.running
    // end on macro end
    chases.removeAll { c in !activity.running.contains(c.macro) }
    for m in activity.running {
      guard m.chaseTargets != nil else { continue }
      let roles = activity.targets[m] ?? []
      if let i = chases.firstIndex(where: { $0.macro == m }) {
        chases[i].advance(by: dt)
        chases[i].retarget(roles)
      } else {
        chases.append(MacroChase(macro: m, targets: roles))  // starts at step 0: no dt yet
      }
    }
  }

  public var state: MacroPulseState {
    var s = MacroPulseState(running: Set(running))
    for c in chases {
      s.pulsing.formUnion(c.targets)
      if let h = c.hot { s.hot.insert(h) }
    }
    return s
  }
}

/// The look of the pulse, in beats' CSS numbers.
public enum MacroPulseStyle {
  /// `rgba(233, 69, 96, …)`: the accent `#e94560` of every glow here.
  public static let color = ScopeColor(hex: "#e94560")!

  /// A `box-shadow`: `0 0 <blur>px <spread>px rgba(233, 69, 96, <alpha>)`.
  public struct Glow: Equatable, Sendable {
    public var spread: Double
    public var blur: Double
    public var alpha: Double
  }

  /// `.pn-pulsing`: `0 0 4px 1px rgba(233, 69, 96, 0.35)`.
  public static let dim = Glow(spread: 1, blur: 4, alpha: 0.35)
  /// `.pn-pulsing-hot`: `0 0 10px 3px rgba(233, 69, 96, 0.95)`.
  public static let hot = Glow(spread: 3, blur: 10, alpha: 0.95)

  public static func glow(_ level: MacroPulseLevel) -> Glow? {
    switch level {
    case .none: nil
    case .dim: dim
    case .hot: hot
    }
  }

  /// `.pn-macro-btn.running`: fill `#e94560`, white text, border `#f8b3c0`.
  public static let runningFill = color
  public static let runningBorder = ScopeColor(hex: "#f8b3c0")!

  /// `animation: pn-macro-pulse 1s ease-in-out infinite`.
  public static let runningPeriod = 1.0
  /// `@keyframes pn-macro-pulse`: `0%, 100% { 0 0 0 0 rgba(…, 0.7) }`,
  /// `50% { 0 0 10px 3px rgba(…, 0.95) }`.
  public static let runningRest = Glow(spread: 0, blur: 0, alpha: 0.7)
  public static let runningPeak = Glow(spread: 3, blur: 10, alpha: 0.95)

  /// The running button's glow at time `t` seconds: the keyframes, eased in and out within each
  /// half of the period (CSS applies `ease-in-out` between every pair of keyframes).
  public static func runningGlow(at t: Double) -> Glow {
    let p = (t / runningPeriod).truncatingRemainder(dividingBy: 1)
    let phase = p < 0 ? p + 1 : p
    let half = phase < 0.5 ? phase * 2 : (1 - phase) * 2  // 0 at the ends, 1 at the middle
    let k = easeInOut(half)
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * k }
    return Glow(
      spread: mix(runningRest.spread, runningPeak.spread),
      blur: mix(runningRest.blur, runningPeak.blur),
      alpha: mix(runningRest.alpha, runningPeak.alpha))
  }

  /// CSS `ease-in-out`: `cubic-bezier(0.42, 0, 0.58, 1)`.
  public static func easeInOut(_ x: Double) -> Double {
    cubicBezier(x, 0.42, 0, 0.58, 1)
  }

  /// y of the cubic Bezier through (0,0), (x1,y1), (x2,y2), (1,1) at progress `x`: bisection on
  /// the curve parameter.
  public static func cubicBezier(
    _ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double
  )
    -> Double
  {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    let target = x
    func at(_ t: Double, _ a: Double, _ b: Double) -> Double {
      let u = 1 - t
      return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }
    var lo = 0.0
    var hi = 1.0
    for _ in 0..<48 {
      let mid = (lo + hi) / 2
      if at(mid, x1, x2) < target { lo = mid } else { hi = mid }
    }
    return at((lo + hi) / 2, y1, y2)
  }
}
