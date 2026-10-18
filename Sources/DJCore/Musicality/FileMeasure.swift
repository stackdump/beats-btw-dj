import AVFoundation
import CryptoKit
import Foundation

/// Any local audio file (wav, aiff, mp3, m4a, flac…) measured with the tooling a render gets
/// (`djctl measure`): the same audio block `djctl render` prints (`audioBlock`), so a reference
/// track and a generated one compare key for key. Decoded by the decks' decoder (`Deck.decode`,
/// as `djctl levels`) at the file's own rate; a mono file plays on both channels, as a deck
/// plays it. The file is read, never copied: it is named by basename and a sha256 prefix.
public struct FileMeasure {
  /// The file's basename.
  public var name: String
  /// The first 16 hex digits of the file's sha256.
  public var sha256: String
  public var sampleRate: Double
  /// Channels in the file (a mono one is measured as two equal channels).
  public var channels: Int
  /// The whole file's length, seconds.
  public var fileSeconds: Double
  /// The part measured: from `start` seconds, `left.count` frames.
  public var start: Double
  public var left: [Float]
  public var right: [Float]

  /// Decode `url` and keep `seconds` of it (all, when nil) from `start` seconds.
  public init(url: URL, start: Double = 0, seconds: Double? = nil) throws {
    let rate: Double
    do {
      let f = try AVAudioFile(forReading: url)
      rate = f.fileFormat.sampleRate
      channels = Int(f.fileFormat.channelCount)
    } catch {
      throw DJEngineError.unreadable(url, error.localizedDescription)
    }
    let b = try Deck.decode(url, sampleRate: rate)
    sampleRate = b.sampleRate
    fileSeconds = b.duration
    let a = min(b.length, max(0, Int(start * b.sampleRate)))
    let end = seconds.map { min(b.length, a + max(0, Int($0 * b.sampleRate))) } ?? b.length
    guard end > a else {
      throw DJEngineError.unreadable(url, "nothing to measure from \(start) s")
    }
    self.start = Double(a) / b.sampleRate
    left = Array(UnsafeBufferPointer(start: b.left + a, count: end - a))
    right =
      b.right == b.left ? left : Array(UnsafeBufferPointer(start: b.right + a, count: end - a))
    name = url.lastPathComponent
    sha256 = try Self.sha256Prefix(url)
  }

  /// The measured part's length, seconds.
  public var seconds: Double { Double(left.count) / sampleRate }

  public var metrics: AudioMetrics {
    AudioMetrics(left: left, right: right, sampleRate: sampleRate)
  }

  /// `djctl render`'s audio block over this file, plus what names it.
  public var dictionary: [String: Any] {
    var d = Self.audioBlock(left: left, right: right, sampleRate: sampleRate)
    d["file"] = name
    d["sha256"] = sha256
    d["sampleRate"] = sampleRate
    d["channels"] = channels
    d["fileSeconds"] = round3(fileSeconds)
    d["start"] = round3(start)
    d["seconds"] = round3(seconds)
    return d
  }

  /// Pitch against `note` over the first second measured (mid of the two channels), and the
  /// period estimate (`PitchMeasure`).
  public func pitch(note: Int) -> [String: Any] {
    let n = min(left.count, Int(sampleRate))
    var mid = [Float](repeating: 0, count: n)
    for i in 0..<n { mid[i] = 0.5 * (left[i] + right[i]) }
    let r = PitchMeasure.error(mid, note: note, sampleRate: sampleRate)
    var d: [String: Any] = [
      "note": note, "hz": round3(r.hz), "cents": round3(r.cents), "octave": r.octave,
      "level": round3(r.level),
    ]
    if let f = PitchMeasure.fundamental(mid, sampleRate: sampleRate) {
      d["fundamentalHz"] = round3(f)
    }
    return d
  }

  /// The level / spectrum part of `djctl render`'s audio block: `AudioMetrics`, BS.1770
  /// integrated loudness, EBU loudness range and true peak. One place, so a render and a file
  /// are measured alike.
  public static func audioBlock(left: [Float], right: [Float], sampleRate sr: Double) -> [String:
    Any]
  {
    var audio = AudioMetrics(left: left, right: right, sampleRate: sr).dictionary
    audio["lufs"] = round3(IntegratedLoudness.lufs(left: left, right: right, sampleRate: sr))
    audio["lra"] = round3(IntegratedLoudness.range(left: left, right: right, sampleRate: sr))
    audio["truePeakDBTP"] = round3(TruePeak.dbtp(left: left, right: right))
    return audio
  }

  /// The first 16 hex digits of `url`'s sha256, read in 1 MB chunks.
  public static func sha256Prefix(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hash = SHA256()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
  }
}
