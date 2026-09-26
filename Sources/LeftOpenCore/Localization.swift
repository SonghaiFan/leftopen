import Foundation

public enum Language: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    /// The first of the user's preferred languages that LeftOpen speaks, English otherwise.
    public static var preferred: Language {
        for identifier in Locale.preferredLanguages {
            if identifier.hasPrefix("zh") { return .chinese }
            if identifier.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// The language user-facing text is produced in. The app sets it from Settings; the CLI keeps
/// English. Read from scan threads as well as the main actor, hence the lock.
public enum Localization {
    private static let storage = LanguageStorage()

    public static var current: Language {
        get { storage.value }
        set { storage.value = newValue }
    }
}

private final class LanguageStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var language = Language.english

    var value: Language {
        get { lock.withLock { language } }
        set { lock.withLock { language = newValue } }
    }
}

/// Text in the current language. Both versions sit side by side at the call site, so a change to
/// one is never missed in the other.
public func L(_ english: String, _ chinese: String) -> String {
    Localization.current == .chinese ? chinese : english
}
