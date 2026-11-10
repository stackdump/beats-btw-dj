#if DJ_RUST
  import DJCore
  import DJRust
  import Foundation

  /// The Rust-engine toggle. With it on, a *net* track loaded on a deck (a generated or shared
  /// beats track: `DeckSourceDescriptor.net`) is composed and played by djrust's engine, which
  /// opens its own CoreAudio output; the Swift deck is paused so the two never double up.
  /// Samples, loops, the recorder, FX, the waveform and the controllers still run on DJEngine
  /// (see docs/RUST-ENGINE.md for the gap list). Off: nothing here runs and the Rust engine is
  /// never created.
  extension AppModel {
    static let rustEngineKey = "useRustEngine"

    /// Called once from `start()`: honours the saved choice and `DJ_ENGINE=rust`.
    func restoreRustEngine() {
      let env = ProcessInfo.processInfo.environment["DJ_ENGINE"]
      if env == "rust" || (env == nil && UserDefaults.standard.bool(forKey: Self.rustEngineKey)) {
        setRustEngine(true)
      }
    }

    public func setRustEngine(_ on: Bool) {
      if on {
        guard rust == nil else { useRustEngine = true; return }
        do {
          rust = try RustEngine()
          useRustEngine = true
          status = "Rust engine on (\(rust?.info.sampleRate ?? 0) Hz)"
        } catch {
          useRustEngine = false
          status = "Rust engine: \(error)"
        }
      } else {
        useRustEngine = false
        rust?.shutdown()  // closes its audio output
        rust = nil
        status = "Swift engine"
      }
      UserDefaults.standard.set(useRustEngine, forKey: Self.rustEngineKey)
    }

    public func toggleRustEngine() { setRustEngine(!useRustEngine) }

    /// A net track onto `deck` through Rust. False: not handled (no engine, bad genre), the
    /// caller falls through to the Swift engine.
    func loadOnRust(_ deck: String, _ spec: TrackSpec) -> Bool {
      guard let rust, RustEngine.genres.contains(spec.genre) else { return false }
      pauseSwiftDeck(deck)
      do {
        try rust.load(deck: deck, genre: spec.genre, seed: Int64(spec.seed), structure: spec.structure)
        status = "Rust: \(spec.genre) \(Int64(spec.seed)) on \(deck)"
        return true
      } catch {
        status = "Rust: \(error)"
        return false
      }
    }

    /// Play/pause on Rust when the deck is loaded there.
    func toggleRust(_ deck: String) -> Bool {
      guard let rust, let s = try? rust.state(deck), s.loaded else { return false }
      try? rust.setPlaying(deck, !s.playing)
      return true
    }
  }
#endif
