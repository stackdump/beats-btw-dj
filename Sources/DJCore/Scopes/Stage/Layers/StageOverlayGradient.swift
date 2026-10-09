import Foundation

// Canvas gradients, as stops a SwiftUI gradient reproduces.
//
// stage.js fills its flame beams and the planet's halo with `createLinearGradient` /
// `createRadialGradient` whose stops fade to a TRANSPARENT colour (`rgba(74,144,217,0)`). The
// HTML canvas interpolates the stops as straight (un-premultiplied) RGBA: halfway from
// `rgba(233,69,96,.7)` to `rgba(74,144,217,0)` it is `rgba(153,106,156,.35)`, the hue travelling
// toward the end colour while the alpha dies. SwiftUI (Core Graphics) interpolates PREMULTIPLIED
// colours: the same half way is `rgba(233,69,96,.35)`, the hue stays put, which makes the tail of a
// beam rosier and the halo's edge more saturated than beats draws them. `resampled` reproduces the
// canvas by handing SwiftUI a dense list of stops sampled from the canvas rule, between which the
// premultiplied blend is as good as exact.

public enum StageCanvasGradient {
  public typealias Stop = (location: Double, color: ScopeColor)

  /// The canvas colour at `s` (0...1): straight RGBA interpolation between the stops on either
  /// side, held at the first and last stop outside them. `stops` are sorted by location.
  public static func color(at s: Double, stops: [Stop]) -> ScopeColor {
    guard let first = stops.first, let last = stops.last else {
      return ScopeColor(r: 0, g: 0, b: 0, a: 0)
    }
    if s <= first.location { return first.color }
    if s >= last.location { return last.color }
    for i in 1..<stops.count where s <= stops[i].location {
      let a = stops[i - 1]
      let b = stops[i]
      let span = b.location - a.location
      let u = span > 0 ? (s - a.location) / span : 1
      // (not x + (y - x) * u: this form is exact at both ends)
      func mix(_ x: Double, _ y: Double) -> Double { (1 - u) * x + u * y }
      return ScopeColor(
        r: mix(a.color.r, b.color.r), g: mix(a.color.g, b.color.g), b: mix(a.color.b, b.color.b),
        a: mix(a.color.a, b.color.a))
    }
    return last.color
  }

  /// `stops` plus `segments` evenly spaced samples of `color(at:stops:)`, in location order.
  public static func resampled(_ stops: [Stop], segments: Int = 32) -> [Stop] {
    var locations = Set(stops.map(\.location))
    for i in 0...max(1, segments) { locations.insert(Double(i) / Double(max(1, segments))) }
    return locations.sorted().map { ($0, color(at: $0, stops: stops)) }
  }
}
