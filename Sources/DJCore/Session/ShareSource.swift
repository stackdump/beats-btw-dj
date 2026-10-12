import Foundation

// A beats share (link or envelope payload) → what a deck holds. Used by the control socket's
// `loadShare` (`dj_load_share`) and the deck's "Share link from clipboard"; the deck then
// loads it through `DJEngine.perform`, so it is recorded like any load.

/// Why a share can't go on a deck.
public enum ShareLoadError: Error, Equatable, CustomStringConvertible {
  case unreadable
  /// A short `?cid=` link: its payload lives on a server, and fetching is the caller's job.
  case needsFetch(cid: String)
  /// An envelope with neither a genre to compose nor nets to play.
  case noTrack
  case unknownGenre(String)

  public var description: String {
    switch self {
    case .unreadable:
      return
        "not a beats share: give a share URL (?cid=…&z=…, or a legacy ?p= / ?g= link) or an "
        + "envelope payload as JSON"
    case .needsFetch(let cid):
      return
        "a short link: the payload of \(cid) lives on a server; give the full link (with &z=) "
        + "or the payload JSON"
    case .noTrack: return "the share has neither a genre nor nets"
    case .unknownGenre(let g): return "unknown genre \(g) (see dj_catalog)"
    }
  }
}

extension DeckSourceDescriptor {
  /// What a beats share puts on a deck. `text` is a share link (`ShareLink.parse`: a full
  /// `?cid=&z=` URL or its query — the CID is verified — or a legacy `?p=` / `?g=` link) or an
  /// envelope payload as JSON. Composed shares become `.net(TrackSpec(share:))`, raw-`nets`
  /// ones `.rawNets(payload:)`.
  public static func share(_ text: String) throws -> DeckSourceDescriptor {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("{") {
      guard let v = try? JSONValue.parse(t) else { throw ShareLoadError.unreadable }
      return try share(payload: v)
    }
    switch ShareLink.parse(t) {
    case .envelope(let s)?: return try share(s)
    case .legacy(let v)?: return try share(Share(legacy: v))
    case .needsFetch(let cid, _)?: throw ShareLoadError.needsFetch(cid: cid)
    case nil: throw ShareLoadError.unreadable
    }
  }

  /// An envelope payload (`shareFromPayload` reads it; its CID is `shareCID` of it).
  public static func share(payload: JSONValue) throws -> DeckSourceDescriptor {
    guard payload.object != nil else { throw ShareLoadError.unreadable }
    return try share(Share(payload: payload, cid: BeatsCID.shareCID(payload)))
  }

  static func share(_ s: Share) throws -> DeckSourceDescriptor {
    if let nets = s.nets {
      guard let o = nets.object, !o.entries.isEmpty else { throw ShareLoadError.noTrack }
      return .rawNets(payload: s.payload)
    }
    guard let spec = TrackSpec(share: s) else { throw ShareLoadError.noTrack }
    guard BeatsTables.shared.genres[spec.genre] != nil else {
      throw ShareLoadError.unknownGenre(spec.genre)
    }
    return .net(spec)
  }
}
