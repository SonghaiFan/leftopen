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

    var portCount: Int { snapshot.portCount }
    var projectPortCount: Int { snapshot.projectPortCount }
    var closablePortCount: Int { snapshot.closablePortCount }
    var hasOpenDoors: Bool { snapshot.hasOpenDoors }

    init() {
        Task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await refresh()
            }
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
            notice = Notice(kind: .error, text: "Scan failed: \(error.localizedDescription)")
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
            notice = Notice(kind: .warning, text: "Close unavailable: \(error.localizedDescription)")
        }
    }

    func confirmClose() async {
        guard let plan = pendingPlan, !isClosing else { return }
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
            notice = Notice(kind: kind, text: outcome)
        } catch {
            pendingPlan = nil
            selectedActivityID = nil
            let detail = error.localizedDescription
            let outcome = detail.hasPrefix("SIGTERM was sent") ? detail : "Close refused: \(detail)"
            await refresh()
            notice = Notice(kind: .warning, text: outcome)
        }
    }

    func previewBatchCloseProjects() async {
        guard !isPreparingBatchClose && !isClosing else { return }
        isPreparingBatchClose = true
        defer { isPreparingBatchClose = false }
        notice = nil
        do {
            let projects = snapshot.closableProjectActivities
            let plans = try await Task.detached(priority: .utility) {
                try CloseService.prepareBatch(activities: projects)
            }.value
            if plans.isEmpty {
                notice = Notice(kind: .warning, text: "No closable project servers found.")
            } else {
                pendingBatchPlans = plans
            }
        } catch {
            notice = Notice(kind: .warning, text: "Batch close unavailable: \(error.localizedDescription)")
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
                notice = Notice(kind: .success, text: "Closed \(result.successfulPlans.count) project server\(result.successfulPlans.count == 1 ? "" : "s").")
            } else {
                notice = Notice(kind: .warning, text: "Closed \(result.successfulPlans.count) of \(result.totalCount) servers. \(result.failedPlans.count) could not be closed.")
            }
        } catch {
            pendingBatchPlans = nil
            selectedActivityID = nil
            await refresh()
            notice = Notice(kind: .warning, text: "Batch close failed: \(error.localizedDescription)")
        }
    }
}

@main
struct LeftOpenApp: App {
    @StateObject private var model = MenuModel()

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
                    Text(model.lastRefresh == nil ? "?" : String(model.portCount))
                        .monospacedDigit()
                } else if model.hasOpenDoors {
                    Image(systemName: "door.left.hand.open")
                    Text(String(model.closablePortCount))
                        .monospacedDigit()
                } else {
                    Image(systemName: "door.left.hand.closed")
                }
            }
            .accessibilityLabel(accessibilityLabel)
        }
        .menuBarExtraStyle(.window)
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
