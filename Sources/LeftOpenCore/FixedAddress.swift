import CryptoKit
import Foundation

/// A saved opt-in belongs to a project and a service, never to a bare port number.
public struct FixedAddressBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectRoot: String
    public let executablePath: String
    public let serviceArgumentsHash: String?
    public let serviceCWD: String?
    public let name: String
    public let launchName: String?
    public let preferredPort: Int

    public init(id: String = UUID().uuidString, projectRoot: String, executablePath: String,
                name: String, preferredPort: Int, serviceArguments: String? = nil, serviceCWD: String? = nil, launchName: String? = nil) {
        self.id = id
        self.projectRoot = projectRoot
        self.executablePath = executablePath
        self.serviceArgumentsHash = serviceArguments.map(Self.argumentHash)
        self.serviceCWD = serviceCWD
        self.name = name
        self.launchName = launchName
        self.preferredPort = preferredPort
    }

    public func matches(_ activity: Activity) -> Bool {
        activity.projectMarker?.root == projectRoot && activity.process.executablePath == executablePath
            && (serviceCWD == nil || activity.process.cwd == serviceCWD)
            && (serviceArgumentsHash == nil || activity.process.arguments.map(Self.argumentHash) == serviceArgumentsHash)
    }

    public func resolve(in activities: [Activity]) -> Activity? {
        let candidates = activities.filter { matches($0) && Self.supportsLoopback($0) }
        let preferred = candidates.filter { $0.listener.port == preferredPort }
        let selected: Activity?
        if preferred.count == 1 { selected = preferred.first }
        else if preferred.isEmpty && candidates.count == 1 { selected = candidates.first }
        else { selected = nil }
        guard let selected else { return nil }
        // The proxy dials loopback. An unrelated listener on either IP family is ambiguous.
        guard activities.filter({ $0.listener.port == selected.listener.port }).allSatisfy({
            $0.process.pid == selected.process.pid && matches($0)
        }) else { return nil }
        return selected
    }

    public static func argumentHash(_ arguments: String) -> String {
        // Match observed service identity without persisting command arguments, which can contain secrets.
        SHA256.hash(data: Data(normalizedArguments(arguments).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedArguments(_ arguments: String) -> String {
        // Only normalize explicit port flags. Other argument changes remain evidence of another service.
        arguments.replacingOccurrences(of: #"(?<!\S)(--port|-p)([ =]+)[0-9]+(?=\s|$)"#,
                                       with: "$1$2<port>", options: .regularExpression)
    }

    public static func supportsLoopback(_ activity: Activity) -> Bool {
        activity.listener.addresses.contains {
            ["*", "0.0.0.0", "::", "::1", "[::1]", "127.0.0.1", "localhost"].contains($0)
        }
    }

    public static func availableName(project: String, used: Set<String>) -> String {
        let base = Portless.suggestedName(project)
        if !used.contains(base) { return base }
        var suffix = 2
        while used.contains("\(base.prefix(55))-\(suffix)") { suffix += 1 }
        return "\(base.prefix(55))-\(suffix)"
    }
}
