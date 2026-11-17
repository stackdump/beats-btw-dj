import DJRust
import Foundation

// The Perform page's state and rules (djandroid Perform.kt, at the rev in rust/PINS): the moves
// djrust's `djhost::perform` offers (`Player.movesCatalog`), what is armed or running
// (`movesState`), each move's settings, and the last refusal by kind. The scheduler, the moves
// and the harmonic hint are the engine's; only the page's bookkeeping is here.

/// One move's settings on the Perform page: its deck ("A" / "B"), its bars and, for a phrase
/// sync, its action ("seed" or "cut").
public struct MoveRow: Equatable, Sendable {
  public var deck: String
  public var bars: Int
  public var action: String
  public init(_ deck: String, _ bars: Int, _ action: String = "seed") {
    self.deck = deck
    self.bars = bars
    self.action = action
  }
}

/// The page (djandroid PerformUi): the catalogue, the engine's state, the rows, the refusals.
struct PerformUI: Equatable {
  var catalog: [MoveInfo] = []
  var state: PerformState?
  var rows: [String: MoveRow] = [:]
  var notes: [String: String] = [:]
  var busy: Bool { state?.active.isEmpty == false }
}

/// The page's rules, apart from SwiftUI and the engine (unit tested, as djandroid's PerformRulesTest).
public enum PerformRules {
  /// The incoming deck of a bass swap is usually B; the rest act on A until changed (as the desktop).
  public static func defaultDeck(_ kind: String) -> String { kind == "bass_swap" ? "B" : "A" }

  public static func defaultRow(_ m: MoveInfo) -> MoveRow { MoveRow(defaultDeck(m.kind), Int(m.defaultBars)) }

  /// A row as saved ("B:16:cut"), back; nil when it does not parse or offers no such bars.
  public static func parseRow(_ s: String?, _ m: MoveInfo) -> MoveRow? {
    guard let p = s?.split(separator: ":", omittingEmptySubsequences: false).map(String.init), p.count == 3,
      deckNames.contains(p[0]), let bars = Int(p[1]), m.barChoices.contains(where: { Int($0) == bars }),
      p[2] == "seed" || p[2] == "cut"
    else { return nil }
    return MoveRow(p[0], bars, p[2])
  }

  public static func rowText(_ r: MoveRow) -> String { "\(r.deck):\(r.bars):\(r.action)" }

  /// The move of `kind` in flight for this row: any deck for a one-at-a-time move.
  public static func flight(_ active: [MoveStatus], _ kind: String, _ oneAtATime: Bool, _ deck: String) -> MoveStatus? {
    active.first { $0.kind == kind && (oneAtATime || $0.deck == deck) }
  }

  /// The last word on `kind` for this row (a one-at-a-time move's is under "*").
  public static func lastWord(_ last: [MoveWord], _ kind: String, _ oneAtATime: Bool, _ deck: String) -> String? {
    let d = oneAtATime ? "*" : deck
    return last.first { $0.kind == kind && $0.deck == d }?.text
  }

  /// A move's one caption line: what it is doing (and in how many beats), else a refusal, else
  /// what it did last.
  public static func caption(_ flight: MoveStatus?, _ note: String?, _ last: String?) -> String {
    if let f = flight { return f.text + (f.beatsLeft.map { " · \(Int($0.rounded(.up))) beats" } ?? "") }
    return note ?? last ?? ""
  }

  /// The light: "armed" (amber), "running" (green), nil (off).
  public static func light(_ flight: MoveStatus?) -> String? { flight?.phase }

  /// The read-only harmonic hint: both keys and how they mix.
  public static func hintKeys(_ h: HarmonicHint) -> String { "A \(h.a ?? "?") · B \(h.b ?? "?")" }

  public static func hintWords(_ h: HarmonicHint) -> String {
    switch h.compat {
    case "same": "same key"
    case "fifth": "a fifth: mixes"
    case "relative": "relative: mixes"
    case "clash": "clash"
    default: "keys unknown"
    }
  }

  /// "phrase", "sweep", "tail", "step": the words before the bars chips (the engine's meaning, short).
  public static func barsWord(_ m: MoveInfo) -> String {
    let w = m.barsMeaning.components(separatedBy: " (")[0]
    return w == "bars per step" ? "step" : w
  }

  /// The moves between the decks, then the moves out of one (the desktop window's order within each).
  public static let transitions = ["bass_swap", "phrase_sync", "vocoder_handoff"]
  public static let exits = ["filter_exit", "echo_out", "loop_roll"]
}

extension RustDJModel {
  /// The catalogue and the saved rows, once the engine is up.
  func startPerform(_ p: Player) {
    let cat = p.movesCatalog()
    perform.catalog = cat
    perform.rows = Dictionary(
      uniqueKeysWithValues: cat.map { m in
        (m.kind, PerformRules.parseRow(prefs.string(forKey: "move/\(m.kind)"), m) ?? PerformRules.defaultRow(m))
      })
  }

  func moveRow(_ m: MoveInfo) -> MoveRow { perform.rows[m.kind] ?? PerformRules.defaultRow(m) }

  /// A move's deck, bars or action, kept across launches.
  func setMoveRow(_ m: MoveInfo, _ f: (inout MoveRow) -> Void) {
    var r = moveRow(m)
    f(&r)
    perform.rows[m.kind] = r
    perform.notes[m.kind] = nil
    prefs.set(PerformRules.rowText(r), forKey: "move/\(m.kind)")
  }

  /// A move's pad: arm it with its row, or cancel it while it is armed or running. A refusal
  /// (no track on the deck, a one-at-a-time move already armed) is shown in its caption.
  func toggleMove(_ m: MoveInfo) {
    guard let p = player else { return }
    let row = moveRow(m)
    let flight = PerformRules.flight(perform.state?.active ?? [], m.kind, m.oneAtATime, row.deck)
    let kind = m.kind
    let action = m.hasAction ? row.action : ""
    engineQueue.async {
      var note: String?
      do {
        if let f = flight {
          _ = try p.movesCancel(id: f.id)
        } else {
          _ = try p.movesArm(kind: kind, deck: row.deck, bars: UInt32(row.bars), action: action)
        }
      } catch let DjError.Perform(msg) {
        note = msg
      } catch {
        note = "\(error)"
      }
      let st = try? p.movesState()
      Task { @MainActor in
        if let st { self.perform.state = st }
        self.perform.notes[kind] = note
      }
    }
  }

  /// Let go of every move in flight.
  func cancelAllMoves() { act { try $0.movesCancelAll() } }
}
