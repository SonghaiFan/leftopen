import Foundation

/// Icon fetching stays on the observed listener, including redirects.
public enum FaviconPolicy {
    public static func isSameOrigin(_ candidate: URL, as origin: URL) -> Bool {
        guard let scheme = candidate.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = candidate.host?.lowercased(),
              candidate.user == nil, candidate.password == nil else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return scheme == origin.scheme?.lowercased()
            && host == origin.host?.lowercased() && port(candidate) == port(origin)
    }

    public static func allowsSelfSignedCertificate(host: String) -> Bool {
        ["127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}
