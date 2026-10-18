import Testing

@testable import DJCore

/// `FileMeasure` (`djctl measure`): a file through the same audio block as a render.
struct FileMeasureTests {
  /// A render written as WAV and measured back reads as the render did in memory (16-bit
  /// quantisation is all that differs).
  @Test func renderedWAVMeasuresLikeTheRender() throws {
    let (memory, file) = try renderedWAVRoundTrip(seconds: 10)
    #expect(file.sampleRate == 48_000)
    #expect(file.channels == 2)
    #expect(abs(file.seconds - 10) < 0.01)
    let a = memory.metrics
    let b = file.metrics
    #expect(abs(a.rmsDB - b.rmsDB) < 0.05, "rms \(a.rmsDB) vs \(b.rmsDB)")
    #expect(abs(a.peakDB - b.peakDB) < 0.05, "peak \(a.peakDB) vs \(b.peakDB)")
    #expect(abs(a.shortTermP95DB - b.shortTermP95DB) < 0.05)
    #expect(abs(renderLUFS(memory) - fileLUFS(file)) < 0.05)
    // the render's audio-block keys, plus what names the file
    let d = file.dictionary
    for k in [
      "peakDB", "rmsDB", "lufs", "lra", "truePeakDBTP", "ltasDB", "slopeDBPerOct", "bands",
      "file", "sha256",
    ] {
      #expect(d[k] != nil, "\(k)")
    }
    #expect((d["sha256"] as? String)?.count == 16)
  }

  /// A mono 44.1 kHz WAV decodes at its own rate, the one channel on both sides.
  @Test func monoWAVDecodes() throws {
    let x = sineWave(1000, rmsDB: -20, seconds: 2, sampleRate: 44_100)
    let m = try measureMonoWAV(x, sampleRate: 44_100)
    #expect(m.sampleRate == 44_100)
    #expect(m.channels == 1)
    #expect(m.left.count == x.count)
    #expect(sameSamples(m.left, m.right) == .identical)
    #expect(abs(m.metrics.rmsDB + 20) < 0.1, "\(m.metrics.rmsDB)")
  }
}
