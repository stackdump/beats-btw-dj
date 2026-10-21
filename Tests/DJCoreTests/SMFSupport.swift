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

// MusicXML fixtures. `\(…)` keeps them readable; two measures of 4/4, divisions 1.
let sampleMusicXML = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
  <score-partwise version="4.0">
    <work><work-title>Tiny Score</work-title></work>
    <part-list>
      <score-part id="P1"><part-name>Lead</part-name></score-part>
      <score-part id="P2"><part-name>Bass</part-name>
        <midi-instrument id="P2-I1"><midi-program>34</midi-program></midi-instrument></score-part>
      <score-part id="P3"><part-name>Kit</part-name>
        <score-instrument id="P3-I36"><instrument-name>Kick</instrument-name></score-instrument>
        <midi-instrument id="P3-I36"><midi-unpitched>36</midi-unpitched></midi-instrument>
        <midi-instrument id="P3-I39"><midi-unpitched>39</midi-unpitched></midi-instrument></score-part>
    </part-list>
    <part id="P1">
      <measure number="1">
        <attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
        <direction><sound tempo="90"/></direction>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration></note>
        <note><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration></note>
        <note><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration><tie type="start"/></note>
      </measure>
      <measure number="2">
        <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><tie type="stop"/></note>
        <note><rest/><duration>1</duration></note>
        <note><grace/><pitch><step>C</step><octave>5</octave></pitch></note>
        <note><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration></note>
        <note><chord/><pitch><step>B</step><octave>4</octave></pitch><duration>2</duration></note>
      </measure>
    </part>
    <part id="P2">
      <measure number="1">
        <attributes><divisions>1</divisions></attributes>
        <note><pitch><step>C</step><octave>2</octave></pitch><duration>4</duration></note>
      </measure>
      <measure number="2">
        <note><pitch><step>G</step><octave>2</octave></pitch><duration>4</duration></note>
      </measure>
    </part>
    <part id="P3">
      <measure number="1">
        <attributes><divisions>1</divisions></attributes>
        <note><unpitched><display-step>C</display-step><display-octave>5</display-octave></unpitched><duration>1</duration><instrument id="P3-I36"/></note>
        <note><rest/><duration>1</duration></note>
        <note><unpitched><display-step>C</display-step><display-octave>5</display-octave></unpitched><duration>1</duration><instrument id="P3-I39"/></note>
        <note><rest/><duration>1</duration></note>
      </measure>
    </part>
  </score-partwise>
  """

func sampleMusicXMLData() -> Data { Data(sampleMusicXML.utf8) }

func notMusicXMLData() -> Data { Data("<html><body/></html>".utf8) }

/// A zip with one deflated entry per file (what an .mxl is): local headers, a central
/// directory and the end record. CRCs are left 0: `MiniZip` doesn't check them.
func zipped(_ files: [(String, String)]) -> Data {
  func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
  func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
  var body: [UInt8] = []
  var central: [UInt8] = []
  for (name, text) in files {
    let raw = Data(text.utf8)
    let comp = (try? (raw as NSData).compressed(using: .zlib)) as Data? ?? raw
    let n = Array(name.utf8)
    let offset = body.count
    body += le32(0x0403_4B50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
    body += le32(comp.count) + le32(raw.count) + le16(n.count) + le16(0) + n + [UInt8](comp)
    central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0)
    central += le32(0) + le32(comp.count) + le32(raw.count) + le16(n.count)
    central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + n
  }
  var out = body + central
  out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
  out += le32(central.count) + le32(body.count) + le16(0)
  return Data(out)
}

func sampleMXLData() -> Data {
  zipped([
    (
      "META-INF/container.xml",
      """
      <?xml version="1.0"?><container><rootfiles>
      <rootfile full-path="score.xml" media-type="application/vnd.recordare.musicxml+xml"/>
      </rootfiles></container>
      """
    ),
    ("score.xml", sampleMusicXML),
  ])
}

/// Four single-line channels like a chorale: soprano, alto, tenor, bass, one bar of quarters each.
func fourVoiceMidi() -> Data {
  var f = SMF()
  f.track([(0, [0xFF, 0x51, 3, 0x07, 0xA1, 0x20])])
  for (ch, base) in [(0, 72), (1, 67), (2, 60), (3, 48)] {
    var ev: [(Int, [UInt8])] = []
    for beat in 0..<4 { ev += SMF.note(UInt8(ch), UInt8(base + beat), at: beat * 480, len: 400) }
    f.track(ev)
  }
  return f.data
}

func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "compositions-\(UUID().uuidString)", isDirectory: true)
}
