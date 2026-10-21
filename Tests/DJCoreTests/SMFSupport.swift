import Foundation

// Builds Standard MIDI Files for MidiImportTests. Kept out of files that `import Testing`
// (Foundation next to Testing needs the Xcode-only overlay).

/// A tiny SMF writer: format 1, 480 ticks per quarter.
struct SMF {
  var tracks: [[UInt8]] = []

  static func vlq(_ v: Int) -> [UInt8] {
    var out = [UInt8(v & 0x7F)]
    var n = v >> 7
    while n > 0 {
      out.insert(UInt8(n & 0x7F) | 0x80, at: 0)
      n >>= 7
    }
    return out
  }

  /// events: (absolute tick, bytes), written in tick order with delta times.
  mutating func track(_ events: [(Int, [UInt8])]) {
    var body: [UInt8] = []
    var last = 0
    for (t, e) in events.sorted(by: { $0.0 < $1.0 }) {
      body += Self.vlq(t - last) + e
      last = t
    }
    body += [0x00, 0xFF, 0x2F, 0x00]
    tracks.append(body)
  }

  var data: Data {
    var d: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, UInt8(tracks.count), 0x01, 0xE0]
    for t in tracks {
      let n = t.count
      d +=
        Array("MTrk".utf8) + [
          UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255),
        ]
      d += t
    }
    return Data(d)
  }

  static func note(_ ch: UInt8, _ pitch: UInt8, at t: Int, len: Int, vel: UInt8 = 100) -> [(
    Int, [UInt8]
  )] {
    [(t, [0x90 | ch, pitch, vel]), (t + len, [0x80 | ch, pitch, 0])]
  }
}

/// Two bars of 4/4 at 100 BPM: drums, a bass, a single-note lead, a three-note pad.
func sampleMidi() -> Data {
  var f = SMF()
  f.track([
    (0, [0xFF, 0x03, 4] + Array("Demo".utf8)),
    (0, [0xFF, 0x51, 3, 0x09, 0x27, 0xC0]),  // 600000 µs = 100 BPM
    (0, [0xFF, 0x58, 4, 4, 2, 24, 8]),
  ])
  var drums: [(Int, [UInt8])] = []
  for beat in 0..<8 {
    drums += SMF.note(9, 36, at: beat * 480, len: 60)
    if beat % 2 == 1 { drums += SMF.note(9, 38, at: beat * 480, len: 60) }
  }
  drums += SMF.note(9, 49, at: 0, len: 60)  // a crash: no role
  f.track(drums)
  f.track(
    [(0, [0xC1, 33])] + SMF.note(1, 36, at: 0, len: 480) + SMF.note(1, 43, at: 960, len: 480))
  f.track(
    SMF.note(2, 72, at: 0, len: 240) + SMF.note(2, 76, at: 480, len: 240)
      + SMF.note(2, 79, at: 1920, len: 480))
  var pad: [(Int, [UInt8])] = [(0, [0xC3, 89])]
  for p: UInt8 in [60, 64, 67] { pad += SMF.note(3, p, at: 0, len: 1920) }
  for p: UInt8 in [57, 60, 64] { pad += SMF.note(3, p, at: 1920, len: 1920) }
  f.track(pad)
  return f.data
}

func junkData() -> Data { Data("hello world, not midi".utf8) }

func smpteVariantOfSample() -> Data {
  var b = Array(sampleMidi())
  b[12] = 0xE7
  b[13] = 0x28
  return Data(b)
}

func noteLessMidi() -> Data {
  var f = SMF()
  f.track([(0, [0xFF, 0x51, 3, 7, 0xA1, 0x20])])
  return f.data
}
