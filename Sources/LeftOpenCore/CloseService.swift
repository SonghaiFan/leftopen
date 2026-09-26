import Darwin
import Foundation

public struct ClosePlan: Sendable, Identifiable {
    public let port: Int
    public let pid: Int32
    public let uid: Int32
    public let executablePath: String
    public let startTime: String
    public let activity: Activity
    public let otherPorts: [Int]
    public let peerPIDs: [Int32]

    public var id: String { "\(port):\(pid)" }
}

public struct CloseResult: Sendable {
    public let targetStoppedListening: Bool
    public let portFree: Bool
    public let remainingPIDs: [Int32]
}

public struct BatchCloseResult: Sendable {
    public let successfulPlans: [ClosePlan]
    public let failedPlans: [(plan: ClosePlan, error: String)]

    public init(successfulPlans: [ClosePlan], failedPlans: [(plan: ClosePlan, error: String)]) {
        self.successfulPlans = successfulPlans
        self.failedPlans = failedPlans
    }

    public var totalCount: Int { successfulPlans.count + failedPlans.count }
    public var isAllSuccessful: Bool { failedPlans.isEmpty }
}

public struct CloseError: LocalizedError, Sendable {
    public let message: String
    /// SIGTERM already went out, so the failure is about the aftermath, not a refusal.
    public let signalSent: Bool
    public var errorDescription: String? { message }

    public init(_ message: String, signalSent: Bool = false) {
        self.message = message
        self.signalSent = signalSent
    }
}

public enum CloseService {
    public static func protectionReason(for activity: Activity) -> String? {
        do {
            try validate(activity: activity, currentUID: Int32(getuid()), currentPID: getpid())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static func prepare(port: Int, pid: Int32? = nil) throws -> ClosePlan {
        let snapshot = try Scanner.scan()
        return try makePlan(activities: snapshot.activities, port: port, pid: pid,
            currentUID: Int32(getuid()), currentPID: getpid(), startTime: processStartTime)
    }

    static func makePlan(activities: [Activity], port: Int, pid: Int32?, currentUID: Int32,
                         currentPID: Int32, startTime: (Int32) -> String?) throws -> ClosePlan {
        let matches = activities.filter { $0.listener.port == port }
        guard !matches.isEmpty else { throw CloseError(L("Nothing is listening on port \(port).", "端口 \(port) 上没有进程在监听。")) }
        let pids = Array(Set(matches.map(\.process.pid))).sorted()
        guard pid != nil || pids.count == 1 else {
            throw CloseError(L("Port \(port) has multiple owning PIDs; select one process.", "端口 \(port) 属于多个进程，请选择其中一个。"))
        }
        let selectedPID = pid ?? pids[0]
        guard let activity = matches.first(where: { $0.process.pid == selectedPID }) else {
            throw CloseError(L("PID \(selectedPID) is not listening on port \(port).", "PID \(selectedPID) 没有在监听端口 \(port)。"))
        }
        try validate(activity: activity, currentUID: currentUID, currentPID: currentPID)
        guard let path = activity.process.executablePath, let uid = activity.process.uid else {
            throw CloseError(L("The process has insufficient verified identity; no signal will be sent.", "无法充分确认该进程的身份，不会发送信号。"))
        }
        guard let startTime = startTime(selectedPID) else {
            throw CloseError(L("PID \(selectedPID) has no verified start time; refusing to close it.", "无法确认 PID \(selectedPID) 的启动时间，拒绝关闭。"))
        }
        let otherPorts = Array(Set(activities.filter {
            $0.process.pid == selectedPID && $0.listener.port != port
        }.map(\.listener.port))).sorted()
        return ClosePlan(port: port, pid: selectedPID, uid: uid, executablePath: path,
            startTime: startTime, activity: activity, otherPorts: otherPorts,
            peerPIDs: pids.filter { $0 != selectedPID })
    }

    private static func validate(activity: Activity, currentUID: Int32, currentPID: Int32) throws {
        let target = activity.process
        guard currentUID != 0 else { throw CloseError(L("Running Close as root is not supported.", "不支持以 root 身份关闭。")) }
        guard target.pid > 1 && target.pid != currentPID else { throw CloseError(L("PID \(target.pid) is protected.", "PID \(target.pid) 受保护。")) }
        guard let uid = target.uid else { throw CloseError(L("PID \(target.pid) has no verified user ID.", "无法确认 PID \(target.pid) 的用户。")) }
        guard uid == currentUID else { throw CloseError(L("PID \(target.pid) belongs to another user.", "PID \(target.pid) 属于其他用户。")) }
        guard let path = target.executablePath else { throw CloseError(L("PID \(target.pid) has no verified executable path.", "无法确认 PID \(target.pid) 的可执行文件路径。")) }
        let protected = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"]
        guard !protected.contains(where: { path.hasPrefix($0) }) else {
            throw CloseError(L("PID \(target.pid) uses an operating-system executable; refusing to close it.", "PID \(target.pid) 是系统程序，拒绝关闭。"))
        }
        guard activity.applicationBundle == nil else {
            throw CloseError(L("PID \(target.pid) belongs to an application bundle; refusing to disrupt the app.", "PID \(target.pid) 属于一个 App，为避免影响该 App，拒绝关闭。"))
        }
        if let job = activity.launchdJob, job.keepAlive {
            throw CloseError(L("launchd keeps \(job.label) alive and would restart it at once. Stop it with `\(job.stopCommand)`.",
                             "launchd 会让 \(job.label) 保持运行，关闭后会立即重启。请用 `\(job.stopCommand)` 停止它。"))
        }
    }

    public static func verify(plan: ClosePlan, activities: [Activity], freshStartTime: String?) throws {
        let matches = activities.filter { $0.listener.port == plan.port }
        guard let activity = matches.first(where: { $0.process.pid == plan.pid }) else {
            throw CloseError(L("PID \(plan.pid) no longer listens on port \(plan.port); nothing was signalled.", "PID \(plan.pid) 已不再监听端口 \(plan.port)，未发送任何信号。"))
        }
        let freshPeers = Set(matches.map(\.process.pid)).subtracting([plan.pid])
        guard freshPeers.isSubset(of: Set(plan.peerPIDs)) else {
            throw CloseError(L("Port \(plan.port) acquired a new owning PID; nothing was signalled.", "端口 \(plan.port) 出现了新的所属进程，未发送任何信号。"))
        }
        guard freshStartTime == plan.startTime,
              activity.process.uid == plan.uid,
              activity.process.executablePath == plan.executablePath else {
            throw CloseError(L("PID \(plan.pid) changed identity since the preview; nothing was signalled.", "PID \(plan.pid) 在确认后身份已变化，未发送任何信号。"))
        }
        try validate(activity: activity, currentUID: Int32(getuid()), currentPID: getpid())
    }

    public static func execute(_ plan: ClosePlan) throws -> CloseResult {
        let fresh = try Scanner.scan()
        try verify(plan: plan, activities: fresh.activities, freshStartTime: processStartTime(plan.pid))
        guard kill(plan.pid, SIGTERM) == 0 else {
            throw CloseError(L("SIGTERM could not be sent to PID \(plan.pid): \(String(cString: strerror(errno))).",
                             "无法向 PID \(plan.pid) 发送 SIGTERM：\(String(cString: strerror(errno)))。"))
        }
        var latest: [Listener] = []
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            do {
                latest = try Scanner.scanListeners().filter { $0.port == plan.port }
            } catch {
                throw CloseError(L("SIGTERM was sent to PID \(plan.pid), but the follow-up listener scan failed: \(error.localizedDescription)",
                                     "已向 PID \(plan.pid) 发送 SIGTERM，但随后的端口检查失败：\(error.localizedDescription)"), signalSent: true)
            }
            if !latest.contains(where: { $0.pid == plan.pid }) { break }
        }
        return CloseResult(targetStoppedListening: !latest.contains(where: { $0.pid == plan.pid }),
            portFree: latest.isEmpty, remainingPIDs: Array(Set(latest.map(\.pid))).sorted())
    }

    public static func prepareBatch(activities: [Activity]) throws -> [ClosePlan] {
        let currentUID = Int32(getuid())
        let currentPID = getpid()
        var plans: [ClosePlan] = []
        var processedPIDs = Set<Int32>()

        for activity in activities {
            let pid = activity.process.pid
            guard !processedPIDs.contains(pid) else { continue }
            processedPIDs.insert(pid)

            guard protectionReason(for: activity) == nil else { continue }
            guard let plan = try? makePlan(activities: activities, port: activity.listener.port, pid: pid,
                                           currentUID: currentUID, currentPID: currentPID, startTime: processStartTime) else {
                continue
            }
            plans.append(plan)
        }
        return plans
    }

    public static func executeBatch(_ plans: [ClosePlan]) throws -> BatchCloseResult {
        var successes: [ClosePlan] = []
        var failures: [(plan: ClosePlan, error: String)] = []

        for plan in plans {
            do {
                let res = try execute(plan)
                if res.targetStoppedListening {
                    successes.append(plan)
                } else {
                    failures.append((plan, L("Process still listening after SIGTERM", "发送 SIGTERM 后进程仍在监听")))
                }
            } catch {
                failures.append((plan, error.localizedDescription))
            }
        }
        return BatchCloseResult(successfulPlans: successes, failedPlans: failures)
    }

    private static func processStartTime(_ pid: Int32) -> String? {
        guard let output = try? CommandRunner.output("/bin/ps", ["-p", String(pid), "-o", "lstart="], timeout: 2) else {
            return nil
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
