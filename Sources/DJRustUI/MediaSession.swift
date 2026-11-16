import DJRust
import Foundation
import MediaPlayer

// The port of djandroid's playback/DeckPlayer.kt: the lead deck as the system's media session,
// so the lock screen, Control Centre, a headset's or a keyboard's media keys show it and drive
// it. Android needs a foreground service for that; iOS only needs `UIBackgroundModes: audio` and
// an active playback session (AudioSessionHost), which the app has from the start.
//
// - The lead deck: the one the crossfader favours, unless only the other one plays, so the
//   session reads "playing" whenever a deck is heard.
// - Pause stops every deck that plays (a headset's pause means quiet); play starts the decks
//   that pause stopped, else the lead.
// - Next is the next version; previous is ⏮ on the deck (the song's top past its first two bars,
//   else the track before) — Media3's rule is "past 3 s", the deck's own button's is used here.
// - The info changes with the track, its play state, its neighbours and its tempo, not per bar;
//   the system extrapolates the elapsed time from the rate.

@MainActor
final class MediaSession {
  private unowned let model: RustDJModel
  private var key: String?
  private(set) var lead = "A"
  private var targets: [Any] = []

  init(model: RustDJModel) {
    self.model = model
    let c = MPRemoteCommandCenter.shared()
    func on(_ cmd: MPRemoteCommand, _ f: @escaping @MainActor () -> Bool) {
      targets.append(
        cmd.addTarget { _ in MainActor.assumeIsolated { f() } ? .success : .noActionableNowPlayingItem })
    }
    on(c.playCommand) { [weak self] in self?.play() ?? false }
    on(c.pauseCommand) { [weak self] in self?.pause() ?? false }
    on(c.stopCommand) { [weak self] in self?.pause() ?? false }
    on(c.togglePlayPauseCommand) { [weak self] in
      guard let self else { return false }
      return self.model.playing ? self.pause() : self.play()
    }
    on(c.nextTrackCommand) { [weak self] in
      guard let self, self.leadLoaded else { return false }
      self.model.next(self.lead)
      return true
    }
    on(c.previousTrackCommand) { [weak self] in
      guard let self, self.leadLoaded else { return false }
      self.model.previous(self.lead)
      return true
    }
    // a live deck has no seek bar and no skip-by-seconds
    for cmd in [c.changePlaybackPositionCommand, c.skipForwardCommand, c.skipBackwardCommand, c.seekForwardCommand, c.seekBackwardCommand] {
      cmd.isEnabled = false
    }
  }

  private var leadLoaded: Bool { model.decks[lead]?.deck?.loaded == true }

  private func play() -> Bool {
    guard leadLoaded || !model.pausedBySession.isEmpty else { return false }
    model.resumeFromSession(lead: lead)
    return true
  }

  private func pause() -> Bool {
    model.pauseAll()
    return true
  }

  /// After a poll: pick the lead and, when what the session shows changed, tell the system.
  func update() {
    let fav = leadDeck(model.mix?.crossfader)
    let other = deckNames.first { $0 != fav }!
    let st = { (x: String) in self.model.decks[x]?.deck }
    lead = st(fav)?.playing != true && st(other)?.playing == true ? other : fav
    let d = st(lead)
    let k = d.map {
      "\($0.deck)|\($0.loaded)|\($0.playing)|\($0.genre ?? "")|\($0.seed ?? 0)|\($0.structure ?? "")|\($0.hasPrevious)|\($0.nextVersionSeed ?? -1)|\($0.totalTicks)|\(Int($0.tempo * 10))|\($0.title ?? "")"
    }
    guard k != key else { return }
    key = k
    publish(d)
  }

  private func publish(_ d: DeckState?) {
    let center = MPNowPlayingInfoCenter.default()
    let c = MPRemoteCommandCenter.shared()
    // an Acid Bass loop has no genre: its loop id stands in
    guard let d, d.loaded, let genre = d.genre ?? d.td3.map({ "acid bass \($0)" }) else {
      center.nowPlayingInfo = nil
      #if os(macOS)
        center.playbackState = .stopped
      #endif
      c.nextTrackCommand.isEnabled = false
      c.previousTrackCommand.isEnabled = false
      return
    }
    let ticksPerSec = d.tempo / 60 * 4
    let pos = model.clocks[lead]?.snap.position ?? d.position
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: d.title ?? d.seed.map { trackTitle(genre: genre, seed: $0) } ?? genre,
      MPMediaItemPropertyArtist: "djrust · deck \(lead) · \(genre)",
      MPMediaItemPropertyAlbumTitle: d.structure ?? "loop",
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: d.structure == nil,
      MPNowPlayingInfoPropertyPlaybackRate: d.playing ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
    if ticksPerSec > 0 {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = pos / ticksPerSec
      // a loop is endless: no duration
      if d.structure != nil { info[MPMediaItemPropertyPlaybackDuration] = Double(d.totalTicks) / ticksPerSec }
    }
    center.nowPlayingInfo = info
    #if os(macOS)
      center.playbackState = d.playing ? .playing : .paused
    #endif
    c.nextTrackCommand.isEnabled = true
    c.previousTrackCommand.isEnabled = true
  }

  func detach() {
    let c = MPRemoteCommandCenter.shared()
    for cmd in [c.playCommand, c.pauseCommand, c.stopCommand, c.togglePlayPauseCommand, c.nextTrackCommand, c.previousTrackCommand] {
      cmd.removeTarget(nil)
    }
    targets = []
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
}
