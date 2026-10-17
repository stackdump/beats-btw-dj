import DJCore
import SwiftUI
import Testing

@testable import DJViews

/// Per-loop FX in the UI: the pad's FX menu and the editor are the one poke `clipFx`, the pad
/// and the row show it, and the library saves it.
@MainActor
struct LoopFxViewTests {
  @Test func theFxMenuAndEditorAreTheClipFxPoke() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    let crunch = try #require(LoopFX.presets.first { $0.name == "Crunch" }).fx
    #expect(m.soundboardAction(.fx(crunch), id) == .clipFx(id: id, fx: crunch))
    #expect(m.soundPads.first?.fx.isActive == false, "no badge before")
    m.soundboard(.fx(crunch), id)
    m.poll()
    #expect(dj.clipFx(id) == crunch)
    #expect(m.clips.first?.fx == crunch && m.soundPads.first?.fx.isActive == true)
    // the editor's own call, and a preset off again
    var louder = crunch
    louder.drive = 15
    m.setClipFx(id, louder)
    m.poll()
    #expect(m.clips.first?.fx.drive == 15 && louder.presetName == nil)
    m.soundboard(.fx(LoopFX()), id)
    m.poll()
    #expect(m.soundPads.first?.fx.isActive == false && dj.clipFx(id) == LoopFX())
  }

  @Test func thePadAndTheEditorDraw() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.model()
    defer { dj.stop() }
    let id = try #require(m.clips.first?.id)
    m.setClipFx(id, LoopFX.presets[2].fx)
    m.poll()
    let clip = try #require(m.clips.first)
    let editor = ClipFxEditor(clip: clip, model: m).padding(12)
    #expect(renderPixels(editor, width: 400, height: 420) != nil)
    let pad = try #require(m.soundPads.first)
    #expect(renderPixels(SoundPadView(pad: pad), width: 180, height: 130) != nil)
  }
}

/// The FX section for a human: `make swift-shots SHOT_DIR=… FILTER=LoopFxShots`.
@MainActor
struct LoopFxShots {
  @Test func theSettingsFxSection() throws {
    let t = SoundboardTests()
    let (m, dj) = try t.pads(3)
    defer { dj.stop() }
    let ids = m.clips.map(\.id)
    m.renameClip(ids[0], "drums 1")
    let warm = LoopFX(drive: 12, mode: .tube, amount: 0.6, tone: 0.7, mix: 0.9, trim: -1.5)
    m.setClipFx(ids[0], warm)
    m.setClipFx(ids[1], LoopFX.presets[4].fx)
    m.soundboard(.toggle, ids[1])
    m.setShowSoundboard(true)
    m.poll()
    let clip = try #require(m.clips.first)
    saveWindowPNG(
      ClipFxEditor(clip: clip, model: m).padding(14).frame(width: 400, alignment: .topLeading)
        .background(Color(white: 0.12)),
      width: 400, height: 440, name: "loop-fx-section")
    saveWindowPNG(
      ClipSettingsView(id: .constant(ids[0]), model: m).background(Color(white: 0.12)),
      width: 400, height: 640, name: "loop-fx-settings")
    saveWindowPNG(
      SoundboardView(model: m).padding(12).background(Color(white: 0.1)),
      width: 720, height: 300, name: "loop-fx-pads")
  }
}
