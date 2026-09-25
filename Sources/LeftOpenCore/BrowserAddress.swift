import Darwin
import Foundation

/// A plausible URL for a browser on this Mac, based only on the observed bind address.
/// A listening TCP socket does not establish that the service actually speaks HTTP.
public enum BrowserAddress {
    public static func candidateURL(for listener: Listener) -> URL? {
        hosts(for: listener).first.flatMap { URL(string: "http://\($0):\(listener.port)") }
    }

    /// Try TLS first, then cleartext, without guessing from a port number or process name.
    public static func probeURLs(for listener: Listener) -> [URL] {
        hosts(for: listener).flatMap { host in
            ["https", "http"].compactMap { URL(string: "\($0)://\(host):\(listener.port)") }
        }
    }

    private static func hosts(for listener: Listener) -> [String] {
        var specific: [String] = []
        var loopback: [String] = []
        var wildcard: [String] = []

        for address in listener.addresses {
            let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            switch host {
            case "*", "0.0.0.0": wildcard.append("localhost")
            case "::": wildcard.append("[::1]")
            case "localhost": loopback.append("localhost")
            default:
                if isIPLiteral(host, family: AF_INET) {
                    if host.hasPrefix("127.") { loopback.append(host) }
                    else { specific.append(host) }
                } else if isIPLiteral(host, family: AF_INET6) {
                    if host == "::1" { loopback.append("[\(host)]") }
                    else { specific.append("[\(host)]") }
                }
            }
        }

        var seen: Set<String> = []
        return (specific + loopback + wildcard).filter { seen.insert($0).inserted }
    }

    private static func isIPLiteral(_ host: String, family: Int32) -> Bool {
        if family == AF_INET {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) == 1 }
        }
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}
