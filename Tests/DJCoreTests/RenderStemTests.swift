import Testing

@testable import DJCore

// `djctl render --mute / --solo / --options / --cohesion` (RenderRequest): the parsing, the
// plain request staying the render it was, and a soloed bass being a bass stem.

private let sr = 48_000.0

/// `request` rendered offline as `djctl render --synth` does, for `seconds`.
@MainActor private func render(_ request: RenderRequest, seconds: Double) throws -> OfflineRender {
  let source = WaveDeckSource(sampleRate: sr, opts: .extended)
  let opts = request.applied(to: .extended(samplers: nil))
  let track = PreparedTrack(spec: try request.spec(), sampleRate: sr, opts: opts)
  return OfflineRender(track: track, source: source, seconds: seconds)
}

@Suite struct RenderStemTests {
  @Test func emptyFlagsAreNoFilter() {
    #expect(RenderRequest.filter(mute: nil, solo: nil) == nil)
    #expect(RenderRequest.filter(mute: "", solo: nil) == nil)
    #expect(RenderRequest(genre: "techno", seed: 42, filter: RoleFilter()).filter == nil)
  }

  @Test func muteAndSoloListsParse() {
    let f = RenderRequest.filter(mute: "hats, kick", solo: "bass")
    #expect(f == RoleFilter(mute: ["hats", "kick"], solo: ["bass"]))
    #expect(RenderRequest.filter(mute: nil, solo: "drums,bass")?.solo == ["drums", "bass"])
  }

  @Test func optionsMustBeAnObject() throws {
    #expect(try RenderRequest.options(nil) == nil)
    #expect(throws: (any Error).self) { try RenderRequest.options("[1, 2]") }
    #expect(throws: (any Error).self) { try RenderRequest.options("{not json") }
    let o = try #require(try RenderRequest.options(#"{"hook": true}"#))
    #expect(o["hook"]?.bool == true)
  }

  @Test func unknownOptionIsRefused() throws {
    let r = RenderRequest(
      genre: "techno", seed: 42, options: try RenderRequest.options(#"{"nope": 1}"#))
    #expect(throws: ComposeOptions.Invalid.self) { try r.spec() }
  }

  @Test func plainRequestIsThePlainSpec() throws {
    let r = RenderRequest(genre: "techno", seed: 42, structure: "standard")
    #expect(try r.spec() == TrackSpec(genre: "techno", seed: 42, structure: "standard"))
    #expect(r.applied(to: .extended).roleFilter == nil)
    #expect(r.reportKeys(try r.spec()).isEmpty)
  }

  @Test func cohesionAndOptionsReachTheSpec() throws {
    let r = RenderRequest(
      genre: "techno", seed: 42, cohesion: "v1",
      options: try RenderRequest.options(#"{"ghostNotes": 0.5}"#))
    let spec = try r.spec()
    #expect(spec.cohesion == "v1")
    #expect(spec.extra["ghost-notes"]?.double == 0.5)
    let keys = r.reportKeys(spec)
    #expect((keys["options"] as? [String: Any])?["ghostNotes"] as? Double == 0.5)
    #expect(keys["cohesion"] as? String == "v1")
  }

  @Test func filterReachesEveryRenderAndTheReport() throws {
    let f = RenderRequest.filter(mute: "hats", solo: "bass")
    let r = RenderRequest(genre: "techno", seed: 42, filter: f)
    #expect(r.applied(to: .extended).roleFilter == f)
    let filter = try #require(r.reportKeys(try r.spec())["filter"] as? [String: Any])
    #expect(filter["solo"] as? [String] == ["bass"])
    #expect(filter["mute"] as? [String] == ["hats"])
  }

  @MainActor @Test func noFilterRendersTheSameBytes() throws {
    let plain = try render(RenderRequest(genre: "techno", seed: 42), seconds: 4)
    let empty = try render(
      RenderRequest(
        genre: "techno", seed: 42, filter: RenderRequest.filter(mute: "", solo: nil)),
      seconds: 4)
    #expect(sameSamples(plain.left, empty.left) == .identical)
    #expect(sameSamples(plain.right, empty.right) == .identical)
  }

  @MainActor @Test func soloBassIsABassStem() throws {
    let r = RenderRequest(
      genre: "techno", seed: 42, filter: RenderRequest.filter(mute: nil, solo: "bass"))
    let m = try render(r, seconds: 10).metrics
    let low = (m.bands["sub"] ?? 0) + (m.bands["low"] ?? 0)
    #expect(m.rmsDB > -60, "the bass stem plays")
    // ≥ 0.75: the fast-mode 0.8 was never measured. techno 42's soloed synth bass measures
    // 0.787 (sub 0.12, low 0.66; lowMid 0.155 is its saw's harmonics), the same with or
    // without `.unison`, `.kickTune` or `.energy`; `.bassLine`'s line is what lifts it out of
    // the sub (0.848 without it), as it does in every render, so a bass stem still clears
    // three quarters by a margin
    #expect(low >= 0.75, "sub + low = \(low)")
  }
}
