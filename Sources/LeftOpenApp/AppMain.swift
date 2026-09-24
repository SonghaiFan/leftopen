import AppKit
import Combine
import LeftOpenCore
import ServiceManagement
import SwiftUI

enum NoticeKind {
    case success
    case warning
    case error

    var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
        }
    }
}

struct Notice {
    let id = UUID()
    let kind: NoticeKind
    let text: String
}

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private init() {
        checkStatus()
    }

    func checkStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
                isEnabled = false
            } else {
                try SMAppService.mainApp.register()
                isEnabled = true
            }
        } catch {
            checkStatus()
        }
    }
}

@MainActor
final class MenuModel: ObservableObject {
    @Published var snapshot = ScanSnapshot(activities: [], limitations: [])
    @Published var isRefreshing = false
    @Published var isPreparingClose = false
    @Published var isPreparingBatchClose = false
    @Published var isClosing = false
    @Published var pendingPlan: ClosePlan?
    @Published var pendingBatchPlans: [ClosePlan]?
    @Published private(set) var notice: Notice?
    @Published var selectedActivityID: String?
    @Published var lastRefresh: Date?

    private var refreshLoop: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?

    /// The scan minus ports the user chose to ignore, so every count agrees with the list.
    var visible: ScanSnapshot {
        let ignored = AppSettings.shared.ignoredPorts
        guard !ignored.isEmpty else { return snapshot }
        return ScanSnapshot(
            activities: snapshot.activities.filter { !ignored.contains($0.listener.port) },
            limitations: snapshot.limitations
        )
    }

    var portCount: Int { visible.portCount }
    var lanPortCount: Int { visible.lanPortCount }
    var closablePortCount: Int { visible.closablePortCount }
    var hasOpenDoors: Bool { visible.hasOpenDoors }

    init() {
        Task { await refresh() }
        scheduleRefresh(AppSettings.shared.refreshInterval)
        settingsObserver = AppSettings.shared.$refreshInterval
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] interval in
                MainActor.assumeIsolated { self?.scheduleRefresh(interval) }
            }
    }

    private func scheduleRefresh(_ interval: RefreshInterval) {
        refreshLoop?.cancel()
        refreshLoop = nil
        guard interval != .manual else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval.rawValue))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// Success notices fade on their own; warnings and errors stay until the next action.
    private func post(_ notice: Notice) {
        self.notice = notice
        guard notice.kind == .success else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice?.id == notice.id { self?.notice = nil }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            snapshot = try await Task.detached(priority: .utility) { try Scanner.scan() }.value
            lastRefresh = Date()
            notice = nil
        } catch {
            post(Notice(kind: .error, text: "Scan failed: \(error.localizedDescription)"))
        }
    }

    func previewClose(_ activity: Activity) async {
        guard !isPreparingClose && !isClosing else { return }
        isPreparingClose = true
        defer { isPreparingClose = false }
        notice = nil
        do {
            pendingPlan = try await Task.detached(priority: .utility) {
                try CloseService.prepare(port: activity.listener.port, pid: activity.process.pid)
            }.value
        } catch {
            post(Notice(kind: .warning, text: "Close unavailable: \(error.localizedDescription)"))
        }
    }

    func confirmClose() async {
        guard let plan = pendingPlan, !isClosing else { return }
        await execute(plan)
    }

    private func execute(_ plan: ClosePlan) async {
        isClosing = true
        defer { isClosing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                try CloseService.execute(plan)
            }.value
            pendingPlan = nil
            selectedActivityID = nil
            let outcome: String
            let kind: NoticeKind
            if result.portFree {
                outcome = "Port \(plan.port) is free."
                kind = .success
            } else if result.targetStoppedListening {
                outcome = "PID \(plan.pid) stopped listening; port \(plan.port) is now held by \(result.remainingPIDs.map(String.init).joined(separator: ", "))."
                kind = .warning
            } else {
                outcome = "SIGTERM was sent, but PID \(plan.pid) still listens. No force-kill was attempted."
                kind = .warning
            }
            await refresh()
            post(Notice(kind: kind, text: outcome))
        } catch {
            pendingPlan = nil
            selectedActivityID = nil
            let detail = error.localizedDescription
            let outcome = detail.hasPrefix("SIGTERM was sent") ? detail : "Close refused: \(detail)"
            await refresh()
            post(Notice(kind: .warning, text: outcome))
        }
    }

    func previewBatchCloseProjects() async {
        guard !isPreparingBatchClose && !isClosing else { return }
        isPreparingBatchClose = true
        defer { isPreparingBatchClose = false }
        notice = nil
        do {
            let projects = visible.closableProjectActivities
            let plans = try await Task.detached(priority: .utility) {
                try CloseService.prepareBatch(activities: projects)
            }.value
            if plans.isEmpty {
                post(Notice(kind: .warning, text: "No closable project servers found."))
            } else {
                pendingBatchPlans = plans
            }
        } catch {
            post(Notice(kind: .warning, text: "Batch close unavailable: \(error.localizedDescription)"))
        }
    }

    func confirmBatchClose() async {
        guard let plans = pendingBatchPlans, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                try CloseService.executeBatch(plans)
            }.value
            pendingBatchPlans = nil
            selectedActivityID = nil
            await refresh()
            if result.isAllSuccessful {
                post(Notice(kind: .success, text: "Closed \(result.successfulPlans.count) project server\(result.successfulPlans.count == 1 ? "" : "s")."))
            } else {
                post(Notice(kind: .warning, text: "Closed \(result.successfulPlans.count) of \(result.totalCount) servers. \(result.failedPlans.count) could not be closed."))
            }
        } catch {
            pendingBatchPlans = nil
            selectedActivityID = nil
            await refresh()
            post(Notice(kind: .warning, text: "Batch close failed: \(error.localizedDescription)"))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LeftOpenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MenuModel()
    @ObservedObject private var settings = AppSettings.shared

    init() {
        PanelSnapshot.runIfRequested(model: MenuModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            HStack(spacing: 3) {
                if model.notice?.kind == .error {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    Image(nsImage: model.hasOpenDoors ? MenuBarDoor.open : MenuBarDoor.closed)
                }
                if let badgeCount {
                    Text(String(badgeCount)).monospacedDigit()
                }
            }
            .accessibilityLabel(accessibilityLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var badgeCount: Int? {
        let count = switch settings.menuBarBadgeMode {
        case .closable: model.closablePortCount
        case .all: model.portCount
        case .none: 0
        }
        return count > 0 ? count : nil
    }

    private var accessibilityLabel: String {
        if model.notice?.kind == .error {
            return "LeftOpen scan failed; \(model.portCount) last known listening ports"
        }
        if model.hasOpenDoors {
            return "LeftOpen, \(model.closablePortCount) open dev ports, \(model.portCount) total ports"
        }
        return "LeftOpen, all doors closed, 0 dev servers running"
    }
}
