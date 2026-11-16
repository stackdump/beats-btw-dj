import Foundation

/// The Rust DJ engine (stackdump/djrust-vevr-se, via the `djmobile` UniFFI crate: the same
/// `Player` surface djandroid-vevr-se drives from Kotlin) behind a small Swift face.
///
/// It owns the audio output (cpal → CoreAudio) and the engine clock itself, so it runs
/// *instead of* DJEngine's AVAudioEngine graph, never alongside it on the same deck: the app
/// pauses a deck's Swift side when the Rust engine takes it (see `AppModel.useRustEngine`).
public final class RustEngine: @unchecked Sendable {
  public let player: Player
  public let info: EngineInfo

  /// `soundFontDir`: a folder of .sf2 banks (missing is fine: synth voices play).
  public init(soundFontDir: String? = nil) throws {
    let dir = soundFontDir ?? RustEngine.defaultSoundFontDir
    player = try Player(soundfontDir: dir)
    info = player.info()
  }

  public static var defaultSoundFontDir: String {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("beats-btw-dj/soundfonts").path
  }

  public static var genres: [String] { DJRust.genres() }

  /// Compose `genre`/`seed` (nil structure: an endless loop) and play it on `deck` ("A"/"B")
  /// once ready; the deck keeps what it has until then.
  @discardableResult
  public func load(deck: String, genre: String, seed: Int64, structure: String? = nil, play: Bool = true) throws -> Bool {
    let asked = try player.compose(deck: deck, genre: genre, seed: seed, structure: structure)
    // the compose lands on a worker: play the moment the deck has its track (a play sent
    // before that finds an empty deck)
    if play {
      let p = player
      DispatchQueue.global(qos: .userInitiated).async {
        let until = Date().addingTimeInterval(20)
        while Date() < until {
          if let s = try? p.state(deck: deck), s.loaded && s.seed == seed {
            try? p.setPlaying(deck: deck, on: true)
            return
          }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
    }
    return asked
  }

  public func setPlaying(_ deck: String, _ on: Bool) throws { try player.setPlaying(deck: deck, on: on) }
  public func state(_ deck: String) throws -> DeckState { try player.state(deck: deck) }
  public func setCrossfader(_ v: Double) throws { try player.setCrossfader(v: v) }
  public func mix() throws -> MixState { try player.mix() }
  public func shutdown() { player.shutdown() }

  /// One line for the status bar.
  public func summary() -> String {
    ["A", "B"].compactMap { d -> String? in
      guard let s = try? player.state(deck: d), s.loaded else { return nil }
      return "\(d) \(s.genre ?? "?") \(s.seed.map(String.init) ?? "") \(s.playing ? "▶" : "■") bar \(s.bar)/\(s.totalBars)"
    }.joined(separator: " · ")
  }
}
