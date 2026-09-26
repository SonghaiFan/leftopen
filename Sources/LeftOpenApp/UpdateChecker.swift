import Combine
import Foundation
import LeftOpenCore

/// Asks GitHub for the latest published release at launch and then once a day, while enabled in
/// Settings. Only the public release feed is requested; nothing about this Mac is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: ReleaseVersion
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed
    }

    @Published private(set) var state = State.idle

    static let upgradeCommand = "brew upgrade --cask songhaifan/tap/leftopen"
    private static let latestRelease = URL(string: "https://api.github.com/repos/SonghaiFan/leftopen/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/SonghaiFan/leftopen/releases/latest")!
    private static let checkInterval: Duration = .seconds(24 * 60 * 60)

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Nil for a development build, which has no version to compare.
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init)

    /// The cask leaves a Caskroom entry, and brew should do the upgrade so it keeps track of it.
    var installedWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/leftopen", "/usr/local/Caskroom/leftopen"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    var availableRelease: Release? {
        if case let .available(release) = state { release } else { nil }
    }

    private var loop: Task<Void, Never>?
    private var settingObserver: AnyCancellable?

    private init() {}

    func start() {
        settingObserver = AppSettings.shared.$checkForUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.schedule(enabled) }
            }
    }

    private func schedule(_ enabled: Bool) {
        loop?.cancel()
        loop = nil
        guard enabled, currentVersion != nil else { return }
        loop = Task { [weak self] in
            // Let launch and the first port scan settle first.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func check() async {
        guard let currentVersion, state != .checking else { return }
        state = .checking
        var request = URLRequest(url: Self.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let version = ReleaseVersion(release.tagName) else { throw URLError(.cannotParseResponse) }
            // Only ever open GitHub itself from what the feed says.
            let page = URL(string: release.htmlURL).flatMap { $0.host == "github.com" ? $0 : nil } ?? Self.releasesPage
            state = version > currentVersion ? .available(Release(version: version, page: page)) : .upToDate
        } catch {
            state = .failed
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
