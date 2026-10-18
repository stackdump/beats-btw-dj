import Foundation

/// What `djctl render` is asked for beyond its fixes and outputs: the spec (genre, seed,
/// structure, `--cohesion`, `--options` as `generate` takes them) and the stem filter
/// (`--mute` / `--solo`: roles, mixer groups or net ids, `RoleFilter`). Parsed here so it can
/// be tested; djctl only reads the arguments and prints. With no flags the spec is the plain
/// `TrackSpec(genre:seed:structure:)` and the filter nil, so the render is the one before.
public struct RenderRequest: Sendable, Equatable {
  public var genre: String
  public var seed: Double
  /// nil = a loop.
  public var structure: String?
  public var cohesion: String
  /// `ComposeOptions`, validated by `spec()`.
  public var options: JSONObject?
  /// nil = everything plays (an empty filter is stored as nil).
  public var filter: RoleFilter?

  public init(
    genre: String, seed: Double, structure: String? = "standard", cohesion: String? = nil,
    options: JSONObject? = nil, filter: RoleFilter? = nil
  ) {
    self.genre = genre
    self.seed = seed
    self.structure = structure
    self.cohesion = cohesion ?? TrackSpec(genre: genre, seed: seed).cohesion
    self.options = options
    self.filter = filter.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// `--mute a,b` / `--solo a,b` as a filter; nil when neither names anything.
  public static func filter(mute: String?, solo: String?) -> RoleFilter? {
    func list(_ s: String?) -> Set<String>? {
      s.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        .map { $0.subtracting([""]) }
    }
    let f = RoleFilter(mute: list(mute) ?? [], solo: list(solo))
    return f.isEmpty ? nil : f
  }

  /// `--options JSON`: a JSON object, or nil without the flag.
  public static func options(_ text: String?) throws -> JSONObject? {
    guard let text else { return nil }
    guard let o = try JSONValue.parse(text).object else {
      throw ComposeOptions.Invalid(description: "--options must be a JSON object")
    }
    return o
  }

  /// The spec to compose (options validated and merged as `generate` does).
  public func spec() throws -> TrackSpec {
    let spec = TrackSpec(genre: genre, seed: seed, structure: structure, cohesion: cohesion)
    guard let options else { return spec }
    return try ComposeOptions.apply(options, to: spec)
  }

  /// `opts` with the stem filter: every render of the request (the main one, `--room`'s dry
  /// one, `--balance`'s solos) goes through this.
  public func applied(to opts: WaveOptions) -> WaveOptions {
    var o = opts
    o.roleFilter = filter
    return o
  }

  /// The report's `filter` and `options` keys (absent when not asked for, so a plain render's
  /// JSON is unchanged).
  public func reportKeys(_ spec: TrackSpec) -> [String: Any] {
    var out: [String: Any] = [:]
    if let filter {
      var f: [String: Any] = ["mute": filter.mute.sorted()]
      if let solo = filter.solo { f["solo"] = solo.sorted() }
      out["filter"] = f
    }
    if options != nil {
      let described = JSONValue.object(ComposeOptions.describe(spec)).jsStringified
      out["options"] =
        (try? JSONSerialization.jsonObject(with: Data(described.utf8))) ?? [String: Any]()
    }
    if cohesion != TrackSpec(genre: genre, seed: seed).cohesion { out["cohesion"] = cohesion }
    return out
  }
}
