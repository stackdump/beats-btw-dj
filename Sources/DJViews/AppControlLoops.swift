import DJCore
import Foundation

/// The control socket's `loops` method (`dj_loops`): the Loops row's buttons that are not deck
/// actions — its Undo, "Load source", Export and "Stop all" — through the same calls they make.
extension AppModel {
  func controlLoops(_ p: JSONValue) async throws -> JSONValue {
    guard let dj = engine else { throw ControlRequestError.bad("the audio engine did not start") }
    func requireClip() throws -> String {
      guard let id = p["id"]?.string, dj.clip(id) != nil else {
        throw ControlRequestError.bad("`id` must be a clip on the row (dj_state.loops.clips[].id)")
      }
      return id
    }
    switch p["action"]?.string ?? "list" {
    case "list":
      break

    case "undo":
      guard let r = lastRemoval else {
        throw ControlRequestError.bad(
          "nothing to undo (the last removal's Undo lasts \(Int(LoopRemoval.undoSeconds)) s; "
            + "dj_perform clipRestore {id} brings back any removed loop)")
      }
      undoRemove()
      guard dj.clip(r.id) != nil else { throw ControlRequestError.bad(status) }

    case "loadSource":
      let id = try requireClip()
      let deck = p["deck"]?.string ?? ""
      guard deck == "A" || deck == "B", dj[deck] != nil else {
        throw ControlRequestError.bad("`deck` must be A or B")
      }
      guard dj.clipOrigin(id) != nil else {
        throw ControlRequestError.bad(
          "can't load where loop \(id) came from (a sample's audio is no longer in memory, "
            + "or it has no source)")
      }
      guard await loadOrigin(id, on: deck) else { throw ControlRequestError.bad(status) }
      poll()
      return deckJSON(deck) ?? .null

    case "export":
      let id = try requireClip()
      guard let raw = p["path"]?.string, !raw.isEmpty else {
        throw ControlRequestError.bad("`path` is required (a .wav file or a folder)")
      }
      let path = (raw as NSString).expandingTildeInPath
      guard path.hasPrefix("/") else { throw ControlRequestError.bad("`path` must be absolute") }
      var url = URL(fileURLWithPath: path)
      var isDir: ObjCBool = false
      if raw.hasSuffix("/")
        || (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
      {
        url = url.appendingPathComponent(dj.clip(id)?.fileName ?? "loop.wav")
      }
      let clip: LoopClip
      do { clip = try writeClipWAV(id, to: url) } catch {
        throw ControlRequestError.bad("export: \(error.localizedDescription)")
      }
      return .object(
        JSONObject([
          ("id", .string(id)), ("path", .string(url.path)), ("frames", .int(clip.buffer.length)),
          ("sampleRate", .number(clip.buffer.sampleRate)), ("beats", .int(clip.beats)),
          ("bpm", .number(clip.bpm)),
        ]))

    case "stopAll":
      let stopping = dj.loopingClips
      stopAllLoops()
      poll()
      var o = JSONObject([("stopped", .array(stopping.map { .string($0) }))])
      o["loops"] = controlState()["loops"] ?? .null
      return .object(o)

    case let other:
      throw ControlRequestError.bad(
        "action must be list | undo | loadSource | export | stopAll, not \(other)")
    }
    poll()
    return controlState()["loops"] ?? .null
  }
}
