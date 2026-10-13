import Testing

@testable import DJCore

// `DJMusicality.Fixes.space`: the send reverb, measured on stereo renders of small projects
// through a linear master. 120 BPM; a pad chord struck once and left to ring out.

private let sr = 48_000.0

private func ring(_ group: String, channel: Int, _ notes: [(step: Int, note: Int)], ms: Int)
  -> NetBundle
{
  var n = NetBundle.ring(64)
  for x in notes { n.bind(x.step, note: x.note, channel: channel, velocity: 100, duration: ms) }
  n.track.channel = channel
  n.track.group = group
  return n
}

/// One short pad chord on the first step of an 8-second ring (its own voice is gone, under
/// −120 dB, within a second), or one low note (C2).
private func padOnce(low: Bool = false) -> Project {
  var p = Project()
  p.tempo = 120
  let notes = low ? [(0, 36)] : [(0, 60), (1, 64), (2, 67)]
  p.nets["harmony"] = ring("harmony", channel: 7, notes, ms: low ? 400 : 100)
  return p
}

private func kickAndBass() -> Project {
  var p = Project()
  p.tempo = 120
  p.nets["kick"] = ring("drums", channel: 10, [0, 4, 8, 12].map { ($0, 36) }, ms: 50)
  p.nets["bass"] = ring("bass", channel: 6, [2, 6, 10, 14].map { ($0, 33) }, ms: 100)
  return p
}

private func render(_ p: Project, _ fixes: DJMusicality.Fixes, space: SpaceSpec? = nil)
  -> (l: [Float], r: [Float])
{
  var o = WaveOptions()
  o.master = "linear"
  o.musicality = fixes
  o.space = space
  let r = WaveRunner(sampleRate: sr, opts: o)
  r.load(prepared: WaveRunner.prepare(p, sampleRate: sr, opts: o))
  r.play()
  var l = [Float](repeating: 0, count: Int(4 * sr))
  var rr = l
  l.withUnsafeMutableBufferPointer { lb in
    rr.withUnsafeMutableBufferPointer { rb in
      var off = 0
      while off < lb.count {
        let n = min(256, lb.count - off)
        r.process(lb.baseAddress! + off, rb.baseAddress! + off, frames: n)
        off += n
      }
    }
  }
  return (l, rr)
}

private func mid(_ x: (l: [Float], r: [Float])) -> [Float] { zip(x.l, x.r).map { ($0 + $1) / 2 } }
private func side(_ x: (l: [Float], r: [Float])) -> [Float] { zip(x.l, x.r).map { ($0 - $1) / 2 } }
private func secs(_ s: Double) -> Int { Int(s * sr) }

/// A two-pole lowpass at `hz`, twice (fourth order).
private func lowpass(_ x: [Float], _ hz: Double) -> [Float] {
  var y = x.map(Double.init)
  for _ in 0..<2 {
    let b = biquad(type: "lowpass", fc: hz, q: 0.7071, sr: sr)
    var z1 = 0.0
    var z2 = 0.0
    for i in 0..<y.count {
      let v = y[i]
      let o = b[0] * v + z1
      z1 = b[1] * v - b[3] * o + z2
      z2 = b[2] * v - b[4] * o
      y[i] = o
    }
  }
  return y.map(Float.init)
}

struct SpaceTests {
  /// The pad rings on in the room after its own voice has died: dry, a second later there is
  /// nothing; with the room, a tail that falls at about the room's rate (60 dB per `seconds`).
  @Test func aPadLeavesATailThatDecaysAtTheRoomsRate() {
    let room = SpaceSpec(seconds: 2, wet: 0.4, damping: 7000)
    let dry = mid(render(padOnce(), .stereo))
    let wet = mid(render(padOnce(), [.stereo, .space], space: room))
    let gone = rmsDB(dry[secs(1.2)..<secs(1.4)])
    #expect(gone < -120)
    let early = rmsDB(wet[secs(1.2)..<secs(1.4)])
    let late = rmsDB(wet[secs(2.2)..<secs(2.4)])
    #expect(early > -90 && early > gone + 40, "tail at 1.2 s: \(early) dB")
    let fall = early - late
    #expect(fall > 20 && fall < 40, "fell \(fall) dB in a second (a 2 s room falls 30)")
  }

  /// The tail is wide (its side close to its mid), but a low note's (C2, 65 Hz) tail is in the
  /// middle below 100 Hz.
  @Test func theReturnIsWideAboveAndMonoBelow() {
    let room = SpaceSpec(seconds: 2, wet: 0.4, damping: 7000)
    let tail = secs(1.2)..<secs(2.0)
    let wet = render(padOnce(), [.stereo, .space], space: room)
    let width = rmsDB(side(wet)[tail]) - rmsDB(mid(wet)[tail])
    #expect(width > -8, "tail side/mid \(width) dB")
    let low = render(padOnce(low: true), [.stereo, .space], space: room)
    let m = lowpass(mid(low), 100)
    let lowWidth = rmsDB(lowpass(side(low), 100)[tail]) - rmsDB(m[tail])
    #expect(lowWidth < -25, "a C2 tail's side/mid below 100 Hz: \(lowWidth) dB")
  }

  /// Kick and bass send nothing: a rhythm section renders bit-identically with the room on.
  @Test func kickAndBassStayDry() {
    let a = render(kickAndBass(), .stereo)
    let b = render(kickAndBass(), [.stereo, .space], space: .forGenre("techno"))
    #expect(a.l == b.l && a.r == b.r)
  }

  /// Rooms by genre: longer for trance and ambient than for techno and funk; a deck's track
  /// plays its genre's room.
  @Test func roomsByGenre() {
    #expect(SpaceSpec.forGenre("ambient").seconds > SpaceSpec.forGenre("trance").seconds)
    #expect(SpaceSpec.forGenre("trance").seconds > SpaceSpec.forGenre("techno").seconds)
    #expect(SpaceSpec.forGenre("techno").seconds > SpaceSpec.forGenre("funk").seconds)
    #expect(SpaceSpec.forGenre("lofi").damping < SpaceSpec.forGenre("trance").damping)
    #expect(SpaceSpec.send(kind: "kick", group: "drums") == 0)
    #expect(SpaceSpec.send(kind: "tonal", group: "bass") == 0)
    #expect(
      SpaceSpec.send(kind: "tonal", group: "harmony")
        > SpaceSpec.send(kind: "snare", group: "drums"))
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: 22_050)
    #expect(track.prepared.space == SpaceSpec.forGenre("trance"))
    #expect(
      WaveRunner.prepare(padOnce(), sampleRate: 22_050, opts: WaveOptions()).space == nil)
  }
}

#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

struct SpaceRealTimeTests {
  /// The room renders without allocating: a whole song with the reverb running, in stereo.
  @Test(.enabled(if: optimized, "allocation is only meaningful in optimized builds"))
  func theRoomDoesNotAllocate() {
    let track = PreparedTrack(
      spec: TrackSpec(genre: "trance", seed: 42, structure: "minimal"), sampleRate: sr)
    let r = WaveRunner(sampleRate: sr, opts: .extended)
    r.load(prepared: track.prepared)
    r.play()
    var l = [Float](repeating: 0, count: 128)
    var rr = l
    l.withUnsafeMutableBufferPointer { lb in
      rr.withUnsafeMutableBufferPointer { rb in
        for _ in 0..<200 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
      }
    }
    let report = countAllocations {
      l.withUnsafeMutableBufferPointer { lb in
        rr.withUnsafeMutableBufferPointer { rb in
          for _ in 0..<3000 { r.process(lb.baseAddress!, rb.baseAddress!, frames: 128) }
        }
      }
    }
    #expect(track.prepared.space != nil)
    #expect(report.allocations == 0, "process allocated \(report.allocations) times")
  }
}
