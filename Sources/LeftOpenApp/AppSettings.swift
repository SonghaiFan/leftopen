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
        static let ignoredPorts = "leftopen.ignoredPorts"
        static let refreshInterval = "leftopen.refreshInterval"
        static let menuBarBadgeMode = "leftopen.menuBarBadgeMode"
        static let language = "leftopen.language"
        static let checkForUpdates = "leftopen.checkForUpdates"
        static let safetyProtectionEnabled = "leftopen.safetyProtectionEnabled"
        static let soundEffectsEnabled = "leftopen.soundEffectsEnabled"
        static let showProjectDock = "leftopen.showProjectDock"
        static let soundVolume = "leftopen.soundVolume"
    }

    private let defaults: UserDefaults

    @Published public var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    @Published public var menuBarBadgeMode: MenuBarBadgeMode {
        didSet { defaults.set(menuBarBadgeMode.rawValue, forKey: Keys.menuBarBadgeMode) }
    }

    @Published public var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Keys.checkForUpdates) }
    }

    @Published public var safetyProtectionEnabled: Bool {
        didSet { defaults.set(safetyProtectionEnabled, forKey: Keys.safetyProtectionEnabled) }
    }

    @Published public var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled) }
    }

    @Published public var showProjectDock: Bool {
        didSet { defaults.set(showProjectDock, forKey: Keys.showProjectDock) }
    }

    @Published public var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: Keys.soundVolume) }
    }

    /// Applied before observers hear about it, so every view re-renders in the new language.
    @Published public var language: LanguagePreference {
        willSet { Localization.current = newValue.resolved }
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published public private(set) var ignoredPorts: [Int] {
        didSet { defaults.set(ignoredPorts, forKey: Keys.ignoredPorts) }
    }

    public func addIgnoredPort(_ port: Int) {
        guard (1...65535).contains(port), !ignoredPorts.contains(port) else { return }
        ignoredPorts = (ignoredPorts + [port]).sorted()
    }

    /// Parse the entire edit before saving so an invalid entry never drops existing ports.
    @discardableResult
    public func setIgnoredPorts(from text: String) -> Bool {
        let tokens = text.split { $0 == "," || $0 == "，" || $0.isWhitespace }
        var ports = Set<Int>()
        for token in tokens {
            guard token.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = Int(token), (1...65535).contains(port) else { return false }
            ports.insert(port)
        }
        ignoredPorts = ports.sorted()
        return true
    }

    public func removeIgnoredPort(_ port: Int) {
        ignoredPorts.removeAll { $0 == port }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignoredPorts = Array(Set(defaults.array(forKey: Keys.ignoredPorts) as? [Int] ?? []))
            .filter { (1...65535).contains($0) }.sorted()
        let storedInterval = defaults.object(forKey: Keys.refreshInterval) as? Int ?? RefreshInterval.minute1.rawValue
        self.refreshInterval = RefreshInterval(rawValue: storedInterval) ?? .minute1

        let storedBadge = defaults.string(forKey: Keys.menuBarBadgeMode) ?? MenuBarBadgeMode.closable.rawValue
        self.menuBarBadgeMode = MenuBarBadgeMode(rawValue: storedBadge) ?? .closable

        self.showProjectDock = defaults.object(forKey: Keys.showProjectDock) as? Bool ?? true

        self.checkForUpdates = defaults.object(forKey: Keys.checkForUpdates) as? Bool ?? true

        self.safetyProtectionEnabled = defaults.object(forKey: Keys.safetyProtectionEnabled) as? Bool ?? true

        self.soundEffectsEnabled = defaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true

        self.soundVolume = defaults.object(forKey: Keys.soundVolume) as? Double ?? 1.0

        let storedLanguage = defaults.string(forKey: Keys.language) ?? LanguagePreference.system.rawValue
        self.language = LanguagePreference(rawValue: storedLanguage) ?? .system
        Localization.current = language.resolved
    }
}
