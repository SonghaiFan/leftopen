import AppKit
import Combine
import LeftOpenCore
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
final class MenuModel: ObservableObject {
    @Published var snapshot = ScanSnapshot(activities: [], limitations: [])
    @Published var isRefreshing = false
    @Published var isPreparingClose = false
    @Published var isClosing = false
    @Published var pendingPlan: ClosePlan?
    @Published private(set) var notice: Notice?
    @Published var selectedActivityID: String?
    @Published var lastRefresh: Date?

    var portCount: Int { snapshot.portCount }

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
}

@main
struct LeftOpenApp: App {
    @StateObject private var model = MenuModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.notice?.kind == .error ? "exclamationmark.triangle" : "network")
                Text(model.notice?.kind == .error && model.lastRefresh == nil ? "?" : String(model.portCount))
                    .monospacedDigit()
            }
            .accessibilityLabel(model.notice?.kind == .error
                ? "LeftOpen scan failed; \(model.portCount) last known listening ports"
                : "LeftOpen, \(model.portCount) listening ports")
        }
        .menuBarExtraStyle(.window)
    }
}
