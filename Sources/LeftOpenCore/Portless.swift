import Foundation

/// Read-only adapter for Portless's pre-1.0 state format.
public enum Portless {
    public struct Route: Decodable, Sendable {
        public let hostname: String
        public let port: Int
        public let pid: Int32
    }

    public static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 243 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    public static func suggestedName(_ project: String) -> String {
        let words = project.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let name = String(words.joined(separator: "-").prefix(63))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "myapp" : name
    }

    public static func launchCommand(name: String, projectRoot: String, command: String) -> String? {
        guard validName(name), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let root = "'" + projectRoot.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // --name supports reserved subcommand names too. The user supplies the shell command.
        return "cd \(root) && portless run --name \(name) \(command)"
    }

    public static func urls(routesData: Data, proxyPort: Int, tls: Bool, proxyPID: Int32,
                            activities: [Activity]) throws -> [String: [URL]] {
        guard (1...65535).contains(proxyPort), proxyPID > 1,
              activities.contains(where: { $0.process.pid == proxyPID && $0.listener.port == proxyPort }) else { return [:] }
        let routes = try JSONDecoder().decode([Route].self, from: routesData)
        var result: [String: [URL]] = [:]
        for route in routes {
            guard validName(route.hostname), (1...65535).contains(route.port), route.pid >= 0 else { continue }
            var components = URLComponents()
            components.scheme = tls ? "https" : "http"
            components.host = route.hostname
            if proxyPort != (tls ? 443 : 80) { components.port = proxyPort }
            guard let url = components.url else { continue }
            for activity in activities where activity.listener.port == route.port {
                // Route PID is the Portless wrapper, not necessarily the listening child.
                guard route.pid == 0 || activity.process.pid == route.pid
                    || activity.parentChain.contains(where: { $0.pid == route.pid }) else { continue }
                if !(result[activity.id] ?? []).contains(url) { result[activity.id, default: []].append(url) }
            }
        }
        return result.mapValues { $0.sorted { $0.absoluteString < $1.absoluteString } }
    }

    public static func readURLs(directory: String, activities: [Activity]) throws -> [String: [URL]] {
        let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        func text(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let file = root.appendingPathComponent("routes.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        guard let port = Int(try text("proxy.port")), let pid = Int32(try text("proxy.pid")) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try urls(routesData: data, proxyPort: port,
                        tls: FileManager.default.fileExists(atPath: root.appendingPathComponent("proxy.tls").path),
                        proxyPID: pid, activities: activities)
    }
}
