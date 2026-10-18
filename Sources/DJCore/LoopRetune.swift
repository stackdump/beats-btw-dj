import Foundation

// Tuning a loop's instruments without taking it again: a net take's provenance says what the
// deck was playing (its share, with any `tracks` override), where (the take's first beat) and
// how fast, so the same bars can be rendered again offline with other instruments on some
// channels. Nothing here touches a deck, the speakers or compose(): the share is composed as
// a deck composes it (`PreparedTrack`, `.extended(samplers:seed:)`) and played through a
// `WaveDeckSource` of its own.
//
// The render is the net source's output — before the deck's EQ, filter, reverb and fader —
// where a take is the deck after its EQ: with the EQ flat the two are the same audio. Played
// with the voices it was taken with, it nulls against the take (sampled instruments with round
// robin or modulation aside, which differ between any two renders).

public enum ClipRetune {
  /// Why a clip can't be rendered again.
  public enum Refusal: Error, Equatable, Sendable {
    /// Taken off a sample deck (or a crop of one): there is no net to play again.
    case notANet
    /// A sequence: several takes, each its own render.
    case sequence
    /// A take with macros running (a beat repeat, a filter sweep…): what they did depends on
    /// when they were fired, which provenance does not keep.
    case macros([String])
    /// Its provenance is missing or names no source.
    case noProvenance
    /// The song ended (or never reached the take's bars) in the render.
    case songEnded
    /// The take starts further into the song than a render will go for it.
    case tooFar
  }

  /// A clip's bars rendered again.
  public struct Retuned: @unchecked Sendable {
    /// Exactly the clip's beats, from its first beat, at its tempo.
    public let buffer: SampleBuffer
    /// The share it was played from: the take's, with `voices` merged into its `tracks`
    /// override (`DeckSourceDescriptor.withInstrument`).
    public let source: DeckSourceDescriptor
  }

  /// Bars of song played before the take's first beat and thrown away, so notes, the room and
  /// the echo already ringing when LOOP went down ring into the render too.
  static let prerollTicks = 32
  /// The furthest into a song a render goes (ticks, 16 a bar): a loop played for an hour is
  /// rendered from its top, and that is where it stops being worth it.
  static let maxTicks = 16 * 512

  /// Render `clip`'s bars again with `voices` (MIDI channel → beats instrument) over the
  /// instruments it was taken with, at `sampleRate`. The other channels play what they played.
  /// Pure: a fresh source and sampler bank, nothing shared with a deck. Off the main thread is
  /// fine (it composes and renders, which takes a while).
  ///
  /// The output is pre-EQ and pre-fader (see the top of this file). Refused for sample takes,
  /// crops of them, sequences and takes with macros running (`Refusal`).
  public static func render(clip: LoopClip, voices: [Int: String], sampleRate: Double) throws
    -> Retuned
  {
    try render(clip: clip, voices: voices, sampleRate: sampleRate, rolesOff: [])
  }

  /// `rolesOff`: more roles to leave silent, beside the take's own (the tests solo a part).
  static func render(
    clip: LoopClip, voices: [Int: String], sampleRate: Double, rolesOff: [String]
  ) throws -> Retuned {
    let take = try takeProvenance(clip)
    guard let taken = take["source"].flatMap(DeckSourceDescriptor.init(json:)) else {
      throw Refusal.noProvenance
    }
    switch taken {
    case .net, .rawNets: break
    case .sample, .none: throw Refusal.notANet
    }
    let macros = clip.originMacros
    guard macros.isEmpty else { throw Refusal.macros(macros) }
    var source = taken
    for (channel, instrument) in voices.sorted(by: { $0.key < $1.key }) {
      guard let s = source.withInstrument(instrument, channel: channel) else {
        throw Refusal.notANet
      }
      source = s
    }

    let startTick = Int((clip.startBeat * 4).rounded())
    let endTick = startTick + 4 * clip.beats
    guard startTick >= 0, endTick <= maxTicks else { throw Refusal.tooFar }
    // A deck's source, as `Deck` builds one, with its own sampler bank.
    let wave = WaveDeckSource(sampleRate: sampleRate, opts: .extended(samplers: nil))
    var opts = WaveOptions.extended(samplers: wave.samplers)  // seed: the track's (PreparedTrack)
    let from = max(0, startTick - prerollTicks)
    if source != taken {
      // the song's own levels, as the take had them (`Deck.sameSongOptions`): the loudness
      // gain, part trims, energy, room and echo are measured over the whole mix, so measured
      // again with another instrument they would move every part, not only its own
      guard let song = prepare(taken, from: from, sampleRate: sampleRate, opts: opts)?.prepared
      else { throw Refusal.notANet }
      opts.trackGain = song.gain
      opts.trackEnergy = song.energy
      opts.duckDepth = song.duckDepth
      opts.space = song.space
      opts.echo = song.echo
      opts.trackBalance = song.balance
      opts.trackRests = song.rests
    }
    let track = prepare(source, from: from, sampleRate: sampleRate, opts: opts)
    guard let track else { throw Refusal.notANet }
    wave.load(track.prepared)
    for role in Set(clip.originRolesOff + rolesOff).sorted() { wave.setRoleMuted(role, true) }
    let bpm = clip.originBPM ?? clip.bpm
    if bpm > 0, abs(bpm - track.played.tempo) > 1e-9 { wave.setTempo(bpm) }
    wave.play()

    // Play until the anchor of the tick after the take's last one: the take ran from the
    // downbeat anchor of its first beat to the one after its last, so the cut does too.
    let perTick = sampleRate * 60 / (max(bpm, 1) * 4)
    let limit = Int(Double(endTick + prerollTicks + 64) * perTick)
    var left: [Float] = []
    var right: [Float] = []
    var anchors: [TickAnchor] = []
    var cursor = 0
    var start: Int?
    var end: Int?
    let block = 512
    var l = [Float](repeating: 0, count: block)
    var r = [Float](repeating: 0, count: block)
    var done = 0
    var base = 0  // the frame of left[0]
    while end == nil || done < end! {
      guard done < limit, !wave.hasEnded else { throw Refusal.songEnded }
      l.withUnsafeMutableBufferPointer { lp in
        r.withUnsafeMutableBufferPointer { rp in
          wave.render(
            frames: block, left: lp.baseAddress!, right: rp.baseAddress!, startFrame: done)
        }
      }
      left += l
      right += r
      done += block
      anchors.removeAll(keepingCapacity: true)
      wave.anchors.drain(from: &cursor, into: &anchors)
      for a in anchors where !a.flags.contains(.swap) {
        // the counter after the tick: the step that begins at `frame` is tick - 1
        let step = Int(a.tick) - 1
        if step == startTick, start == nil { start = Int(a.frame) }
        if step == endTick, start != nil, end == nil { end = Int(a.frame) }
      }
      // until the take's first beat, keep only the last few blocks (a song played from its
      // top to a late take would otherwise be held whole)
      if start == nil, left.count > 8 * block {
        let drop = left.count - 4 * block
        left.removeFirst(drop)
        right.removeFirst(drop)
        base += drop
      }
      if done % (block * 64) == 0 { wave.drainRetired() }
    }
    wave.drainRetired()
    guard let start, let end, end > start, start >= base else { throw Refusal.songEnded }
    let range = (start - base)..<(end - base)
    let buffer = SampleBuffer(
      left: Array(left[range]), right: Array(right[range]), sampleRate: sampleRate)
    return Retuned(buffer: buffer, source: source)
  }

  /// `source` composed as a deck composes it, from tick `from` (a raw-`nets` share from its top).
  static func prepare(
    _ source: DeckSourceDescriptor, from: Int, sampleRate: Double, opts: WaveOptions
  ) -> PreparedTrack? {
    if case .net(let spec) = source {
      return PreparedTrack(spec: spec, sampleRate: sampleRate, opts: opts, startTick: from)
    }
    return PreparedTrack(source: source, sampleRate: sampleRate, opts: opts)
  }

  /// The provenance of the take `clip` is made of: through crops (their beats are already the
  /// clip's own `startBeat` and `beats`), never a sequence.
  static func takeProvenance(_ clip: LoopClip) throws -> JSONValue {
    var p = clip.provenance
    while let op = p?["op"]?.string {
      switch op {
      case "crop": p = p?["parent"]
      case "sequence": throw Refusal.sequence
      default: throw Refusal.noProvenance
      }
    }
    guard let p else { throw Refusal.noProvenance }
    if p["mode"]?.string == "sample" { throw Refusal.notANet }
    return p
  }
}
