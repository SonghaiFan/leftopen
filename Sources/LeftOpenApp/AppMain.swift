import AppKit
import Combine
import LeftOpenCore
import ServiceManagement
import SwiftUI

enum NoticeKind {
    case success
    case warning
    case forceClose
    case error

    var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .forceClose: "exclamationmark.triangle.fill"
        case .error: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .forceClose: Color(nsColor: .systemRed)
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
    @Published var pendingContainerStop: ContainerStopPlan?
    @Published private(set) var notice: Notice?
    @Published private(set) var forceCloseOffer: ForceCloseOffer?
    @Published var selectedActivityID: String?
    @Published var lastRefresh: Date?
    /// Rows hidden optimistically after a completed swipe while the safe close check runs.
    @Published private(set) var closingActivityIDs: Set<String> = []

    private var refreshLoop: Task<Void, Never>?
    private var scanLoop: Task<Void, Never>?
    private var rescanRequested = false
    private var settingsObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var safetyProtectionObserver: AnyCancellable?
    private var previousListeningPorts: Set<Int>?

    /// Hide a closing row optimistically until the follow-up scan confirms the result.
    var visible: ScanSnapshot {
        guard !closingActivityIDs.isEmpty else { return snapshot }
        return ScanSnapshot(
            activities: snapshot.activities.filter {
                !closingActivityIDs.contains($0.id)
            },
            limitations: snapshot.limitations
        )
    }

    var portCount: Int { visible.portCount }
    var hasFailedClose: Bool { forceCloseOffer != nil }

    func awaitsForceClose(_ activity: Activity) -> Bool {
        forceCloseOffer?.plan.pid == activity.process.pid
    }
    var lanPortCount: Int { visible.lanPortCount }
    var closablePortCount: Int {
        Set(visible.closableActivities(
            safetyProtectionEnabled: AppSettings.shared.safetyProtectionEnabled
        ).map(\.listener.port)).count
    }
    var hasOpenDoors: Bool { closablePortCount > 0 }

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
                    self?.forceCloseOffer = nil
                    self?.pendingContainerStop = nil
                    Task { await self?.refresh() }
                }
            }
        safetyProtectionObserver = AppSettings.shared.$safetyProtectionEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pendingPlan = nil
                    self?.pendingBatchPlans = nil
                    self?.pendingContainerStop = nil
                    self?.forceCloseOffer = nil
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
                if let offer = forceCloseOffer {
                    if !snapshot.activities.contains(where: {
                        $0.process.pid == offer.plan.pid && $0.listener.port == offer.plan.port
                    }) {
                        forceCloseOffer = nil
                        notice = nil
                    }
                }
                let listeningPorts = Set(snapshot.activities.map(\.listener.port))
                if let previousListeningPorts {
                    if !listeningPorts.subtracting(previousListeningPorts).isEmpty {
                        DoorSound.doorOpen.play()
                    } else if !previousListeningPorts.subtracting(listeningPorts).isEmpty {
                        DoorSound.doorClose.play()
                    }
                }
                previousListeningPorts = listeningPorts
            } catch {
                forceCloseOffer = nil
                post(Notice(kind: .error, text: L("Scan failed: \(error.localizedDescription)", "扫描失败：\(error.localizedDescription)")))
            }
        } while rescanRequested
    }

    func previewClose(_ activity: Activity) async {
        guard !isPreparingClose && !isClosing else { return }
        if let offer = forceCloseOffer, offer.plan.pid == activity.process.pid {
            await confirmForceClose(offer)
            return
        }
        isPreparingClose = true
        forceCloseOffer = nil
        defer { isPreparingClose = false }
        notice = nil
        do {
            let safetyProtectionEnabled = AppSettings.shared.safetyProtectionEnabled
            pendingPlan = try await Task.detached(priority: .utility) {
                try CloseService.prepare(port: activity.listener.port, pid: activity.process.pid,
                    safetyProtectionEnabled: safetyProtectionEnabled)
            }.value
        } catch {
            post(Notice(kind: .warning, text: L("Close unavailable: \(error.localizedDescription)", "无法关闭：\(error.localizedDescription)")))
        }
    }

    func confirmClose() async {
        guard let plan = pendingPlan, !isClosing else { return }
        await execute(plan)
    }

    /// The stop review is prepared like a close plan: the restart policy is fetched once, here,
    /// instead of on every scan.
    func previewContainerStop(_ activity: Activity) async {
        guard !isPreparingClose && !isClosing, let container = activity.container else { return }
        isPreparingClose = true
        notice = nil
        defer { isPreparingClose = false }
        let policy = await Task.detached(priority: .utility) {
            ContainerResolver.restartPolicy(of: container)
        }.value
        pendingContainerStop = ContainerStopPlan(activity: activity, container: container,
                                                 restartPolicy: policy)
    }

    func confirmContainerStop() async {
        guard let plan = pendingContainerStop, !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        // The ports this container owned before stopping; the refreshed scan tells which remain.
        let containerPorts = Set(snapshot.activities.filter {
            $0.container?.name == plan.container.name
                || (plan.container.id.isEmpty == false && $0.container?.id == plan.container.id)
        }.map(\.listener.port))
        do {
            _ = try await Task.detached(priority: .utility) {
                try ContainerResolver.stop(plan.container)
            }.value
            pendingContainerStop = nil
            selectedActivityID = nil
            await refresh()
            let stillForwarded = snapshot.activities.filter { containerPorts.contains($0.listener.port) }
            let outcome: String
            let kind: NoticeKind
            if stillForwarded.isEmpty {
                outcome = L("Container \(plan.container.name) stopped; port \(plan.activity.listener.port) is free.",
                            "容器 \(plan.container.name) 已停止，端口 \(plan.activity.listener.port) 已释放。")
                kind = .success
            } else {
                let held = stillForwarded.map { String($0.listener.port) }.sorted().joined(separator: ", ")
                outcome = L("Container \(plan.container.name) stopped, but \(held) still listen. Another container or the runtime may hold them.",
                            "容器 \(plan.container.name) 已停止，但 \(held) 仍在监听，可能由其他容器或运行时占用。")
                kind = .warning
            }
            post(Notice(kind: kind, text: outcome))
        } catch {
            let detail = error.localizedDescription
            post(Notice(kind: .error, text: L("docker stop failed: \(detail)", "docker stop 失败：\(detail)")))
        }
    }

    /// Swipe-to-close: the swipe past the threshold is the confirmation, so the plan is prepared
    /// and executed without the review page. Identity checks in CloseService still apply.
    func closeNow(_ activity: Activity) async {
        guard !isPreparingClose && !isClosing else { return }
        if let offer = forceCloseOffer, offer.plan.pid == activity.process.pid {
            await confirmForceClose(offer)
            return
        }
        isPreparingClose = true
        forceCloseOffer = nil
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
            let safetyProtectionEnabled = AppSettings.shared.safetyProtectionEnabled
            let plan = try await Task.detached(priority: .utility) {
                try CloseService.prepare(port: activity.listener.port, pid: activity.process.pid,
                    safetyProtectionEnabled: safetyProtectionEnabled)
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
                outcome = L("PID \(plan.pid) is still listening. Close it again within two minutes to force close; unsaved work may be lost.",
                            "PID \(plan.pid) 仍在监听。两分钟内再次关闭将强制结束，可能丢失未保存的数据。")
                kind = .forceClose
            }
            await refresh()
            if plan.safetyProtectionEnabled == AppSettings.shared.safetyProtectionEnabled,
               snapshot.activities.contains(where: { $0.process.pid == plan.pid && $0.listener.port == plan.port }) {
                forceCloseOffer = result.forceCloseOffer
                if let offer = forceCloseOffer {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(120))
                        if self?.forceCloseOffer?.id == offer.id { self?.forceCloseOffer = nil }
                    }
                }
            }
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

    func confirmForceClose(_ offer: ForceCloseOffer) async {
        guard !isClosing, !isPreparingClose, !isPreparingBatchClose else {
            post(Notice(kind: .warning, text: L("A close is already in progress. Please wait.", "正在执行关闭，请稍候。")))
            return
        }
        guard forceCloseOffer?.id == offer.id else {
            post(Notice(kind: .warning, text: L("Force close is no longer available. Try a gentle close again.", "强制关闭已失效，请先重新尝试轻轻关闭。")))
            return
        }
        // Consume the offer before awaiting: double clicks cannot resend SIGKILL.
        forceCloseOffer = nil
        isClosing = true
        post(Notice(kind: .warning, text: L("Force closing PID \(offer.plan.pid)…", "正在强制关闭 PID \(offer.plan.pid)…")))
        defer { isClosing = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                try CloseService.forceClose(offer)
            }.value
            await refresh()
            if result.portFree {
                post(Notice(kind: .success, text: L("Port \(offer.plan.port) is free.", "端口 \(offer.plan.port) 已释放。")))
            } else {
                post(Notice(kind: .warning, text: result.targetStoppedListening
                    ? L("The process stopped listening, but another process holds the port.", "该进程已停止监听，但端口仍被其他进程占用。")
                    : L("Force close was sent, but the process is still listening.", "已发送强制关闭信号，但进程仍在监听。")))
            }
        } catch {
            await refresh()
            post(Notice(kind: .warning, text: error.localizedDescription))
        }
    }

    func previewBatchCloseProjects() async {
        guard !isPreparingBatchClose && !isClosing else { return }
        isPreparingBatchClose = true
        forceCloseOffer = nil
        defer { isPreparingBatchClose = false }
        notice = nil
        do {
            let safetyProtectionEnabled = AppSettings.shared.safetyProtectionEnabled
            let projects = visible.closableProjectActivities(
                safetyProtectionEnabled: safetyProtectionEnabled)
            let plans = try await Task.detached(priority: .utility) {
                try CloseService.prepareBatch(activities: projects,
                    safetyProtectionEnabled: safetyProtectionEnabled)
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
                        .overlay(alignment: .topTrailing) {
                            if model.hasFailedClose {
                                Circle()
                                    .fill(Color(nsColor: .systemRed))
                                    .frame(width: 6, height: 6)
                                    .offset(x: 2, y: -2)
                                    .accessibilityHidden(true)
                            }
                        }
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
        if let offer = model.forceCloseOffer {
            return L("LeftOpen, PID \(offer.plan.pid) did not close; close it again to force close",
                     "LeftOpen，PID \(offer.plan.pid) 未能关闭；再次关闭将强制结束")
        }
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
