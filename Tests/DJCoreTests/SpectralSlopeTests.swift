@preconcurrency import AVFoundation
import Testing

@testable import DJCore

// ROADMAP 6.6 (HF tilt, part a): measure before changing anything. `Spectrum`'s long-term
// slope (63 Hz … 8 kHz) and hfBump (12.5 / 16 kHz over the fit) per genre, synth voices and
// sampled, and the same for each part soloed, so the table in docs/musicality-notes.md §14 can
// name which voices carry a bright top. A report: it prints, and asserts only that the numbers
// are finite and that measuring leaves the parity path alone.

private let sr = 48_000.0

/// With `DJ_SPECTRAL_SURVEY=1` set, `SpectralSlopeSurveyTests` renders the whole table
/// (12 genres × synth / sampled × the mix and each part; minutes in release).
private let surveying = ProcessInfo.processInfo.environment["DJ_SPECTRAL_SURVEY"] != nil

/// The matrix's genres (scripts/musicality-matrix.py `GENRES`).
private let surveyGenres = [
  "techno", "house", "edm", "trance", "dnb", "dubstep", "synthwave", "lofi", "jazz", "funk",
  "bossa", "ambient",
]

/// The parts soloed (`RoleFilter` names: net ids and groups), and the file whose voice each
/// plays on a synth voice. `fills` are the `fill-N` chains (buildups, the section crash).
private let surveyParts: [(name: String, solo: Set<String>, synthFile: String)] = [
  ("kick", ["kick"], "Beats/Wave/WaveSynth.swift drumVoice"),
  ("snare", ["snare", "clap"], "Beats/Wave/WaveSynth.swift drumVoice"),
  ("hats", ["hihat"], "Beats/Wave/WaveSynth.swift drumVoice (hat / openhat)"),
  ("fills", [], "Beats/Wave/WaveSynth.swift drumVoice (crash)"),
  ("bass", ["bass"], "Musicality/SynthVoice.swift + Resources/voices/instruments.json"),
  ("harmony", ["harmony"], "Musicality/SynthVoice.swift + Resources/voices/instruments.json"),
  ("melody", ["melody"], "Musicality/SynthVoice.swift + Resources/voices/instruments.json"),
  ("arp", ["arp"], "Musicality/SynthVoice.swift + Resources/voices/instruments.json"),
]

/// A part carries the bump when its 12.5 / 16 kHz energy is at least this share of the mix's.
private let carryShare = 0.25

/// What one render's spectrum gives the table.
private struct SlopeRow {
  var slope: Double
  var bump: Double
  /// Linear power in `Spectrum.bumpBands` (sum of the bands' PSD), for shares between renders
  /// made at the same gain.
  var hfPower: Double
  var plays: Bool

  init(_ r: OfflineRender) {
    let s = Spectrum(left: r.left, right: r.right, sampleRate: r.sampleRate)
    slope = s.slopeDBPerOct
    bump = s.hfBumpDB
    hfPower = 0
    for (i, hz) in Spectrum.bandsHz.enumerated() where Spectrum.bumpBands.contains(hz) {
      hfPower += pow(10, s.ltasDB[i] / 10)
    }
    plays = s.ltasDB.contains { $0 > -150 }
  }
}

/// `genre` at `seed` as a deck plays it, from the top, for `seconds`: `.extended` (sampled on
/// the deck's bank, or synth voices), the loudness gain fixed at 1 and a linear master so the
/// mix and its solos are rendered at one gain (the parts' trims and energy curve are taken from
/// the whole project, `WaveRunner.prepare`), so each solo sits where it does in the mix.
@MainActor private func render(
  _ genre: String, seed: Double, sampled: Bool, solo: Set<String>?, seconds: Double
) -> (render: OfflineRender, track: PreparedTrack) {
  var deckOpts = WaveOptions.extended
  deckOpts.master = "linear"
  let source = WaveDeckSource(sampleRate: sr, opts: deckOpts)
  let spec = TrackSpec(genre: genre, seed: seed, structure: "standard")
  var filter: RoleFilter?
  if var names = solo {
    if names.isEmpty {
      names = Set(spec.project().nets.keys.filter { $0.hasPrefix("fill-") })
      if names.isEmpty { names = ["(no fills)"] }
    }
    filter = RoleFilter(solo: names)
  }
  var o = WaveOptions.extended(
    samplers: sampled ? source.samplers : nil, seed: seed, roleFilter: filter)
  o.master = "linear"
  o.trackGain = 1
  let track = PreparedTrack(spec: spec, sampleRate: sr, opts: o)
  return (OfflineRender(track: track, source: source, seconds: seconds), track)
}

private func f1(_ x: Double) -> String { String(format: "%.1f", x) }

@MainActor
@Suite struct SpectralSlopeTests {
  /// A mix and a soloed part read finite numbers, and the solo is part of the mix's top end.
  @Test func aMixAndASoloMeasureFinite() {
    let mix = SlopeRow(render("techno", seed: 42, sampled: false, solo: nil, seconds: 12).render)
    let hats = SlopeRow(
      render("techno", seed: 42, sampled: false, solo: ["hihat"], seconds: 12).render)
    #expect(mix.plays && hats.plays)
    for v in [mix.slope, mix.bump, hats.slope, hats.bump] { #expect(v.isFinite, "\(v)") }
    #expect(mix.hfPower > 0 && mix.hfPower.isFinite)
    #expect(hats.hfPower <= mix.hfPower * 1.5, "a solo is not louder up top than its mix")
  }

  /// Measuring touches neither the parity options nor what is composed: `WaveOptions()` stays
  /// beats' (no fixes, no filter, soft master), and a soloed render composes the same track
  /// (same share CID, same project) as the plain one.
  @Test func measuringLeavesParityAlone() {
    let parity = WaveOptions()
    #expect(parity.musicality.isEmpty)
    #expect(parity.roleFilter == nil)
    #expect(parity.trackGain == nil)
    #expect(parity.master == "soft")
    let spec = TrackSpec(genre: "techno", seed: 42, structure: "standard")
    let cid = BeatsCID.shareCID(spec.payload)
    let solo = render("techno", seed: 42, sampled: false, solo: ["hihat"], seconds: 1).track
    #expect(BeatsCID.shareCID(spec.payload) == cid)
    #expect(solo.spec.map { BeatsCID.shareCID($0.payload) } == cid)
    #expect(Set(solo.project.nets.keys) == Set(spec.project().nets.keys))
  }
}

/// The 6.6 table: per genre and voicing, the mix's slope and hfBump and the parts carrying its
/// 12.5 / 16 kHz energy; then per family (`BeatsTables.family(of:)`) the means. Seed 42, 60 s
/// from the top, 48 kHz. Printed for docs/musicality-notes.md §14.
@MainActor
@Suite struct SpectralSlopeSurveyTests {
  @Test(.enabled(if: surveying, "a measurement: DJ_SPECTRAL_SURVEY=1"))
  func perFamilySlopeAndHFBump() {
    let seconds = 60.0
    struct Acc {
      var slope: [Double] = []
      var bump: [Double] = []
      var carriers: [String: Int] = [:]
    }
    var families: [String: Acc] = [:]
    var lines: [String] = [
      "genre      voices  family  slope  hfBump  carriers (share of 12.5/16 kHz; part slope/bump)"
    ]
    var finite = true
    for genre in surveyGenres {
      let family = GrooveTemplate.familyNames[
        min(BeatsTables.shared.family(of: genre), GrooveTemplate.familyNames.count - 1)]
      for sampled in [false, true] {
        let (mixRender, track) = render(
          genre, seed: 42, sampled: sampled, solo: nil, seconds: seconds)
        let mix = SlopeRow(mixRender)
        finite = finite && mix.slope.isFinite && mix.bump.isFinite
        var carriers: [String] = []
        for part in surveyParts {
          let r = SlopeRow(
            render(genre, seed: 42, sampled: sampled, solo: part.solo, seconds: seconds).render)
          guard r.plays, mix.hfPower > 0 else { continue }
          finite = finite && r.slope.isFinite && r.bump.isFinite
          let share = r.hfPower / mix.hfPower
          if share >= carryShare {
            let onSampler = sampled && track.prepared.sampledGroups.values.contains(part.name)
            let file = onSampler ? "sampler (Audio/Sampler.swift, VoiceCatalog)" : part.synthFile
            carriers.append(
              "\(part.name) \(String(format: "%.2f", share)) (\(f1(r.slope))/\(f1(r.bump))) [\(file)]"
            )
            families["\(family) \(sampled ? "sampled" : "synth")", default: Acc()].carriers[
              part.name, default: 0] += 1
          }
        }
        let key = "\(family) \(sampled ? "sampled" : "synth")"
        families[key, default: Acc()].slope.append(mix.slope)
        families[key, default: Acc()].bump.append(mix.bump)
        lines.append(
          genre.padding(toLength: 11, withPad: " ", startingAt: 0)
            + (sampled ? "sampled " : "synth   ")
            + family.padding(toLength: 7, withPad: " ", startingAt: 0)
            + String(format: " %6.2f  %6.2f  ", mix.slope, mix.bump)
            + (carriers.isEmpty ? "—" : carriers.joined(separator: "; ")))
      }
    }
    print("6.6 spectral slope (seed 42, \(Int(seconds)) s, 48 kHz, linear master, gain 1)")
    for l in lines { print(l) }
    print("family           n  slope dB/oct  hfBump dB  parts carrying the bump (genres)")
    for key in families.keys.sorted() {
      let a = families[key]!
      let n = Double(a.slope.count)
      let carriers = a.carriers.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }
      print(
        key.padding(toLength: 16, withPad: " ", startingAt: 0)
          + String(
            format: " %d  %12.2f  %9.2f  ", a.slope.count, a.slope.reduce(0, +) / n,
            a.bump.reduce(0, +) / n)
          + (carriers.isEmpty ? "—" : carriers.joined(separator: ", ")))
    }
    #expect(finite, "every slope and hfBump is finite")
    #expect(!families.isEmpty)
  }
}
