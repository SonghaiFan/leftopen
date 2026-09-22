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
    public var errorDescription: String? { message }

    public init(_ message: String) { self.message = message }
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
        guard !matches.isEmpty else { throw CloseError("Nothing is listening on port \(port).") }
        let pids = Array(Set(matches.map(\.process.pid))).sorted()
        guard pid != nil || pids.count == 1 else {
            throw CloseError("Port \(port) has multiple owning PIDs; select one process.")
        }
        let selectedPID = pid ?? pids[0]
        guard let activity = matches.first(where: { $0.process.pid == selectedPID }) else {
            throw CloseError("PID \(selectedPID) is not listening on port \(port).")
        }
        try validate(activity: activity, currentUID: currentUID, currentPID: currentPID)
        guard let path = activity.process.executablePath, let uid = activity.process.uid else {
            throw CloseError("The process has insufficient verified identity; no signal will be sent.")
        }
        guard let startTime = startTime(selectedPID) else {
            throw CloseError("PID \(selectedPID) has no verified start time; refusing to close it.")
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
        guard currentUID != 0 else { throw CloseError("Running Close as root is not supported.") }
        guard target.pid > 1 && target.pid != currentPID else { throw CloseError("PID \(target.pid) is protected.") }
        guard let uid = target.uid else { throw CloseError("PID \(target.pid) has no verified user ID.") }
        guard uid == currentUID else { throw CloseError("PID \(target.pid) belongs to another user.") }
        guard let path = target.executablePath else { throw CloseError("PID \(target.pid) has no verified executable path.") }
        let protected = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"]
        guard !protected.contains(where: { path.hasPrefix($0) }) else {
            throw CloseError("PID \(target.pid) uses an operating-system executable; refusing to close it.")
        }
        guard activity.applicationBundle == nil else {
            throw CloseError("PID \(target.pid) belongs to an application bundle; refusing to disrupt the app.")
        }
    }

    public static func verify(plan: ClosePlan, activities: [Activity], freshStartTime: String?) throws {
        let matches = activities.filter { $0.listener.port == plan.port }
        guard let activity = matches.first(where: { $0.process.pid == plan.pid }) else {
            throw CloseError("PID \(plan.pid) no longer listens on port \(plan.port); nothing was signalled.")
        }
        let freshPeers = Set(matches.map(\.process.pid)).subtracting([plan.pid])
        guard freshPeers.isSubset(of: Set(plan.peerPIDs)) else {
            throw CloseError("Port \(plan.port) acquired a new owning PID; nothing was signalled.")
        }
        guard freshStartTime == plan.startTime,
              activity.process.uid == plan.uid,
              activity.process.executablePath == plan.executablePath else {
            throw CloseError("PID \(plan.pid) changed identity since the preview; nothing was signalled.")
        }
        try validate(activity: activity, currentUID: Int32(getuid()), currentPID: getpid())
    }

    public static func execute(_ plan: ClosePlan) throws -> CloseResult {
        let fresh = try Scanner.scan()
        try verify(plan: plan, activities: fresh.activities, freshStartTime: processStartTime(plan.pid))
        guard kill(plan.pid, SIGTERM) == 0 else {
            throw CloseError("SIGTERM could not be sent to PID \(plan.pid): \(String(cString: strerror(errno))).")
        }
        var latest: [Listener] = []
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            do {
                latest = try Scanner.scanListeners().filter { $0.port == plan.port }
            } catch {
                throw CloseError("SIGTERM was sent to PID \(plan.pid), but the follow-up listener scan failed: \(error.localizedDescription)")
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
                    failures.append((plan, "Process still listening after SIGTERM"))
                }
            } catch {
                failures.append((plan, error.localizedDescription))
            }
        }
        return BatchCloseResult(successfulPlans: successes, failedPlans: failures)
    }

    private static func processStartTime(_ pid: Int32) -> String? {
        guard let output = try? CommandRunner.output("/bin/ps", ["-p", String(pid), "-o", "lstart="]) else {
            return nil
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
