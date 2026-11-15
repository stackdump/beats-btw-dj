import Foundation

#if os(iOS)
  import AVFAudio
  import UIKit

  // The iOS side of what Android's PlaybackService and audio focus do: the playback session the
  // engine's RemoteIO unit needs, kept through interruptions and route changes, and the charger
  // rule for the screen (djandroid MainActivity.keepAwake).
  //
  // The engine (djmobile `keep_output`) watches its own stream: no callback for 3 s and it drops
  // it and reopens the default output, retrying at 1 s, doubling to 8 s, and only at the rate it
  // was built for. So a RemoteIO unit an interruption stopped is noticed, but it can only come
  // back once the session is active again (this file) — and at the same hardware rate, which is
  // why the preferred rate is pinned to the engine's. There is no call to reopen *now*: after an
  // interruption the sound returns on the engine's next retry, up to ~8 s later
  // (docs/ANDROID-PORT.md, Engine changes wanted 3).

  @MainActor
  final class AudioSessionHost {
    private unowned let model: RustDJModel
    private var observers: [NSObjectProtocol] = []
    /// The engine's sample rate: the one the session should keep.
    var engineRate: Double? { didSet { pinRate() } }
    /// An interruption ended without "should resume" (another app plays): the session is left
    /// inactive until a deck is played again.
    private(set) var inactive = false
    /// Plugged in (charging or full): djandroid keeps the screen on then.
    private(set) var charging = false

    init(model: RustDJModel) {
      self.model = model
      let nc = NotificationCenter.default
      let s = AVAudioSession.sharedInstance()
      observers.append(
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { n in
          let info = n.userInfo ?? [:]
          let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
          let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
          MainActor.assumeIsolated { self.interrupted(type, resume: opts.contains(.shouldResume)) }
        })
      observers.append(
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { n in
          let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
          let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
          MainActor.assumeIsolated { self.routeChanged(reason) }
        })
      observers.append(
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { _ in
          // the audio server restarted: every session object is new; set ours up again
          MainActor.assumeIsolated { self.activate() }
        })
      UIDevice.current.isBatteryMonitoringEnabled = true
      charging = Self.plugged()
      observers.append(
        nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated {
            self.charging = Self.plugged()
            self.model.applyScreenFlag()
          }
        })
    }

    private static func plugged() -> Bool {
      let s = UIDevice.current.batteryState
      return s == .charging || s == .full
    }

    /// Before `Player()`: cpal opens a RemoteIO unit, which needs a playback session.
    nonisolated static func prepare() throws {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default)
      try s.setActive(true)
    }

    /// Make the session ours again (after an interruption, a reset, or a play after one).
    func activate() {
      let s = AVAudioSession.sharedInstance()
      do {
        try s.setCategory(.playback, mode: .default)
        pinRate()
        try s.setActive(true)
        inactive = false
      } catch {
        model.error = "The audio session could not be reactivated: \(error.localizedDescription)"
      }
    }

    private func pinRate() {
      guard let r = engineRate, r > 0 else { return }
      try? AVAudioSession.sharedInstance().setPreferredSampleRate(r)
    }

    /// A deck is about to play: an interruption that left the session inactive is over now.
    func willPlay() { if inactive { activate() } }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, resume: Bool) {
      switch type {
      case .began:
        // iOS has already silenced the unit; the decks stay as they are, so a call that ends
        // with "resume" picks the set up where it was.
        break
      case .ended:
        if resume {
          activate()
        } else {
          // another app took the sound: quiet, as its play button would leave it
          model.pauseAll()
          inactive = true
        }
      default: break
      }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason) {
      switch reason {
      case .oldDeviceUnavailable:
        // headphones pulled or a speaker gone (Android's "becoming noisy"): pause, rather
        // than carry on out of the iPad's speaker; play resumes the decks it stopped
        model.pauseAll()
      case .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange:
        pinRate()
      default: break
      }
    }

    func detach() {
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
    }
  }
#endif
