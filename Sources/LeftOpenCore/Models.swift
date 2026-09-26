import Foundation

public enum ListenerScope: String, Sendable {
    case local = "LOCAL"
    case lan = "LAN"
}

public enum OwnerCategory: String, Sendable {
    case project
    case application
    case service
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
    public let uptime: String?
    public let rawElapsedTime: String?
    public let arguments: String?
    public let rssKB: UInt64?

    public init(pid: Int32, ppid: Int32?, command: String, executablePath: String?, uid: Int32?, user: String?, cwd: String?, uptime: String? = nil, rawElapsedTime: String? = nil, arguments: String? = nil, rssKB: UInt64? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.command = command
        self.executablePath = executablePath
        self.uid = uid
        self.user = user
        self.cwd = cwd
        self.uptime = uptime
        self.rawElapsedTime = rawElapsedTime
        self.arguments = arguments
        self.rssKB = rssKB
    }

    public var memoryUsage: String? {
        guard let rssKB else { return nil }
        if rssKB < 1024 {
            return "< 1 MB"
        } else if rssKB < 1024 * 1024 {
            let mb = Double(rssKB) / 1024.0
            return mb >= 100 ? "\(Int(round(mb))) MB" : String(format: "%.1f MB", mb)
        } else {
            let gb = Double(rssKB) / (1024.0 * 1024.0)
            return String(format: "%.1f GB", gb)
        }
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

/// A launchd job (brew services, a LaunchAgent or login item) that runs the listener or its direct
/// parent. With `keepAlive`, launchd restarts it as soon as it exits, so SIGTERM frees the port
/// only for a moment.
public struct LaunchdJob: Sendable, Equatable {
    public let label: String
    public let pid: Int32
    public let keepAlive: Bool

    public init(label: String, pid: Int32, keepAlive: Bool) {
        self.label = label
        self.pid = pid
        self.keepAlive = keepAlive
    }

    /// The command that stops the job for good instead of letting launchd bring it back.
    public var stopCommand: String {
        let homebrewPrefix = "homebrew.mxcl."
        if label.hasPrefix(homebrewPrefix) {
            return "brew services stop \(label.dropFirst(homebrewPrefix.count))"
        }
        return "launchctl bootout gui/\(getuid())/\(label)"
    }
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
    public var launchdJob: LaunchdJob? = nil

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
    public var projectPortCount: Int {
        Set(activities.filter { $0.inference.category == .project }.map(\.listener.port)).count
    }
    public var closableActivities: [Activity] {
        activities.filter { CloseService.protectionReason(for: $0) == nil }
    }
    public var closablePortCount: Int {
        Set(closableActivities.map(\.listener.port)).count
    }
    public var closableProjectActivities: [Activity] {
        closableActivities.filter { $0.inference.category == .project }
    }
    public var closableProjectPortCount: Int {
        Set(closableProjectActivities.map(\.listener.port)).count
    }
    public var hasOpenDoors: Bool {
        closablePortCount > 0
    }
}

public func compactPath(_ path: String?) -> String {
    guard let path else { return "—" }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}
