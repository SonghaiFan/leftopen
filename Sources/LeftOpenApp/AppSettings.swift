import Combine
import Foundation
import LeftOpenCore

/// The Settings choice; `.system` follows the Mac's preferred languages.
public enum LanguagePreference: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case chinese = "zh"

    public var id: String { rawValue }

    /// Language names are shown in their own language, so they stay findable in either UI.
    public var title: String {
        switch self {
        case .system: return L("Follow System", "跟随系统")
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    public var resolved: Language {
        switch self {
        case .system: return Language.preferred
        case .english: return .english
        case .chinese: return .chinese
        }
    }
}

public enum MenuBarBadgeMode: String, CaseIterable, Identifiable {
    case closable = "closable"
    case all = "all"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .closable: return L("Closable ports", "可关闭的端口")
        case .all: return L("All ports", "全部端口")
        case .none: return L("None", "不显示")
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
        case .seconds15: return L("Every 15 seconds", "每 15 秒")
        case .seconds30: return L("Every 30 seconds", "每 30 秒")
        case .minute1: return L("Every minute", "每分钟")
        case .minutes2: return L("Every 2 minutes", "每 2 分钟")
        case .minutes5: return L("Every 5 minutes", "每 5 分钟")
        case .manual: return L("Manually", "手动")
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
        static let language = "leftopen.language"
        static let checkForUpdates = "leftopen.checkForUpdates"
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

    @Published public var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Keys.checkForUpdates) }
    }

    /// Applied before observers hear about it, so every view re-renders in the new language.
    @Published public var language: LanguagePreference {
        willSet { Localization.current = newValue.resolved }
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    private init() {
        let storedInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? RefreshInterval.minute1.rawValue
        self.refreshInterval = RefreshInterval(rawValue: storedInterval) ?? .minute1

        let storedBadge = defaults.string(forKey: Keys.menuBarBadgeMode) ?? MenuBarBadgeMode.closable.rawValue
        self.menuBarBadgeMode = MenuBarBadgeMode(rawValue: storedBadge) ?? .closable

        self.ignoredPorts = defaults.array(forKey: Keys.ignoredPorts) as? [Int] ?? []

        self.checkForUpdates = defaults.object(forKey: Keys.checkForUpdates) as? Bool ?? true

        let storedLanguage = defaults.string(forKey: Keys.language) ?? LanguagePreference.system.rawValue
        self.language = LanguagePreference(rawValue: storedLanguage) ?? .system
        Localization.current = language.resolved
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
