#if os(iOS)
  import Foundation
  import Network

  // Finding a HEOS zone on the iPad. The engine's own discovery (djhost `heos::discover`) sends SSDP
  // and mDNS from raw UDP sockets to multicast addresses, which iOS refuses without Apple's
  // multicast entitlement (`com.apple.developer.networking.multicast`, TN3179), so on the iPad it
  // never finds anything. Bonjour through Network.framework needs no entitlement: only the service
  // type listed in Info.plist (`NSBonjourServices`) and the local-network permission. One zone's
  // address is enough: the engine reads every zone from it (`player/get_players`).
  //
  // The zones advertise `_heos-audio._tcp` (Kitchen, Patio, Pool on Matt's Wi-Fi: `dns-sd -B
  // _heos-audio._tcp`), on port 10101; the engine talks to them on 1255.

  enum HeosBonjour {
    static let service = "_heos-audio._tcp"

    enum Found: Equatable {
      /// A zone's IPv4 address.
      case host(String)
      /// Nothing answered within the time allowed.
      case none
      /// iPadOS refused: the app has no local-network access (Settings › Privacy & Security ›
      /// Local Network), or the service type is missing from `NSBonjourServices`.
      case denied
    }

    /// The first HEOS zone that Bonjour finds and resolves within `timeout`.
    static func find(timeout: TimeInterval = 6) async -> Found {
      await withCheckedContinuation { (k: CheckedContinuation<Found, Never>) in
        Search(timeout: timeout) { k.resume(returning: $0) }.start()
      }
    }

    /// One browse: the first service resolved to an IPv4 address wins; the rest are let go.
    private final class Search: @unchecked Sendable {
      // everything below is touched on `queue` only
      private let queue = DispatchQueue(label: "heos.bonjour")
      private let timeout: TimeInterval
      private var done: ((Found) -> Void)?
      private var browser: NWBrowser?
      private var connections: [NWConnection] = []
      private var tried: Set<String> = []
      private var denied = false

      init(timeout: TimeInterval, done: @escaping (Found) -> Void) {
        self.timeout = timeout
        self.done = done
      }

      func start() {
        queue.async { [self] in
          let b = NWBrowser(for: .bonjour(type: HeosBonjour.service, domain: "local."), using: .tcp)
          browser = b
          b.browseResultsChangedHandler = { [self] results, _ in
            for r in results { resolve(r.endpoint) }
          }
          b.stateUpdateHandler = { [self] state in
            switch state {
            case .waiting(let e), .failed(let e):
              if case .dns(let code) = e, Int(code) == -65570 {  // kDNSServiceErr_PolicyDenied
                denied = true
                finish(.denied)
              } else if case .failed = state {
                finish(.none)
              }
            default: break
            }
          }
          b.start(queue: queue)
          queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(denied ? .denied : .none)
          }
        }
      }

      // A connection to the service is how Network.framework hands over its address.
      private func resolve(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        guard done != nil, !tried.contains(key) else { return }
        tried.insert(key)
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
          ip.version = .v4
        }
        let c = NWConnection(to: endpoint, using: params)
        connections.append(c)
        c.stateUpdateHandler = { [self] state in
          switch state {
          case .ready:
            if case .hostPort(let host, _)? = c.currentPath?.remoteEndpoint,
              case .ipv4(let a) = host
            {
              // "192.168.1.241%en0": the zone's address without the interface
              finish(.host(String("\(a)".split(separator: "%").first ?? "")))
            }
          case .waiting:
            if case .localNetworkDenied? = c.currentPath?.unsatisfiedReason { denied = true }
          default: break
          }
        }
        c.start(queue: queue)
      }

      private func finish(_ found: Found) {
        guard let d = done else { return }
        done = nil
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        for c in connections {
          c.stateUpdateHandler = nil
          c.cancel()
        }
        connections = []
        d(found)
      }
    }
  }
#endif
