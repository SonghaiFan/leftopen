import Foundation

/// A preview can be hosted inside a shared editor process without owning that process.
public enum EditorPreview: String, Sendable, Equatable {
    case liveServer = "live-server"

    public var name: String { "Live Server" }

    static func candidate(mappedPaths: [String]) -> EditorPreview? {
        mappedPaths.contains {
            $0.contains("/extensions/ritwickdey.liveserver-") && $0.contains("/node_modules/")
        } ? .liveServer : nil
    }

    static func matches(_ page: String) -> Bool {
        ["<!-- Code injected by live-server -->", "new WebSocket(address)",
         "msg.data == 'refreshcss'"].allSatisfy(page.contains)
    }

    /// Directory listings have no reload script. Try at most two HTML links on the same origin.
    static func pageURLs(in listing: String, base: URL) -> [URL] {
        guard listing.contains("listing directory"),
              let regex = try? NSRegularExpression(pattern: #"href="([^"?#]+\.html?)""#, options: .caseInsensitive) else { return [] }
        return Array(regex.matches(in: listing, range: NSRange(listing.startIndex..., in: listing)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: listing),
                  let url = URL(string: String(listing[range]), relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }.prefix(2))
    }

    static func detect(_ listener: Listener, mappedPaths: [String],
                       fetch: (URL) -> String? = readPage) -> EditorPreview? {
        guard listener.uid == Int32(getuid()), let candidate = candidate(mappedPaths: mappedPaths),
              listener.addresses.contains(where: { ["*", "0.0.0.0", "::", "[::]", "127.0.0.1", "::1", "[::1]"].contains($0) }) else { return nil }
        // Stay on numeric loopback: never resolve a hostname, follow redirects, or contact a LAN host.
        let host = listener.addresses.contains(where: { ["*", "0.0.0.0", "127.0.0.1"].contains($0) }) ? "127.0.0.1" : "[::1]"
        guard let base = URL(string: "http://\(host):\(listener.port)/"), let page = fetch(base) else { return nil }
        if matches(page) { return candidate }
        for url in pageURLs(in: page, base: base) {
            if let page = fetch(url), matches(page) { return candidate }
        }
        return nil
    }

    private static func readPage(_ url: URL) -> String? {
        // No cookies, credentials, proxy, redirects or disk cache. Bodies are never retained or logged.
        try? CommandRunner.output("/usr/bin/curl", ["--silent", "--fail", "--noproxy", "*",
            "--proto", "=http", "--max-time", "0.4", "--max-filesize", "262144", url.absoluteString],
            timeout: 0.6, maxOutputBytes: 262144)
    }
}
