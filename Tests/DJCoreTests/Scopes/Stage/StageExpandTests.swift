import Testing

@testable import DJCore

// The expand-variants toggle (SPEC mode 8): every riff-group variant gets a panel.

@MainActor
struct StageExpandTests {
  @Test func expandingShowsEveryVariant() throws {
    let h = try StageHarness()
    defer { h.stop() }
    h.run(0.3)
    let epoch = h.ctx.epoch
    h.model.settings.expandVariants = true
    h.run(0.1)
    let c = h.ctx
    // kick 2 + hihat 2 + snare + harmony + bass 14 + melody 16 = 36; hit tracks are muted
    #expect(c.panels.count == 36 && c.expandVariants)
    #expect(Set(c.panels.map(\.netId)).count == 36)
    #expect(c.epoch == epoch + 1)
    #expect(c.layout.showsMeta == false, "more than 16 panels: no meta-net")
    // an expanded panel never flips: each variant owns its panel
    h.deck.wave.setMute("bass-3", false)
    h.run(0.1)
    #expect(h.ctx.panels.contains { $0.id == "A/bass-0" && $0.netId == "bass-0" })
    h.model.settings.expandVariants = false
    h.run(0.1)
    #expect(h.ctx.panels.count == 6 && h.ctx.epoch == epoch + 2)
  }
}
