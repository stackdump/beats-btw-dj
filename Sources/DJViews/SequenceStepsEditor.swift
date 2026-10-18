import DJCore
import SwiftUI

/// A sequence's steps as chips: tap one for ×1 → ×2 → ×4; right-click to move or remove it;
/// optionally an "Add a loop" menu for a new last step. Every change is `AppModel.editSequence`,
/// which remakes the sequence in its place under a new id; `follow` is given that id. Shared by
/// the Loops row's tile and the Soundboard's clip settings.
struct SequenceStepsEditor: View {
  /// The sequence's id.
  let id: String
  let steps: [StepState]
  let model: AppModel
  /// Show the "Add a loop" menu (the tile adds by dropping a clip on it instead).
  var addMenu = false
  /// Given the edited sequence's new id.
  var follow: (String) -> Void = { _ in }

  /// The steps as the engine takes them.
  static func sequenceSteps(_ steps: [StepState]) -> [SequenceStep] {
    steps.map { SequenceStep(clipID: $0.clipID, repeats: $0.repeats) }
  }

  /// A chip's tap: ×1 → ×2 → ×4 → ×1.
  static func nextRepeats(_ r: Int) -> Int { r >= 4 ? 1 : r * 2 }

  /// The loops "Add a loop" offers: every clip on the row but the sequence itself.
  static func addable(to id: String, in model: AppModel) -> [ClipState] {
    model.clips.filter { $0.id != id }
  }

  /// Rewrite sequence `id`'s steps; the remade sequence takes its place on the row under a new
  /// id, which `follow` is given (as `ClipSettingsView.crop` does for a crop). Only a clip new to
  /// the row is followed: an edit whose audio is already on the row (the engine then drops the
  /// edited one) leaves `follow` uncalled.
  static func edit(
    _ id: String, _ steps: [SequenceStep], in model: AppModel, follow: (String) -> Void
  ) {
    let before = Set(model.clips.map(\.id))
    let index = model.clips.firstIndex { $0.id == id }
    model.editSequence(id, steps)
    if let index, model.clips.indices.contains(index), !before.contains(model.clips[index].id) {
      follow(model.clips[index].id)
    }
  }

  var body: some View {
    FlowRow(spacing: 3) {
      ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
        Button("\(step.name)\(step.repeats > 1 ? " ×\(step.repeats)" : "")") {
          edited { $0[i].repeats = Self.nextRepeats($0[i].repeats) }
        }
        .buttonStyle(.bordered).controlSize(.mini)
        .foregroundStyle(step.name == "missing" ? Color.red : Color.primary)
        .contextMenu {
          if i > 0 { Button("Move earlier") { edited { $0.swapAt(i, i - 1) } } }
          if i < steps.count - 1 { Button("Move later") { edited { $0.swapAt(i, i + 1) } } }
          if steps.count > 1 { Button("Remove") { edited { $0.remove(at: i) } } }
        }
        .help("×1 → ×2 → ×4 (right-click: move or remove)")
      }
      if addMenu {
        let others = Self.addable(to: id, in: model)
        Menu {
          ForEach(others) { c in
            Button(c.title) { edited { $0.append(SequenceStep(clipID: c.id)) } }
          }
        } label: {
          Label("Add a loop", systemImage: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.mini)
        .disabled(others.isEmpty)
        .help("A new last step")
      }
    }
  }

  private func edited(_ change: (inout [SequenceStep]) -> Void) {
    var s = Self.sequenceSteps(steps)
    change(&s)
    Self.edit(id, s, in: model, follow: follow)
  }
}
