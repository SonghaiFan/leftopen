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
    /// Rows hidden optimistically after a completed swipe while the safe close check runs.
    @Published private(set) var closingActivityIDs: Set<String> = []

    private var refreshLoop: Task<Void, Never>?
    private var scanLoop: Task<Void, Never>?
    private var rescanRequested = false
    private var settingsObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?

    /// The scan minus ports the user chose to ignore, so every count agrees with the list.
    var visible: ScanSnapshot {
        let ignored = AppSettings.shared.ignoredPorts
        guard !ignored.isEmpty || !closingActivityIDs.isEmpty else { return snapshot }
        return ScanSnapshot(
            activities: snapshot.activities.filter {
                !ignored.contains($0.listener.port) && !closingActivityIDs.contains($0.id)
            },
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
        // Owner evidence and scan limitations are written during the scan, so rescan to reword them.
        languageObserver = AppSettings.shared.$language
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notice = nil
                    Task { await self?.refresh() }
                }
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

    /// Returns once a scan that started after this call has landed. Overlapping calls share one
    /// scan loop: a request that arrives mid-scan queues a single rescan instead of a parallel one,
    /// so a refresh after a close never settles for a snapshot taken before the signal.
    func refresh() async {
        if let scanLoop {
            rescanRequested = true
            await scanLoop.value
            return
        }
        let loop = Task { await runScans() }
        scanLoop = loop
        await loop.value
    }

    private func runScans() async {
        isRefreshing = true
        defer {
            isRefreshing = false
            scanLoop = nil
        }
        repeat {
            rescanRequested = false
            do {
                snapshot = try await Task.detached(priority: .utility) { try Scanner.scan() }.value
                lastRefresh = Date()
                notice = nil
            } catch {
                post(Notice(kind: .error, text: L("Scan failed: \(error.localizedDescription)", "扫描失败：\(error.localizedDescription)")))
            }
        } while rescanRequested
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
            post(Notice(kind: .warning, text: L("Close unavailable: \(error.localizedDescription)", "无法关闭：\(error.localizedDescription)")))
        }
    }

    func confirmClose() async {
        guard let plan = pendingPlan, !isClosing else { return }
        await execute(plan)
    }

    /// Swipe-to-close: the swipe past the threshold is the confirmation, so the plan is prepared
    /// and executed without the review page. Identity checks in CloseService still apply.
    func closeNow(_ activity: Activity) async {
        guard !isPreparingClose && !isClosing else { return }
        isPreparingClose = true
        _ = withAnimation(.easeOut(duration: 0.16)) {
            closingActivityIDs.insert(activity.id)
        }
        defer {
            isPreparingClose = false
            _ = withAnimation(.easeOut(duration: 0.16)) {
                closingActivityIDs.remove(activity.id)
            }
        }
        notice = nil
        do {
            let plan = try await Task.detached(priority: .utility) {
                try CloseService.prepare(port: activity.listener.port, pid: activity.process.pid)
            }.value
            await execute(plan)
        } catch {
            post(Notice(kind: .warning, text: L("Close unavailable: \(error.localizedDescription)", "无法关闭：\(error.localizedDescription)")))
        }
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
                outcome = L("Port \(plan.port) is free.", "端口 \(plan.port) 已释放。")
                kind = .success
            } else if result.targetStoppedListening {
                let holders = result.remainingPIDs.map(String.init).joined(separator: ", ")
                outcome = L("PID \(plan.pid) stopped listening; port \(plan.port) is now held by \(holders).",
                            "PID \(plan.pid) 已停止监听，但端口 \(plan.port) 现在被 \(holders) 占用。")
                kind = .warning
            } else {
                outcome = L("SIGTERM was sent, but PID \(plan.pid) still listens. No force-kill was attempted.",
                            "已发送 SIGTERM，但 PID \(plan.pid) 仍在监听。未尝试强制结束。")
                kind = .warning
            }
            await refresh()
            post(Notice(kind: kind, text: outcome))
        } catch {
            pendingPlan = nil
            selectedActivityID = nil
            let detail = error.localizedDescription
            let signalSent = (error as? CloseError)?.signalSent == true
            let outcome = signalSent ? detail : L("Close refused: \(detail)", "已拒绝关闭：\(detail)")
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
                post(Notice(kind: .warning, text: L("No closable project servers found.", "没有可关闭的项目服务器。")))
            } else {
                pendingBatchPlans = plans
            }
        } catch {
            post(Notice(kind: .warning, text: L("Batch close unavailable: \(error.localizedDescription)", "无法批量关闭：\(error.localizedDescription)")))
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
                post(Notice(kind: .success, text: L("Closed \(result.successfulPlans.count) project server\(result.successfulPlans.count == 1 ? "" : "s").",
                                                    "已关闭 \(result.successfulPlans.count) 个项目服务器。")))
            } else {
                post(Notice(kind: .warning, text: L("Closed \(result.successfulPlans.count) of \(result.totalCount) servers. \(result.failedPlans.count) could not be closed.",
                                                    "已关闭 \(result.successfulPlans.count)/\(result.totalCount) 个服务器，\(result.failedPlans.count) 个未能关闭。")))
            }
        } catch {
            pendingBatchPlans = nil
            selectedActivityID = nil
            await refresh()
            post(Notice(kind: .warning, text: L("Batch close failed: \(error.localizedDescription)", "批量关闭失败：\(error.localizedDescription)")))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { UpdateChecker.shared.start() }
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
            return L("LeftOpen scan failed; \(model.portCount) last known listening ports", "LeftOpen 扫描失败；上次已知 \(model.portCount) 个监听端口")
        }
        if model.hasOpenDoors {
            return L("LeftOpen, \(model.closablePortCount) open dev ports, \(model.portCount) total ports",
                     "LeftOpen，\(model.closablePortCount) 个可关闭端口，共 \(model.portCount) 个端口")
        }
        return L("LeftOpen, all doors closed, 0 dev servers running", "LeftOpen，门都关好了，没有可关闭的端口")
    }
}
