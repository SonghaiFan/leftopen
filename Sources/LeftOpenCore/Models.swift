import Foundation

public enum ListenerScope: String, Sendable {
    case local = "LOCAL"
    case lan = "LAN"
}

public enum OwnerCategory: String, Sendable {
    case project
    case application
    case systemService = "system-service"
    case unknown
}

public struct Listener: Sendable, Equatable {
    public let pid: Int32
    public let command: String
    public let uid: Int32?
    public let user: String?
    public let port: Int
    public var addresses: [String]

    public init(pid: Int32, command: String, uid: Int32?, user: String?, port: Int, addresses: [String]) {
        self.pid = pid
        self.command = command
        self.uid = uid
        self.user = user
        self.port = port
        self.addresses = addresses
    }
}

public struct ProcessFact: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32?
    public let command: String
    public let executablePath: String?
    public let uid: Int32?
    public let user: String?
    public let cwd: String?

    public init(pid: Int32, ppid: Int32?, command: String, executablePath: String?, uid: Int32?, user: String?, cwd: String?) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.executablePath = executablePath
        self.uid = uid
        self.user = user
        self.cwd = cwd
    }
}

public struct ProjectMarker: Sendable, Equatable {
    public let name: String
    public let root: String
    public let source: String
    public let markerPath: String
}

public struct ApplicationBundle: Sendable, Equatable {
    public let name: String
    public let path: String
    public let sourcePID: Int32
    public let direct: Bool
}

public struct OwnerInference: Sendable, Equatable {
    public let label: String
    public let category: OwnerCategory
    public let confidence: String
    public let reason: String
}

public struct Activity: Sendable, Equatable, Identifiable {
    public let listener: Listener
    public let process: ProcessFact
    public let parentChain: [ProcessFact]
    public let projectMarker: ProjectMarker?
    public let applicationBundle: ApplicationBundle?
    public let scope: ListenerScope
    public let inference: OwnerInference

    public var id: String { "\(listener.port):\(listener.pid)" }
}

public struct ScanSnapshot: Sendable {
    public let activities: [Activity]
    public let limitations: [String]

    public init(activities: [Activity], limitations: [String]) {
        self.activities = activities
        self.limitations = limitations
    }

    public var portCount: Int { Set(activities.map(\.listener.port)).count }
    public var lanPortCount: Int {
        Set(activities.filter { $0.scope == .lan }.map(\.listener.port)).count
    }
}

public func compactPath(_ path: String?) -> String {
    guard let path else { return "—" }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
