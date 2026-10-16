@preconcurrency import AVFoundation
import AudioToolbox

/// A channel's reverb: Apple's AUReverb2 between the EQ and the fader (and the cue send), so the
/// headphones hear it too. LOOP record listens at the EQ's own output, before it: takes are dry,
/// and a clip gets its room from the channel it plays on.
///
/// Three knobs, 0…1: `wet` (dry/wet mix; at 0 the unit is bypassed, bit-transparent and free),
/// `size` (decay 0.25…8 s, with the early reflections spreading out as it grows) and `tone`
/// (how long the highs ring against the lows: 0 dark, 1 bright). Main thread.
public final class DeckReverb {
  public let node: AVAudioUnitEffect

  public var wet = 0.0 { didSet { apply() } }
  public var size = 0.5 { didSet { apply() } }
  public var tone = 0.5 { didSet { apply() } }

  init() {
    node = AVAudioUnitEffect(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Reverb2,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
        componentFlagsMask: 0))
    apply()
  }

  /// Decay of the lows, seconds.
  public var decaySeconds: Double { 0.25 * pow(32, min(1, max(0, size))) }

  /// Is it doing anything?
  public var isOn: Bool { wet >= 0.005 }

  private func set(_ id: AudioUnitParameterID, _ v: Double) {
    AudioUnitSetParameter(node.audioUnit, id, kAudioUnitScope_Global, 0, Float(v), 0)
  }

  private func apply() {
    node.bypass = !isOn
    let decay = decaySeconds
    let s = min(1, max(0, size))
    set(kReverb2Param_DryWetMix, min(1, max(0, wet)) * 100)
    set(kReverb2Param_Gain, 0)
    set(kReverb2Param_MinDelayTime, 0.004 + 0.012 * s)
    set(kReverb2Param_MaxDelayTime, 0.03 + 0.12 * s)
    set(kReverb2Param_DecayTimeAt0Hz, decay)
    set(kReverb2Param_DecayTimeAtNyquist, decay * (0.06 + 0.94 * min(1, max(0, tone))))
  }

  /// The unit's own value of a parameter (tests).
  func parameter(_ id: AudioUnitParameterID) -> Double {
    var v: Float = 0
    AudioUnitGetParameter(node.audioUnit, id, kAudioUnitScope_Global, 0, &v)
    return Double(v)
  }
}
