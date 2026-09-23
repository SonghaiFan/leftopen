import Foundation
import LeftOpenCore

let isTTY = isatty(STDOUT_FILENO) != 0 && !CommandLine.arguments.contains("--no-color") && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

func paint(_ code: Int, _ text: String) -> String {
    isTTY ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
}
func bold(_ text: String) -> String { paint(1, text) }
func dim(_ text: String) -> String { paint(2, text) }
func green(_ text: String) -> String { paint(32, text) }
func yellow(_ text: String) -> String { paint(33, text) }
func cyan(_ text: String) -> String { paint(36, text) }
func red(_ text: String) -> String { paint(31, text) }

func pad(_ value: Any, _ width: Int) -> String {
    let s = String(describing: value)
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
}

func scopeLabel(_ scope: ListenerScope) -> String {
    scope == .local ? green("LOCAL") : yellow("LAN")
}

func printSection(_ title: String, activities: [Activity]) {
    guard !activities.isEmpty else { return }
    print("\n\(bold(title)) \(dim("(\(activities.count))"))")
    print(dim("\(pad("PORT", 8))\(pad("PID", 9))\(pad("OWNER", 24))\(pad("PROCESS", 16))\(pad("AGE", 8))\(pad("RAM", 9))SCOPE"))
    for activity in activities {
        let portStr = pad(activity.listener.port, 8)
        let pidStr = pad(activity.process.pid, 9)
        let ownerStr = pad(String(activity.inference.label.prefix(22)), 24)
        let procStr = pad(String(activity.process.command.prefix(14)), 16)
        let ageStr = pad(activity.process.compactUptime ?? "—", 8)
        let ramStr = pad(activity.process.memoryUsage ?? "—", 9)
        let scopeStr = scopeLabel(activity.scope)
        print("\(portStr)\(pidStr)\(ownerStr)\(procStr)\(ageStr)\(ramStr)\(scopeStr)")
        if let marker = activity.projectMarker {
            print(dim("         ↳ \(compactPath(marker.root))"))
        }
    }
}

func printOverview(activities: [Activity]) {
    let portCount = Set(activities.map(\.listener.port)).count
    let processCount = Set(activities.map(\.process.pid)).count
    let projectCount = Set(activities.compactMap { $0.projectMarker?.root }).count
    let lanCount = Set(activities.filter { $0.scope == .lan }.map(\.listener.port)).count

    print(bold("\nLEFT OPEN"))
    print("\(cyan(String(portCount))) listening ports · \(processCount) processes · \(projectCount) projects · \(yellow(String(lanCount))) LAN-visible")

    let sections: [(OwnerCategory, String)] = [
        (.project, "MY PROJECTS"),
        (.application, "APPLICATIONS"),
        (.service, "SERVICES"),
        (.systemService, "SYSTEM SERVICES"),
        (.unknown, "UNKNOWN"),
    ]

    for (cat, title) in sections {
        printSection(title, activities: activities.filter { $0.inference.category == cat })
    }
    print(dim("\nLOCAL = this Mac only · LAN = may be reachable from your local network\n"))
}

func printDetail(port: Int, activities: [Activity]) {
    let matches = activities.filter { $0.listener.port == port }
    guard !matches.isEmpty else {
        print("\n\(green("FREE")) Nothing is listening on port \(port).\n")
        return
    }
    print("\n\(bold("PORT \(port)")) · \(matches.count) listener\(matches.count == 1 ? "" : "s")")
    for (idx, activity) in matches.enumerated() {
        if idx > 0 { print(dim(String(repeating: "─", count: 56))) }
        print("URL:        http://localhost:\(activity.listener.port)")
        print("Owner:      \(activity.inference.label)")
        print("Type:       \(activity.inference.category.rawValue)")
        if let uptime = activity.process.uptime {
            let rawStr = activity.process.rawElapsedTime.map { " (\($0))" } ?? ""
            print("Uptime:     \(uptime)\(rawStr)")
        }
        if let memory = activity.process.memoryUsage {
            print("Memory:     \(memory)")
        }
        print("Confidence: \(activity.inference.confidence)")
        print("Process:    \(activity.process.command)")
        print("PID:        \(activity.process.pid)")
        print("PPID:       \(activity.process.ppid.map(String.init) ?? "unknown")")
        print("User:       \(activity.process.user ?? activity.process.uid.map(String.init) ?? "unknown")")
        print("Scope:      \(scopeLabel(activity.scope))")
        print("Addresses:  \(activity.listener.addresses.joined(separator: ", "))")
        print("Executable: \(compactPath(activity.process.executablePath))")
        print("CWD:        \(compactPath(activity.process.cwd))")
        if let marker = activity.projectMarker {
            print("Marker:     \(compactPath(marker.markerPath))")
        }
        if let bundle = activity.applicationBundle {
            print("App bundle: \(compactPath(bundle.path))")
        }
        if !activity.parentChain.isEmpty {
            let chain = activity.parentChain.map { "\($0.command) (\($0.pid))" }.joined(separator: " → ")
            print("Parents:    \(chain)")
        }
        print("Reason:     \(activity.inference.reason)")
        if let protection = CloseService.protectionReason(for: activity) {
            print("Protection: \(yellow(protection))")
        }
    }
    print()
}

func runClose(port: Int, targetPID: Int32?, dryRun: Bool, autoConfirm: Bool, activities: [Activity]) {
    let matches = activities.filter { $0.listener.port == port }
    guard !matches.isEmpty else {
        print("\(yellow("NOT LISTENING")) Port \(port) is already free.")
        return
    }

    let activity: Activity
    if let targetPID = targetPID {
        guard let found = matches.first(where: { $0.process.pid == targetPID }) else {
            print("\(red("ERROR")) PID \(targetPID) is not listening on port \(port).")
            exit(1)
        }
        activity = found
    } else if matches.count == 1 {
        activity = matches[0]
    } else {
        print("\(yellow("MULTIPLE LISTENERS")) Multiple processes share port \(port):")
        for m in matches {
            print("  PID \(m.process.pid): \(m.process.command) (\(m.inference.label))")
        }
        print("Specify the PID to close with --pid <pid>.")
        exit(1)
    }

    if let protection = CloseService.protectionReason(for: activity) {
        print("\(red("REFUSED")) Cannot close \(activity.inference.label): \(protection)")
        exit(1)
    }

    do {
        let plan = try CloseService.prepare(port: port, pid: activity.process.pid)
        print("\n\(bold("CLOSE PLAN"))")
        print("Target:     \(plan.activity.process.command) (PID \(plan.pid))")
        print("Executable: \(compactPath(plan.executablePath))")
        print("Started:    \(plan.startTime)")
        if !plan.otherPorts.isEmpty {
            print(yellow("Warning:    This PID also listens on \(plan.otherPorts.map(String.init).joined(separator: ", ")); those ports may close too."))
        }
        if !plan.peerPIDs.isEmpty {
            print(yellow("Notice:     Other PIDs share this port: \(plan.peerPIDs.map(String.init).joined(separator: ", ")); only PID \(plan.pid) will be signalled."))
        }

        if dryRun {
            print(dim("\nDry run mode: no signal sent.\n"))
            return
        }

        if !autoConfirm {
            if isatty(STDIN_FILENO) == 0 {
                print("An interactive terminal is required; use --yes to confirm non-interactively.")
                exit(1)
            }
            print("\nClose PID \(plan.pid) listening on port \(port)? [y/N] ", terminator: "")
            fflush(stdout)
            guard let line = readLine(), ["y", "yes"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                print("Cancelled.")
                return
            }
        }

        print("Sending SIGTERM to PID \(plan.pid)…")
        let result = try CloseService.execute(plan)
        if result.portFree {
            print("\(green("SUCCESS")) Port \(port) is free.")
        } else if result.targetStoppedListening {
            print("\(yellow("PARTIAL")) PID \(plan.pid) stopped listening; port \(port) is still held by \(result.remainingPIDs.map(String.init).joined(separator: ", ")).")
        } else {
            print("\(yellow("WARNING")) SIGTERM was sent, but PID \(plan.pid) is still listening. No force-kill was attempted.")
        }
    } catch {
        print("\(red("ERROR")) \(error.localizedDescription)")
        exit(1)
    }
}

func runOpen(port: Int, activities: [Activity]) {
    let urlString = "http://localhost:\(port)"
    let isListening = activities.contains { $0.listener.port == port }
    if !isListening {
        print(yellow("Notice: Nothing was detected listening on port \(port)."))
    }
    print("Opening \(cyan(urlString)) in default browser…")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [urlString]
    try? process.run()
    process.waitUntilExit()
}

func printJSON(snapshot: ScanSnapshot) {
    var list: [[String: Any]] = []
    for a in snapshot.activities {
        var item: [String: Any] = [
            "port": a.listener.port,
            "url": "http://localhost:\(a.listener.port)",
            "addresses": a.listener.addresses,
            "scope": a.scope.rawValue,
            "pid": a.process.pid,
            "command": a.process.command,
            "uptime": a.process.uptime as Any,
            "rawElapsedTime": a.process.rawElapsedTime as Any,
            "rssKB": a.process.rssKB as Any,
            "memory": a.process.memoryUsage as Any,
            "cwd": a.process.cwd as Any,
            "executable": a.process.executablePath as Any,
            "user": a.process.user as Any,
            "owner": [
                "label": a.inference.label,
                "category": a.inference.category.rawValue,
                "confidence": a.inference.confidence,
                "reason": a.inference.reason
            ]
        ]
        if let m = a.projectMarker {
            item["project"] = ["name": m.name, "root": m.root, "source": m.source]
        }
        list.append(item)
    }
    let dict: [String: Any] = [
        "portCount": snapshot.portCount,
        "lanPortCount": snapshot.lanPortCount,
        "activities": list,
        "limitations": snapshot.limitations
    ]
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func runBatchCloseProjects(dryRun: Bool, autoConfirm: Bool, activities: [Activity]) {
    guard !activities.isEmpty else {
        print("\(yellow("NO PROJECTS")) No running dev project servers found.")
        return
    }
    do {
        let plans = try CloseService.prepareBatch(activities: activities)
        guard !plans.isEmpty else {
            print("\(yellow("NO CLOSABLE TARGETS")) No closable dev project servers found.")
            return
        }
        print("\n\(bold("BATCH CLOSE PLAN")) (\(plans.count) project server\(plans.count == 1 ? "" : "s"))")
        for plan in plans {
            let ramStr = plan.activity.process.memoryUsage.map { " (\($0))" } ?? ""
            print("  • Port \(plan.port): \(plan.activity.inference.label) — PID \(plan.pid)\(ramStr)")
        }
        if dryRun {
            print(dim("\nDry run mode: no signal sent.\n"))
            return
        }
        if !autoConfirm {
            if isatty(STDIN_FILENO) == 0 {
                print("An interactive terminal is required; use --yes to confirm non-interactively.")
                exit(1)
            }
            print("\nClose all \(plans.count) dev project servers? [y/N] ", terminator: "")
            fflush(stdout)
            guard let line = readLine(), ["y", "yes"].contains(line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                print("Cancelled.")
                return
            }
        }
        print("Sending SIGTERM to \(plans.count) processes…")
        let result = try CloseService.executeBatch(plans)
        if result.isAllSuccessful {
            print("\(green("SUCCESS")) Closed \(result.successfulPlans.count) project server\(result.successfulPlans.count == 1 ? "" : "s").")
        } else {
            print("\(yellow("PARTIAL")) Closed \(result.successfulPlans.count) of \(result.totalCount) servers.")
            for failure in result.failedPlans {
                print("  \(red("FAILED")) PID \(failure.plan.pid) (Port \(failure.plan.port)): \(failure.error)")
            }
        }
    } catch {
        print("\(red("ERROR")) \(error.localizedDescription)")
        exit(1)
    }
}

func printHelp() {
    print("""
\(bold("LeftOpen")) — See what your tools left running on localhost.

Usage:
  leftopen [list]               Show all listening activity
  leftopen <port>               Explain who owns a port
  leftopen open <port>          Open http://localhost:<port> in default browser
  leftopen close <port>         Gracefully close the process listening on a port
  leftopen close --all-projects Gracefully close all dev project servers
  leftopen --json               Print machine-readable output

Options:
  --projects             Show dev project ports only
  --pid <pid>            Select a PID when multiple processes share a port
  --dry-run              Preview a close without signalling anything
  --yes, -y              Confirm a close without an interactive prompt
  --no-color             Disable terminal colours
  -h, --help             Show this help
  -v, --version          Show the version
""")
}

// Main execution
let args = Array(CommandLine.arguments.dropFirst())

if args.contains("-h") || args.contains("--help") {
    printHelp()
    exit(0)
}

if args.contains("-v") || args.contains("--version") {
    print("LeftOpen 0.3.2")
    exit(0)
}

let snapshot: ScanSnapshot
do {
    snapshot = try Scanner.scan()
} catch {
    print("\(red("ERROR")) Scan failed: \(error.localizedDescription)")
    exit(1)
}

if args.contains("--json") {
    printJSON(snapshot: snapshot)
    exit(0)
}

let nonFlagArgs = args.filter { !$0.hasPrefix("-") }
let isProjectsOnly = args.contains("--projects")
let effectiveActivities = isProjectsOnly ? snapshot.activities.filter { $0.inference.category == .project } : snapshot.activities

if nonFlagArgs.isEmpty || nonFlagArgs == ["list"] || nonFlagArgs == ["ls"] {
    printOverview(activities: effectiveActivities)
    exit(0)
}

if nonFlagArgs[0] == "open" {
    guard nonFlagArgs.count >= 2, let port = Int(nonFlagArgs[1]), port >= 1, port <= 65535 else {
        print("\(red("ERROR")) Invalid or missing port. Usage: leftopen open <port>")
        exit(1)
    }
    runOpen(port: port, activities: snapshot.activities)
    exit(0)
}

if nonFlagArgs[0] == "close" {
    let dryRun = args.contains("--dry-run")
    let autoConfirm = args.contains("--yes") || args.contains("-y")
    if args.contains("--all-projects") || args.contains("--all") || (nonFlagArgs.count >= 2 && (nonFlagArgs[1] == "all" || nonFlagArgs[1] == "projects")) {
        runBatchCloseProjects(dryRun: dryRun, autoConfirm: autoConfirm, activities: snapshot.closableProjectActivities)
        exit(0)
    }
    guard nonFlagArgs.count >= 2, let port = Int(nonFlagArgs[1]), port >= 1, port <= 65535 else {
        print("\(red("ERROR")) Invalid or missing port. Usage: leftopen close <port> or leftopen close --all-projects")
        exit(1)
    }
    var targetPID: Int32? = nil
    if let pidIdx = args.firstIndex(of: "--pid"), pidIdx + 1 < args.count {
        targetPID = Int32(args[pidIdx + 1])
    }
    runClose(port: port, targetPID: targetPID, dryRun: dryRun, autoConfirm: autoConfirm, activities: snapshot.activities)
    exit(0)
}

if let port = Int(nonFlagArgs[0]), port >= 1, port <= 65535 {
    printDetail(port: port, activities: snapshot.activities)
    exit(0)
}

if nonFlagArgs[0] == "info" || nonFlagArgs[0] == "get", nonFlagArgs.count >= 2, let port = Int(nonFlagArgs[1]) {
    printDetail(port: port, activities: snapshot.activities)
    exit(0)
}

printHelp()
exit(1)
