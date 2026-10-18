import DJCore
import Foundation

/// The control socket's `variations` method (dj_variations): the sound panel's saved ways to
/// play an instrument (`VoiceVariationStore`), through the same calls the panel makes, so the
/// store edits journal as `variation.*` and an apply records as the panel's acts.
extension AppModel {
  func controlVariations(_ p: JSONValue) async throws -> JSONValue {
    switch p["action"]?.string ?? "list" {
    case "list":
      let instrument = p["instrument"]?.string
      return variationsJSON(only: instrument)

    case "save":
      let (deck, voice) = try variationChannel(p)
      guard let name = p["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      else { throw ControlRequestError.bad("`name` is required") }
      guard let setting = engine?[deck]?.voiceSetting(voice.channel), !setting.isDefault else {
        throw ControlRequestError.bad(
          "channel \(voice.channel) on deck \(deck) plays \(voice.instrument)'s own voice: "
            + "shape it first (dj_perform voiceTweak / voiceSynth)")
      }
      saveVariation(voice.instrument, name: name, setting)
      guard variations[voice.instrument]?.contains(where: { $0.name == name }) == true else {
        throw ControlRequestError.bad(status)
      }
      return variationsJSON(only: voice.instrument)

    case "apply":
      let (deck, voice) = try variationChannel(p)
      let instrument = p["instrument"]?.string ?? voice.instrument
      if instrument != voice.instrument {
        let options = engine?[deck]?.roleVoices.first { $0.channel == voice.channel }?.options ?? []
        guard options.contains(instrument) else {
          throw ControlRequestError.bad(
            "channel \(voice.channel) can play: \(options.joined(separator: ", "))")
        }
      }
      let v = try requireVariation(instrument, p["name"]?.string)
      // a different instrument reloads the track first (awaited), then the tweak goes on
      guard await applyVariation(deck, channel: voice.channel, instrument: instrument, v) else {
        throw ControlRequestError.bad(status)
      }
      poll()
      return deckJSON(deck) ?? .null

    case "rename":
      let instrument = try variationInstrument(p)
      let v = try requireVariation(instrument, p["name"]?.string)
      guard let to = p["to"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty
      else { throw ControlRequestError.bad("`to` (the new name) is required") }
      renameVariation(instrument, v.name, to: to)
      guard variations[instrument]?.contains(where: { $0.name == to }) == true else {
        throw ControlRequestError.bad(status)
      }
      return variationsJSON(only: instrument)

    case "delete":
      let instrument = try variationInstrument(p)
      let v = try requireVariation(instrument, p["name"]?.string)
      deleteVariation(instrument, v.name)
      guard variations[instrument]?.contains(where: { $0.name == v.name }) != true else {
        throw ControlRequestError.bad(status)
      }
      return variationsJSON(only: instrument)

    case let other:
      throw ControlRequestError.bad(
        "action must be list | save | apply | rename | delete, not \(other)")
    }
  }

  /// The saved variations, by instrument (one instrument's when `only` is given).
  func variationsJSON(only: String? = nil) -> JSONValue {
    let names = only.map { [$0] } ?? variations.keys.sorted()
    let o = JSONObject(
      names.map { i in
        (
          i,
          JSONValue.array(
            (variations[i] ?? []).map { v in
              var e = JSONObject([("name", .string(v.name)), ("params", v.params.json)])
              if v.useSynth { e["useSynth"] = .bool(true) }
              return .object(e)
            })
        )
      })
    return .object(JSONObject([("variations", .object(o))]))
  }

  /// `deck` + `channel` of a net deck, and what that channel plays now; errors name the
  /// channels there are.
  private func variationChannel(_ p: JSONValue) throws -> (String, ChannelVoice) {
    let deck = p["deck"]?.string ?? ""
    let d = try requireDeck(deck)
    guard d.mode == .net else {
      throw ControlRequestError.bad("deck \(deck) is playing a sample; variations need a net deck")
    }
    let chs = d.roleVoices.map { "\($0.channel) (\($0.role))" }.joined(separator: ", ")
    guard let ch = p["channel"]?.int else {
      throw ControlRequestError.bad("`channel` is required (channels: \(chs))")
    }
    guard let voice = d.channelVoice(ch) else {
      throw ControlRequestError.bad("deck \(deck) has nothing on channel \(ch) (channels: \(chs))")
    }
    return (deck, voice)
  }

  /// `instrument`, or what `deck` + `channel` plays now.
  private func variationInstrument(_ p: JSONValue) throws -> String {
    if let i = p["instrument"]?.string, !i.isEmpty { return i }
    guard p["deck"] != nil else {
      throw ControlRequestError.bad("`instrument` (or `deck` and `channel`) is required")
    }
    return try variationChannel(p).1.instrument
  }

  private func requireVariation(_ instrument: String, _ name: String?) throws -> VoiceVariation {
    let saved = variations[instrument] ?? []
    if let name, let v = saved.first(where: { $0.name == name }) { return v }
    let have =
      saved.isEmpty
      ? "none saved for \(instrument)"
      : "variations of \(instrument): " + saved.map(\.name).joined(separator: ", ")
    throw ControlRequestError.bad(
      name == nil ? "`name` is required (\(have))" : "no variation \(name!) (\(have))")
  }
}
