import DJCore

// dj_state.fxUnit: each target's FX unit (A, B and the loops' L), as the panel shows it.

extension AppModel {
  /// `{A: {...}, B: {...}, L: {...}}`: every control's value, the kill, whether the unit is
  /// changing the sound, the controls the target has now, and why it lacks the others.
  func fxUnitJSON() -> JSONValue {
    guard let dj = engine else { return .null }
    var o = JSONObject()
    for name in (dj.decks.keys.sorted() + [dj.loopChannel.name]) {
      guard let d = dj[name] else { continue }
      let s = d.fxUnit
      var values = JSONObject()
      for p in FxParam.allCases { values[p.id] = .number(s[p]) }
      var missing = JSONObject()
      for p in FxParam.allCases { if let why = d.fxUnitMissing(p) { missing[p.id] = .string(why) } }
      let controls = d.fxUnitControls
      o[name] = .object(
        JSONObject([
          ("values", .object(values)), ("killed", .bool(s.killed)), ("active", .bool(s.isActive)),
          ("moved", .array(s.moved.map { .string($0.id) })),
          ("controls", .array(FxParam.allCases.filter(controls.contains).map { .string($0.id) })),
          ("missing", .object(missing)),
        ]))
    }
    return .object(o)
  }
}
