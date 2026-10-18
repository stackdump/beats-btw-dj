import Darwin
import Testing

@testable import DJCore

/// `Translation`: the device curves and the mono fold, against signals whose fate is known.
struct TranslationTests {
  let sr = 48_000.0
  let seconds = 2.0

  func sine(_ hz: Double, amp: Double = 0.25) -> [Float] {
    (0..<Int(seconds * sr)).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / sr)) }
  }

  /// A band-limited sawtooth (every harmonic under Nyquist, at 1/n).
  func saw(_ hz: Double, amp: Double = 0.2) -> [Float] {
    let harmonics = Int(sr / 2 / hz)
    return (0..<Int(seconds * sr)).map { i in
      let t = Double(i) / sr
      var y = 0.0
      for n in 1...harmonics { y += sin(2 * Double.pi * hz * Double(n) * t) / Double(n) }
      return Float(amp * y * 2 / Double.pi)
    }
  }

  @Test func subBassIsFlaggedOnThePhone() {
    let bass = sine(45)
    let r = Translation.analyse(part: "bass", left: bass, right: bass, sampleRate: sr)
    let phone = r.devices["phone"]!
    #expect(phone.flagged)
    #expect(phone.levelDB < -Translation.flagDB)
    #expect(r.flags.contains("phone"))
    #expect(!r.flags.contains("mono"))
    #expect(!r.devices["headphones"]!.flagged)
  }

  @Test func sawOnTheSameNoteKeepsItsHarmonicsOnThePhone() {
    // A1 = 55 Hz: the fundamental goes, the harmonics above 350 Hz carry it
    let bass = saw(55)
    let r = Translation.analyse(part: "bass", left: bass, right: bass, sampleRate: sr)
    #expect(!r.devices["phone"]!.flagged)
    #expect(r.devices["phone"]!.levelDB > -Translation.flagDB)
    #expect(r.flags.isEmpty)
  }

  @Test func oppositePolarityChannelsAreFlaggedInMono() {
    let l = sine(440)
    let r = l.map { -$0 }
    let rep = Translation.analyse(part: "pad", left: l, right: r, sampleRate: sr)
    #expect(rep.monoFoldLossDB <= -Translation.flagDB)
    #expect(rep.flags.contains("mono"))
    // the phone folds to mono too
    #expect(rep.flags.contains("phone"))
    // headphones and monitors are stereo: nothing lost there
    #expect(!rep.devices["headphones"]!.flagged)
    #expect(!rep.devices["monitors"]!.flagged)
  }

  @Test func centredPartFoldsWithoutLoss() {
    let x = sine(440)
    #expect(abs(Translation.monoFoldLossDB(left: x, right: x)) < 0.01)
    let rep = Translation.analyse(part: "lead", left: x, right: x, sampleRate: sr)
    #expect(rep.flags.isEmpty)
    // 440 Hz is inside every curve's passband: within 1.5 dB everywhere
    for d in Translation.devices { #expect(abs(rep.devices[d.name]!.levelDB) < 1.5) }
  }

  @Test func headphonesLiftTheBass() {
    let x = sine(40)
    let rep = Translation.analyse(part: "bass", left: x, right: x, sampleRate: sr)
    #expect(rep.devices["headphones"]!.levelDB > 2.5)
  }

  @Test func everyDeviceNamesItsSource() {
    #expect(Translation.devices.map(\.name) == ["phone", "headphones", "monitors"])
    for d in Translation.devices { #expect(!d.source.isEmpty) }
  }

  @Test func reportOrdersPartsAndMeasuresAgainstTheMix() {
    let bass = sine(45)
    let lead = sine(880, amp: 0.125)
    let mix = zip(bass, lead).map { $0 + $1 }
    let parts = Translation.report(
      ["mix": (mix, mix), "lead": (lead, lead), "bass": (bass, bass)], sampleRate: sr)
    #expect(parts.map(\.part) == ["bass", "lead"])
    for p in parts { #expect(p.vsMixDB! < 0) }
    #expect(parts[0].flags == ["phone"])
    #expect(parts[1].flags.isEmpty)
    #expect(parts[0].dictionary["devices"] != nil)
  }
}
