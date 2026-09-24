import Combine
import Foundation

public enum MenuBarBadgeMode: String, CaseIterable, Identifiable {
    case closable = "closable"
    case all = "all"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .closable: return "Closable ports"
        case .all: return "All ports"
        case .none: return "None"
        }
    }
}

public enum RefreshInterval: Int, CaseIterable, Identifiable {
    case seconds15 = 15
    case seconds30 = 30
    case minute1 = 60
    case minutes2 = 120
    case minutes5 = 300
    case manual = 0

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .seconds15: return "Every 15 seconds"
        case .seconds30: return "Every 30 seconds"
        case .minute1: return "Every minute"
        case .minutes2: return "Every 2 minutes"
        case .minutes5: return "Every 5 minutes"
        case .manual: return "Manually"
        }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private enum Keys {
        static let refreshInterval = "leftopen.refreshInterval"
        static let menuBarBadgeMode = "leftopen.menuBarBadgeMode"
        static let ignoredPorts = "leftopen.ignoredPorts"
    }

    private let defaults = UserDefaults.standard

    @Published public var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    @Published public var menuBarBadgeMode: MenuBarBadgeMode {
        didSet { defaults.set(menuBarBadgeMode.rawValue, forKey: Keys.menuBarBadgeMode) }
    }

    @Published public var ignoredPorts: [Int] {
        didSet { defaults.set(ignoredPorts, forKey: Keys.ignoredPorts) }
    }

    private init() {
        let storedInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? RefreshInterval.minute1.rawValue
        self.refreshInterval = RefreshInterval(rawValue: storedInterval) ?? .minute1

        let storedBadge = defaults.string(forKey: Keys.menuBarBadgeMode) ?? MenuBarBadgeMode.closable.rawValue
        self.menuBarBadgeMode = MenuBarBadgeMode(rawValue: storedBadge) ?? .closable

        self.ignoredPorts = defaults.array(forKey: Keys.ignoredPorts) as? [Int] ?? []
    }

    public func addIgnoredPort(_ port: Int) {
        guard port >= 1 && port <= 65535 else { return }
        if !ignoredPorts.contains(port) {
            ignoredPorts.append(port)
            ignoredPorts.sort()
        }
    }

    public func removeIgnoredPort(_ port: Int) {
        ignoredPorts.removeAll { $0 == port }
    }

    public func isPortIgnored(_ port: Int) -> Bool {
        ignoredPorts.contains(port)
    }
}
