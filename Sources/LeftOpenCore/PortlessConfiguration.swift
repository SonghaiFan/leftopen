import Foundation

public enum PortlessConfiguration {
    public static let portKey = "leftopen.proxyHTTPSPort"
    public static func validPort(_ port: Int) -> Bool {
        (1...65535).contains(port) && !(1355...1365).contains(port)
    }
    public static func savedPort(in defaults: UserDefaults = .standard) -> Int {
        let port = defaults.integer(forKey: portKey)
        return validPort(port) ? port : 443
    }
    public static func address(host: String, port: Int) -> URL? {
        guard validPort(port) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        if port != 443 { parts.port = port }
        return parts.url
    }
}
