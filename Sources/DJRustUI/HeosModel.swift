import DJRust
import Foundation

// The HEOS half of djandroid's PlayerViewModel ("HEOS"): the Denon zones on the Wi-Fi, found or
// reached at a typed address, and the mix streamed to the ticked ones. The engine does the
// protocol, the discovery and the stream's HTTP server; this keeps the page's state.
//
// iPad: talking to a zone (TCP 1255) needs the local-network permission (Info.plist
// `NSLocalNetworkUsageDescription`; iOS asks once; refused, every connect fails with "No route to
// host (os error 65)"). The zones fetching the stream from the iPad need nothing (TN3179: accepting
// incoming TCP is not a local-network operation). The engine's discovery sends SSDP / mDNS from raw
// sockets to multicast addresses, which iOS refuses without Apple's multicast entitlement
// (`com.apple.developer.networking.multicast`), so on the iPad a blank host is found by Bonjour
// (`HeosBonjour`, `_heos-audio._tcp`, listed in `NSBonjourServices`) and handed to the engine as an
// address. Any zone found leads to the rest.

/// The HEOS page: the service's state, the zones ticked for the stream, and the host typed
/// (blank: find).
struct HeosUI: Equatable {
  var state: HeosState?
  var ticked: Set<Int64> = []
  var host = ""
  /// iPad: Bonjour is looking for a zone.
  var finding = false
  /// iPad: why no zone was found (Bonjour), shown under the status until the next connect.
  var hint: String?
  /// When Play was last pressed: a stream no zone fetches after a while is said so.
  var streamSince: Date?
  /// The mix is playing on zones now: the top bar's and the menu's "HEOS live".
  var live: Bool { state?.streamUrl != nil }

  static let localNetworkHint =
    "iPadOS is blocking this app from the local network. Settings › Privacy & Security › Local Network › beats-btw-dj: on."

  /// What is wrong, in words, from the engine's status (nil: nothing known).
  var problem: String? {
    if let hint { return hint }
    let status = state?.status ?? ""
    let log = state?.log.joined(separator: "\n") ?? ""
    // EHOSTUNREACH: iOS's answer to a local-network connect the app has no permission for
    if status.contains("os error 65") || log.contains("os error 65") {
      return Self.localNetworkHint
    }
    return nil
  }

  /// Playing for `after` seconds and no zone has fetched the stream: the zones can't reach the
  /// iPad (another network or a VPN in the way), or the zone refused it (its Log line says so).
  func unfetched(now: Date = Date(), after: TimeInterval = 10) -> Bool {
    guard let s = state, s.streamUrl != nil, s.listeners == 0, let t = streamSince else {
      return false
    }
    return now.timeIntervalSince(t) > after
  }
}

extension RustDJModel {
  /// Start HEOS (the page opened): connect to the address kept (else find the zones), then read
  /// them twice a second.
  func heosStart() {
    guard let p = player else { return }
    let host = heos.host.isEmpty ? (prefs.string(forKey: "heos_host") ?? "") : heos.host
    heos.host = host
    if host.isEmpty { heosFind(first: true) } else { act { try $0.heosStart(host: host) } }
    guard !heosPolling else { return }
    heosPolling = true
    Task.detached(priority: .utility) { [weak self] in await self?.pollHeos(p) }
  }

  private nonisolated func pollHeos(_ p: Player) async {
    var last: UInt64?
    var lastStream: String?
    var lastListeners: UInt32?
    while !Task.isCancelled {
      let s = p.heosState()
      if s.generation != last || s.streamUrl != lastStream || s.listeners != lastListeners {
        last = s.generation
        lastStream = s.streamUrl
        lastListeners = s.listeners
        await MainActor.run { self.heosArrived(s) }
      }
      try? await Task.sleep(for: .milliseconds(500))
    }
  }

  private func heosArrived(_ s: HeosState) {
    var ticked = heos.ticked
    // the zones ticked last time are ticked again once they are found: one tap streams to them
    if ticked.isEmpty && (heos.state?.zones.isEmpty ?? true) {
      ticked = Set((prefs.stringArray(forKey: "heos_ticked") ?? []).compactMap { Int64($0) })
    }
    let present = ticked.filter { t in s.zones.contains { $0.pid == t } }
    heos.ticked = present.isEmpty ? ticked : present
    heos.state = s
  }

  func heosHost(_ h: String) { heos.host = h }

  /// Connect to the host typed (blank: find the zones again); remembered.
  func heosConnect() {
    let h = heos.host.trimmingCharacters(in: .whitespaces)
    prefs.set(h, forKey: "heos_host")
    heos.hint = nil
    if h.isEmpty { heosFind(first: false) } else { act { try $0.heosStart(host: h) } }
  }

  /// Find the zones with no address typed: the engine's SSDP + mDNS, or on the iPad, Bonjour.
  private func heosFind(first: Bool) {
    #if os(iOS)
      heos.finding = true
      Task { @MainActor in
        let found = await HeosBonjour.find()
        heos.finding = false
        switch found {
        case .host(let ip):
          act { try $0.heosStart(host: ip) }
        case .denied:
          heos.hint = HeosUI.localNetworkHint
        case .none:
          heos.hint =
            "No HEOS zone answered Bonjour on this Wi-Fi. Type a zone's address (Denon app › a speaker › About › IP address)."
        }
      }
    #else
      act { p in if first { try p.heosStart(host: nil) } else { try p.heosDiscover() } }
    #endif
  }

  func heosTick(_ pid: Int64, _ on: Bool) {
    if on { heos.ticked.insert(pid) } else { heos.ticked.remove(pid) }
    prefs.set(heos.ticked.map(String.init), forKey: "heos_ticked")
  }

  func heosVolume(_ pid: Int64, _ level: Int) {
    let v = UInt8(min(max(level, 0), 100))
    if var s = heos.state {
      s.zones = s.zones.map { z in
        var z = z
        if z.pid == pid { z.volume = v }
        return z
      }
      heos.state = s
    }
    act { try $0.heosVolume(pid: pid, level: v) }
  }

  func heosGroupVolume(_ gid: Int64, _ level: Int) {
    let v = UInt8(min(max(level, 0), 100))
    act { try $0.heosGroupVolume(gid: gid, level: v) }
  }

  func heosMute(_ pid: Int64) { act { try $0.heosMute(pid: pid, on: nil) } }

  func heosTransport(_ pid: Int64, _ state: String) {
    act { try $0.heosTransport(pid: pid, state: state) }
  }

  /// Group the ticked zones (in the list's order: the first leads).
  func heosGroupTicked() {
    let pids = heosTickedInOrder()
    act { try $0.heosGroup(pids: pids) }
  }

  func heosUngroup(_ pid: Int64) { act { try $0.heosUngroup(pid: pid) } }

  /// Play the mix on the ticked zones (several are grouped first, so they stay together).
  func heosStream() {
    let pids = heosTickedInOrder()
    guard !pids.isEmpty else {
      error = "Tick the zones to play the mix on."
      return
    }
    heos.streamSince = Date()
    act { _ = try $0.heosStream(pids: pids) }
  }

  func heosStreamStop() {
    heos.streamSince = nil
    act { try $0.heosStreamStop() }
  }

  private func heosTickedInOrder() -> [Int64] {
    (heos.state?.zones ?? []).map(\.pid).filter { heos.ticked.contains($0) }
  }
}
