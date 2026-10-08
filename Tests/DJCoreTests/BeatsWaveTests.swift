import Testing

@testable import DJCore

// Oracle: beats' wave-engine (net.js / synth.js / runner.js) via scripts/beats-wave.mjs.

private func wave() throws -> JSONValue { try JSONValue.parse(try beatsFixtureText("wave")) }

private func bits(_ hex: String) -> Double { Double(bitPattern: UInt64(hex, radix: 16)!) }

private func fnv(_ h: UInt32, _ v: Int32) -> UInt32 {
  (h ^ UInt32(bitPattern: v)) &* 16_777_619
}

/// Mirror of tickChecksum() in scripts/beats-wave.mjs.
private func tickChecksum(_ g: WaveGraph) -> UInt32 {
  var h: UInt32 = 2_166_136_261
  h = fnv(h, Int32(truncatingIfNeeded: g.tick))
  for i in 0..<g.firedCount { h = fnv(h, g.fired[i]) }
  h = fnv(h, 0x7fff)
  for i in 0..<g.controlCount { h = fnv(h, g.controls[i]) }
  h = fnv(h, Int32(g.overflow))
  for n in g.nets {
    for p in 0..<n.nPlaces { h = fnv(h, Int32(jsRound(n.state[p] * 1000))) }
  }
  for i in 0..<g.muted.count { h = fnv(h, Int32(g.muted[i]) + 2 * Int32(i)) }
  for i in 0..<g.mutedNotes.count where g.mutedNotes[i] != 0 { h = fnv(h, Int32(i + 100_000)) }
  for i in 0..<g.mutedGroups.count { h = fnv(h, Int32(g.mutedGroups[i]) + 3 * Int32(i)) }
  h = fnv(h, g.stopRequested ? 1 : 0)
  return h
}

private func project(_ genre: String, _ seed: Double, _ structure: String) -> Project {
  var ov = JSONObject()
  ov["seed"] = .number(seed)
  if structure != "loop" { ov["structure"] = .string(structure) }
  return compose(genre: genre, overrides: .object(ov))
}

struct WaveSynthTests {
  @Test func integerHelpersMatch() throws {
    let w = try wave()
    for r in w["strHashes"]!.array! {
      #expect(Int(strHash(r["s"]!.string!)) == Int(r["h"]!.double!), "strHash \(r["s"]!.string!)")
    }
    for r in w["noiseSeeds"]!.array! {
      #expect(Int(noiseSeed(r["i"]!.int!)) == r["seed"]!.int!, "noiseSeed \(r["i"]!.int!)")
    }
    for r in w["rands"]!.array! {
      let got = deterministicRand(tick: r["tick"]!.int!, salt: Int32(r["salt"]!.int!))
      #expect(
        got.bitPattern == bits(r["bits"]!.string!).bitPattern,
        "rand \(r["tick"]!.int!)/\(r["salt"]!.int!)")
    }
  }

  @Test func voicesMatch() throws {
    let w = try wave()
    for r in w["voices"]!["drums"]!.array! {
      let want = VoiceSpec(json: r["voice"]!)
      let got = drumVoice(kind: r["kind"]!.string!, instrument: r["instrument"]!.string!)
      #expect(got == want, "drum \(r["instrument"]!.string!)/\(r["kind"]!.string!)")
    }
    let tonal = w["voices"]!["tonal"]!.array!
    #expect(tonal.count == 27 * 6)
    for r in tonal {
      let want = VoiceSpec(json: r["voice"]!)
      let got = tonalVoice(instrument: r["instrument"]!.string, group: r["group"]!.string)
      #expect(
        got == want,
        "tonal \(r["instrument"]?.jsStringified ?? "")/\(r["group"]?.jsStringified ?? "")")
    }
  }

  @Test func biquadsAndTablesMatch() throws {
    let w = try wave()
    for r in w["biquads"]!.array! {
      let got = biquad(
        type: r["type"]!.string!, fc: r["fc"]!.double!, q: r["q"]!.double!, sr: r["sr"]!.double!)
      let want = r["coeffs"]!.array!.map { $0.double! }
      for (a, b) in zip(got, want) { #expect(abs(a - b) < 1e-13, "\(r["type"]!.string!)") }
    }
    for r in w["tables"]!.array! {
      let t = buildTable(r["wave"]!.string!)
      #expect(t.count == waveTableSize + 1)
      for (k, want) in r["sum"]!.array!.enumerated() {
        #expect(abs(Double(t[k * 251]) - want.double!) < 1e-6, "\(r["wave"]!.string!)[\(k * 251)]")
      }
      #expect(Double(t[waveTableSize]) == r["last"]!.double!)
    }
  }
}

struct WaveExecutorTests {
  @Test func tickTracesAreExact() throws {
    let traces = try wave()["traces"]!.array!
    #expect(traces.count == 8)
    for tr in traces {
      let tag = "\(tr["genre"]!.string!)/\(tr["structure"]!.string!)"
      let g = WaveGraph(
        project: project(tr["genre"]!.string!, tr["seed"]!.double!, tr["structure"]!.string!))
      #expect(g.nets.count == tr["nets"]!.int!, "\(tag) net count")
      #expect(g.nets.map(\.id) == tr["netIds"]!.strings!, "\(tag) net order")
      let sums = tr["checksums"]!.array!
      let head = tr["head"]!.array!
      var firstBad: Int?
      for k in 0..<sums.count {
        g.advance()
        if UInt32(truncatingIfNeeded: sums[k].int!) != tickChecksum(g) && firstBad == nil {
          firstBad = k
        }
        if k < head.count {
          #expect(
            Array(g.fired[0..<g.firedCount]).map { Int($0) } == head[k]["fired"]!.ints!,
            "\(tag) fired @\(k)")
          #expect(
            Array(g.controls[0..<g.controlCount]).map { Int($0) } == head[k]["controls"]!.ints!,
            "\(tag) controls @\(k)")
        }
      }
      #expect(firstBad == nil, "\(tag): first checksum mismatch at tick \(firstBad ?? -1)")
      #expect(g.stopRequested == tr["stopRequested"]!.bool!, "\(tag) stop")
      #expect(g.muted.map { Int($0) } == tr["mutedAtEnd"]!.ints!, "\(tag) muted")
      #expect(g.groups == tr["groups"]!.strings!, "\(tag) groups")
    }
  }

  @Test func incidenceAndInvariantsMatch() throws {
    let rows = try wave()["invariants"]!.array!
    let g = WaveGraph(project: project("techno", 42, "standard"))
    #expect(g.nets.count == rows.count)
    for (n, r) in zip(g.nets, rows) {
      #expect(n.id == r["id"]!.string!)
      #expect(n.nPlaces == r["P"]!.int! && n.nTrans == r["T"]!.int!)
      let mat = n.incidenceMatrix()
      let weighted = mat.map { row in
        row.enumerated().reduce(0.0) { $0 + $1.element * Double($1.offset + 1) }
      }
      #expect(weighted == r["incidence"]!.array!.map { $0.double! }, "incidence \(n.id)")
      // Elimination is cubic: long linear chains (fills, curves) are checked in JS only.
      if n.nPlaces > 128 { continue }
      let ys = pInvariants(mat)
      #expect(ys.count == r["invariants"]!.int!, "invariant count \(n.id)")
      let ones = ys.count == 1 && ys[0].allSatisfy { abs($0 - 1) < 1e-9 }
      #expect(ones == r["ones"]!.bool!, "all-ones invariant \(n.id)")
    }
  }

  @Test func inhibitorAndConflictSemantics() throws {
    // p0 feeds t0 and t1 (a conflict); t2 is inhibited by p3 and fires into p3.
    let doc = try JSONValue.parse(
      #"""
      {"name":"x","tempo":120,"nets":{"n":{"places":{"p0":{"initial":[1]},"p1":{},"p2":{},"p3":{},"p4":{"initial":[1]}},
      "transitions":{"t0":{},"t1":{},"t2":{}},
      "arcs":[{"source":"p0","target":"t0"},{"source":"p0","target":"t1"},{"source":"t0","target":"p1"},{"source":"t1","target":"p2"},
      {"source":"p4","target":"t2"},{"source":"p3","target":"t2","inhibit":true},{"source":"t2","target":"p3"}]}}}
      """#)
    let g = WaveGraph(json: doc)
    g.advance()
    let n = g.nets[0]
    // exactly one of t0/t1 won p0's token; t2 fired once and then p3 inhibits it
    #expect(n.state[0] == 0)
    #expect(n.state[1] + n.state[2] == 1)
    #expect(n.state[3] == 1 && n.state[4] == 0)
    g.advance()
    #expect(n.state[3] == 1)
  }
}

struct WaveAudioTests {
  @Test func rendersMatchWithinOneEMinusFive() throws {
    let cases = try wave()["renders"]!.array!
    #expect(cases.count == 12)
    for c in cases {
      let tag = c["tag"]!.string!
      let want = decodeFloat32(base64: c["audio"]!.string!)
      let got = renderWaveCase(c)
      #expect(got.left.count == want.count, "\(tag) length")
      var maxDiff: Float = 0
      var at = -1
      for i in 0..<min(want.count, got.left.count) {
        let d = abs(got.left[i] - want[i])
        if d > maxDiff {
          maxDiff = d
          at = i
        }
      }
      #expect(maxDiff < 1e-5, "\(tag): max |Δ| \(maxDiff) at sample \(at)")
      #expect(got.left == got.right, "\(tag) mono → stereo identical")
      #expect(got.graphTick == c["graphTick"]!.int!, "\(tag) graph tick")
      #expect(got.tempoAtEnd == c["tempoAtEnd"]!.double!, "\(tag) tempo")
      #expect(got.stopped == c["stopped"]!.bool!, "\(tag) stopped")
      #expect(got.samples == c["samplesCounted"]!.double!, "\(tag) samples")
    }
  }

  /// The comparison has to be able to fail: another case's audio must not satisfy it.
  @Test func renderComparisonRejectsOtherAudio() throws {
    let cases = try wave()["renders"]!.array!
    let other = decodeFloat32(base64: cases[2]["audio"]!.string!)
    let got = renderWaveCase(cases[0])
    var maxDiff: Float = 0
    for i in 0..<min(other.count, got.left.count) {
      maxDiff = max(maxDiff, abs(got.left[i] - other[i]))
    }
    #expect(maxDiff > 1e-2)
    #expect(got.left.contains { $0 != 0 })
  }

  @Test func renderingIsDeterministic() throws {
    let c = try wave()["renders"]!.array![0]
    #expect(renderWaveCase(c).left == renderWaveCase(c).left)
  }
}
