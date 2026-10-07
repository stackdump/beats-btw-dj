/// A jog-wheel event, decoded from raw MIDI 1.0 bytes. Port of
/// `parseJogMessage` in web/jog/inpulse-200-mk3.js.
public enum JogEvent: Equatable, Sendable {
  case touch(deck: String, shift: Bool, down: Bool)
  case scratch(deck: String, shift: Bool, ticks: Int)
  case bend(deck: String, shift: Bool, ticks: Int)
}

public func decodeRelative(_ value: UInt8, _ encoding: JogProfile.Encoding = .twos) -> Int {
  switch encoding {
  case .offset64: return Int(value) - 0x40
  case .twos: return value < 0x40 ? Int(value) : Int(value) - 0x80
  }
}

public func encodeRelative(_ ticks: Int, _ encoding: JogProfile.Encoding = .twos) -> UInt8 {
  switch encoding {
  case .offset64: return UInt8((0x40 + ticks) & 0x7F)
  case .twos: return UInt8(ticks & 0x7F)
  }
}

extension JogProfile {
  /// Returns nil for anything that is not a jog message on one of this profile's decks.
  public func parse(_ data: [UInt8]) -> JogEvent? {
    guard data.count >= 3 else { return nil }
    let type = data[0] & 0xF0
    let channel = data[0] & 0x0F

    var deck: String?
    var shift = false
    // Sorted so the result does not depend on dictionary order.
    for (name, ch) in decks.sorted(by: { $0.key < $1.key }) {
      if channel == ch {
        deck = name
        break
      }
      if channel == ch + shiftChannelOffset {
        deck = name
        shift = true
        break
      }
    }
    guard let deck else { return nil }

    if (type == 0x90 || type == 0x80) && data[1] == touch.note {
      return .touch(deck: deck, shift: shift, down: type == 0x90 && data[2] > 0)
    }
    if type == 0xB0 && (data[1] == scratchCC || data[1] == bendCC) {
      let ticks = decodeRelative(data[2], encoding)
      if ticks == 0 { return nil }
      return data[1] == scratchCC
        ? .scratch(deck: deck, shift: shift, ticks: ticks)
        : .bend(deck: deck, shift: shift, ticks: ticks)
    }
    return nil
  }
}
