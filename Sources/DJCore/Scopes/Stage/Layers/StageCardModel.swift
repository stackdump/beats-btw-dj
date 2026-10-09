// The share-card flash (SPEC mode 19): NOT PORTED, on purpose. The slot stays so the toolbar's
// card button and the T key have somewhere honest to ask.
//
// What stage.js does. On a genuine track change, when the toolbar's card button is on, it shows
// `renderCurrentCard` in a box in the top right for 6 s (fading from 5.4 s; a newer change
// replaces the box; closing the stage cancels the timers). The card is beats' share card
// (`public/lib/share/card.js`): a 1200 x 630 SVG with the title, genre, tempo, seed, key and
// bars, the seed's ring of dots, the CID, and a scannable QR code of the track's short share URL
// ("so someone watching a recording later can reopen the exact track").
//
// Why it is not here. This app has no share card, and no piece of one:
//   * no card renderer (nothing in Sources draws genre / seed / tempo / key as a card),
//   * no QR encoder (`lib/share/qr.js` has no counterpart; no CoreImage use anywhere),
//   * no share URL (`shortShareUrl`): `SessionBundle.publicURL` is a cdn.stackdump.com blob
//     directory of a published SESSION, which exists only after `djctl publish` / the app's
//     publish button has uploaded it, not for the track the stage is showing.
//   `Share.swift` (the share-v1 payload parser) and `CID.swift` are the decoding side.
// A flash of something else (a title strip without the QR) would not be the card, and a QR
// renderer is a feature of its own that nothing else in the app asks for, so this is a listed
// non-port, not a stand-in.
//
// What that means for the stage. `isAvailable` is false, which disables the toolbar's card
// button (`StageToolbar`) and keeps `StageModel.handleKey(.t)` from toggling `cardOnChange`; the
// reason below is the button's tooltip. There is no timer, fade or box anywhere: the layer
// (`StageCardLayer`) draws nothing, and `context.trackChanged` is read by nobody here. If a
// share card is ever added to the app, this model is where its 6 s life belongs: `advance` sees
// `trackChanged` for exactly the frame a track change landed, `context.now` is the clock for the
// 5.4 s fade and the 6 s end, a newer flash replaces the current one, and `reset()` /
// `context.epoch` are the "stage closed" signals.

@MainActor
public final class StageCardModel: StageLayerModel {
  public init() {}

  /// Can the toolbar's card button be used? Not until the app has a share card to show.
  public var isAvailable: Bool { false }

  /// Why not (the button's tooltip while unavailable).
  public var unavailableReason: String { Self.reason }

  public static let reason =
    "Share-card flash is not available: this app has no share card (the card is beats' "
    + "title / genre / seed / tempo / key card with a QR code)."
}
