import Foundation

/// Recognizes an HTTP(S) listener by its response to a bounded HEAD request.
/// It never follows redirects or accepts untrusted TLS certificates.
public enum WebProbe {
    private static let noRedirects = NoRedirects()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 0.75
        configuration.timeoutIntervalForResource = 1.0
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    public static func detect(_ listener: Listener, using customSession: URLSession? = nil) async -> URL? {
        let session = customSession ?? Self.session
        var untrustedTLSHosts: Set<String> = []
        for url in BrowserAddress.probeURLs(for: listener) {
            guard !Task.isCancelled else { return nil }
            if url.scheme == "http", let host = url.host, untrustedTLSHosts.contains(host) {
                continue
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 0.75)
            request.httpMethod = "HEAD"
            do {
                let (_, response) = try await session.data(for: request, delegate: noRedirects)
                if let http = response as? HTTPURLResponse,
                   http.url?.scheme == url.scheme, http.url?.host == url.host,
                   http.url?.port == url.port {
                    return url
                }
            } catch let error as URLError {
                // A TLS certificate failure is evidence of HTTPS, not permission to retry HTTP.
                if [.serverCertificateUntrusted, .serverCertificateHasBadDate,
                    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid].contains(error.code) {
                    if let host = url.host { untrustedTLSHosts.insert(host) }
                }
            } catch { }
        }
        return nil
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
