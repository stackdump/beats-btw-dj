import Foundation

// MusicXML (`.musicxml`, `.xml`, and the zipped `.mxl`) → the same `MidiImport.Parsed` a MIDI
// file gives, so one converter (`MidiImport.convert`) quantises it, sorts the roles and reports.
// Reads score-partwise documents: each part's measures, `divisions`, the first time signature,
// `<sound tempo>`, notes with `<chord/>`, ties, `<backup>` / `<forward>`, written→sounding
// transposition, one source per (part, staff), and unpitched parts as drums by
// `<midi-unpitched>`. Grace notes, repeats and tempo changes after the first are counted, not
// played (the report says so). Time becomes 480 ticks per quarter.

public enum MusicXMLImport {
  static let ticksPerQuarter = 480

  // MARK: .mxl container

  /// The score inside a zipped `.mxl`: META-INF/container.xml names the root file.
  public static func unpack(mxl data: Data) throws -> Data {
    let zip = try MiniZip(data)
    guard let container = try zip.read("META-INF/container.xml") else {
      throw MidiImportError.bad("the .mxl has no META-INF/container.xml")
    }
    let tree = try XMLNode.parse(container)
    guard let path = tree.find("rootfile")?.attrs["full-path"], let xml = try zip.read(path) else {
      throw MidiImportError.bad("the .mxl's container names no readable score file")
    }
    return xml
  }

  // MARK: parse

  public static func parse(_ data: Data) throws -> MidiImport.Parsed {
    var bytes = data
    if bytes.starts(with: [0x50, 0x4B]) { bytes = try unpack(mxl: bytes) }
    let root = try XMLNode.parse(bytes)
    guard root.name == "score-partwise" else {
      throw MidiImportError.bad(
        root.name == "score-timewise"
          ? "score-timewise MusicXML is not supported (re-export as partwise)"
          : "not a MusicXML score (root element \(root.name))")
    }

    var out = MidiImport.Parsed(
      format: 1, ticksPerQuarter: ticksPerQuarter, tempos: [], timeSignature: nil,
      title: root.find("work-title")?.text.nilIfEmpty
        ?? root.find("movement-title")?.text.nilIfEmpty,
      sources: [], lastTick: 0, warnings: [])

    // score-part id → name, GM program (0-based), midi-unpitched by instrument id
    var partName: [String: String] = [:]
    var partProgram: [String: Int] = [:]
    var unpitched: [String: Int] = [:]  // "<instrument id>" → GM note (1-based in the file)
    for sp in root.find("part-list")?.all("score-part") ?? [] {
      let id = sp.attrs["id"] ?? ""
      partName[id] = sp.child("part-name")?.text.nilIfEmpty ?? id
      for mi in sp.all("midi-instrument") {
        if let prog = mi.child("midi-program")?.int, partProgram[id] == nil {
          partProgram[id] = max(0, prog - 1)
        }
        if let u = mi.child("midi-unpitched")?.int, let iid = mi.attrs["id"] {
          unpitched[iid] = max(0, u - 1)
        }
      }
    }

    var skipped: [String: Int] = [:]
    for (partIndex, part) in root.all("part").enumerated() {
      let id = part.attrs["id"] ?? "P\(partIndex + 1)"
      var divisions = 1.0
      var transpose = 0
      var measureStart = 0.0  // quarters
      var streams: [String: (notes: [MidiImport.RawNote], drums: Bool, staff: Int)] = [:]
      var order: [String] = []
      var open: [String: Int] = [:]  // "<stream>|<pitch>" → index of a note waiting for its tie stop

      for measure in part.all("measure") {
        var cursor = 0.0  // divisions
        var reached = 0.0
        var lastStart = 0.0
        func tick(_ div: Double) -> Int {
          Int(((measureStart + div / divisions) * Double(ticksPerQuarter)).rounded())
        }
        func tempo(from node: XMLNode, at div: Double) {
          if let t = node.attrs["tempo"].flatMap(Double.init), t > 0 {
            out.tempos.append((tick(div), Int((60_000_000 / t).rounded())))
          }
        }
        for el in measure.children {
          switch el.name {
          case "attributes":
            if let d = el.child("divisions")?.double, d > 0 { divisions = d }
            if out.timeSignature == nil, let t = el.child("time"),
              let n = t.child("beats")?.int, let d = t.child("beat-type")?.int
            {
              out.timeSignature = (n, d)
            }
            if let t = el.child("transpose") {
              transpose =
                (t.child("chromatic")?.int ?? 0) + 12 * (t.child("octave-change")?.int ?? 0)
            }
          case "direction":
            for s in el.descendants("sound") { tempo(from: s, at: cursor) }
          case "sound":
            tempo(from: el, at: cursor)
          case "backup":
            cursor -= el.child("duration")?.double ?? 0
          case "forward":
            cursor += el.child("duration")?.double ?? 0
            reached = max(reached, cursor)
          case "barline":
            if el.child("repeat") != nil || el.child("ending") != nil {
              skipped["repeatsNotExpanded", default: 0] += 1
            }
          case "note":
            let dur = el.child("duration")?.double ?? 0
            let isChord = el.child("chord") != nil
            let start = isChord ? lastStart : cursor
            defer {
              if !isChord {
                lastStart = cursor
                cursor += dur
              }
              reached = max(reached, cursor)
            }
            if el.child("rest") != nil { continue }
            if el.child("grace") != nil {
              skipped["graceNotes", default: 0] += 1
              continue
            }
            let staff = el.child("staff")?.int ?? 1
            var pitch: Int
            let drums = el.child("unpitched") != nil
            if let p = el.child("pitch"), let step = p.child("step")?.text,
              let octave = p.child("octave")?.int
            {
              let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][step] ?? 0
              let alter = Int((p.child("alter")?.double ?? 0).rounded())
              pitch = (octave + 1) * 12 + base + alter + transpose
            } else if drums {
              guard let iid = el.child("instrument")?.attrs["id"], let u = unpitched[iid] else {
                skipped["unpitchedWithoutMidiNote", default: 0] += 1
                continue
              }
              pitch = u
            } else {
              continue
            }
            pitch = min(127, max(0, pitch))
            let key = "\(partIndex)|\(staff)|\(drums ? "d" : "p")"
            if streams[key] == nil {
              streams[key] = ([], drums, staff)
              order.append(key)
            }
            let s0 = tick(start)
            let s1 = tick(start + dur)
            let ties = el.all("tie").compactMap { $0.attrs["type"] }
            let tieKey = "\(key)|\(pitch)"
            if ties.contains("stop"), let i = open[tieKey], streams[key]!.notes[i].end == s0 {
              streams[key]!.notes[i].end = s1
              if !ties.contains("start") { open[tieKey] = nil }
              continue
            }
            streams[key]!.notes.append(
              MidiImport.RawNote(start: s0, end: max(s1, s0 + 1), pitch: pitch, velocity: 90))
            if ties.contains("start") { open[tieKey] = streams[key]!.notes.count - 1 }
          default:
            break
          }
        }
        measureStart += reached / divisions
        out.lastTick = max(out.lastTick, Int((measureStart * Double(ticksPerQuarter)).rounded()))
      }

      for key in order {
        let st = streams[key]!
        guard !st.notes.isEmpty else { continue }
        let name = (partName[id] ?? id) + (st.staff > 1 ? " (staff \(st.staff))" : "")
        out.sources.append(
          MidiImport.Source(
            track: partIndex, channel: st.drums ? 9 : 0, name: name,
            program: st.drums ? nil : partProgram[id],
            notes: st.notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) },
            label: "\(id):\(st.staff)", drums: st.drums))
      }
    }
    out.tempos.sort { $0.tick < $1.tick }
    for (k, n) in skipped.sorted(by: { $0.key < $1.key }) {
      out.warnings.append("\(k): \(n)")
    }
    guard out.sources.contains(where: { !$0.notes.isEmpty }) else { throw MidiImportError.noNotes }
    return out
  }
}

// MARK: - a tiny XML tree

final class XMLNode {
  let name: String
  var attrs: [String: String]
  var text = ""
  var children: [XMLNode] = []
  init(_ name: String, _ attrs: [String: String]) {
    self.name = name
    self.attrs = attrs
  }

  func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
  func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
  func find(_ n: String) -> XMLNode? {
    if name == n { return self }
    for c in children { if let f = c.find(n) { return f } }
    return nil
  }
  func descendants(_ n: String) -> [XMLNode] {
    children.flatMap { ($0.name == n ? [$0] : []) + $0.descendants(n) }
  }
  var int: Int? { Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
  var double: Double? { Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

  static func parse(_ data: Data) throws -> XMLNode {
    let builder = Builder()
    let p = XMLParser(data: data)
    p.delegate = builder
    p.shouldResolveExternalEntities = false
    guard p.parse(), let root = builder.root else {
      throw MidiImportError.bad("unreadable XML: \(p.parserError?.localizedDescription ?? "empty")")
    }
    return root
  }

  private final class Builder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String]
    ) {
      let n = XMLNode(name, attributes)
      if let top = stack.last { top.children.append(n) } else { root = n }
      stack.append(n)
    }
    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
      stack.last?.text += string
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}

// MARK: - just enough zip for an .mxl

struct MiniZip {
  struct Entry {
    var method: Int
    var compressedSize: Int
    var localOffset: Int
  }
  let data: [UInt8]
  var entries: [String: Entry] = [:]

  init(_ d: Data) throws {
    data = [UInt8](d)
    func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    guard data.count > 22 else { throw MidiImportError.bad("not a zip file") }
    var eocd = -1
    var i = data.count - 22
    while i >= max(0, data.count - 22 - 65_535) {
      if u32(i) == 0x0605_4B50 {
        eocd = i
        break
      }
      i -= 1
    }
    guard eocd >= 0 else { throw MidiImportError.bad("not a zip file (no central directory)") }
    let count = u16(eocd + 10)
    var p = u32(eocd + 16)
    for _ in 0..<count {
      guard p + 46 <= data.count, u32(p) == 0x0201_4B50 else { break }
      let nameLen = u16(p + 28)
      let extraLen = u16(p + 30)
      let commentLen = u16(p + 32)
      guard p + 46 + nameLen <= data.count else { break }
      let name = String(decoding: data[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
      entries[name] = Entry(
        method: u16(p + 10), compressedSize: u32(p + 20), localOffset: u32(p + 42))
      p += 46 + nameLen + extraLen + commentLen
    }
  }

  func read(_ name: String) throws -> Data? {
    guard let e = entries[name] else { return nil }
    func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
    let h = e.localOffset
    guard h + 30 <= data.count else { throw MidiImportError.bad("corrupt zip entry \(name)") }
    let start = h + 30 + u16(h + 26) + u16(h + 28)
    guard start + e.compressedSize <= data.count else {
      throw MidiImportError.bad("corrupt zip entry \(name)")
    }
    let raw = Data(data[start..<(start + e.compressedSize)])
    switch e.method {
    case 0: return raw
    case 8:
      guard let out = try? (raw as NSData).decompressed(using: .zlib) else {
        throw MidiImportError.bad("could not inflate \(name)")
      }
      return out as Data
    default: throw MidiImportError.bad("zip entry \(name): unsupported compression \(e.method)")
    }
  }
}
