import Testing

@testable import DJCore

struct CompositionStoreTests {
  func envelope(_ name: String, note: Int = 60) throws -> JSONValue {
    try PianoRoll.envelope(
      JSONValue.parse(
        #"{"name":"\#(name)","tempo":110,"parts":{"melody":{"notes":[[0,\#(note)]]}}}"#))
  }

  @Test func savesListsAndReloadsAnEnvelopeByAPartOfItsId() throws {
    let store = CompositionStore(directory: temporaryDirectory())
    let a = try envelope("Daft Punk-style (original)")
    let request = try JSONValue.parse(#"{"inspiredBy":"Daft Punk","brief":"122 BPM"}"#)
    let saved = try store.save(kind: "inspired", deck: "A", envelope: a, request: request)
    #expect(!saved.existed && saved.url.lastPathComponent.contains("-daft-punk-style-original-"))
    #expect(saved.url.lastPathComponent.hasSuffix("\(saved.cid.suffix(8)).json"))

    let rows = store.list()
    #expect(rows.count == 1 && rows[0].kind == "inspired" && rows[0].deck == "A")
    #expect(rows[0].name == "Daft Punk-style (original)" && rows[0].tempo == 110)
    #expect(rows[0].cid == saved.cid)

    // the envelope comes back byte-for-byte: same share CID
    let back = try store.envelope(matching: "daft")
    #expect(BeatsCID.shareCID(back.envelope) == saved.cid && back.entry.id == rows[0].id)
    #expect(try store.envelope(matching: String(saved.cid.suffix(8))).entry.id == rows[0].id)
  }

  @Test func theSameEnvelopeIsKeptOnceAndDifferentOnesAreTold() throws {
    let store = CompositionStore(directory: temporaryDirectory())
    let a = try envelope("Same")
    let first = try store.save(kind: "compose", deck: "A", envelope: a, request: nil)
    let again = try store.save(kind: "compose", deck: "B", envelope: a, request: nil)
    #expect(again.existed && again.url == first.url && store.list().count == 1)
    _ = try store.save(
      kind: "compose", deck: "A", envelope: try envelope("Same", note: 62), request: nil)
    #expect(store.list().count == 2)
    #expect(throws: CompositionStore.StoreError.self) { try store.envelope(matching: "same") }  // two match
    #expect(throws: CompositionStore.StoreError.noMatch("zzz")) {
      try store.envelope(matching: "zzz")
    }
  }

  @Test func theFileKeepsOneTopLevelKeyPerLineAndIsStillJSON() throws {
    let store = CompositionStore(directory: temporaryDirectory())
    let saved = try store.save(
      kind: "compose", deck: "A", envelope: try envelope("Readable"),
      request: try JSONValue.parse(#"{"parts":{}}"#))
    let text = fileText(saved.url)
    let lines = text.split(separator: "\n")
    #expect(lines.first == "{" && lines.last == "}")
    #expect(
      lines.contains { $0.hasPrefix(#""request":"#) }
        && lines.contains { $0.hasPrefix(#""envelope":"#) })
    #expect(try JSONValue.parse(text)["name"]?.string == "Readable")
  }
}
