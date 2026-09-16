import Foundation

enum ScanError: LocalizedError {
    case commandFailed(String, Int32)
    case missingTool(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(tool, code): "\(tool) exited with status \(code)."
        case let .missingTool(tool): "\(tool) is not available on this Mac."
        }
    }
}

enum CommandRunner {
    static func output(_ executable: String, _ arguments: [String], allowEmptyLsof: Bool = false) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ScanError.missingTool(executable)
        }
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain while the child runs; waiting first can deadlock on a full pipe.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || (allowEmptyLsof && process.terminationStatus == 1) else {
            throw ScanError.commandFailed(executable, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Scanner {
    public static func parseListeners(_ output: String) -> [Listener] {
        var pid: Int32?
        var command = "unknown"
        var uid: Int32?
        var user: String?
        var byKey: [String: Listener] = [:]

        for raw in output.split(whereSeparator: \.isNewline) {
            guard let field = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = "unknown"
                uid = nil
                user = nil
            case "c": command = value.isEmpty ? "unknown" : value
            case "u": uid = Int32(value)
            case "L": user = value.isEmpty ? nil : value
            case "n":
                guard let pid, let endpoint = parseEndpoint(value) else { continue }
                let key = "\(pid):\(endpoint.port)"
                if var existing = byKey[key] {
                    if !existing.addresses.contains(endpoint.address) {
                        existing.addresses.append(endpoint.address)
                        byKey[key] = existing
                    }
                } else {
                    byKey[key] = Listener(pid: pid, command: command, uid: uid, user: user,
                                          port: endpoint.port, addresses: [endpoint.address])
                }
            default: break
            }
        }
        return byKey.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    private static func parseEndpoint(_ endpoint: String) -> (address: String, port: Int)? {
        guard let colon = endpoint.lastIndex(of: ":"), let port = Int(endpoint[endpoint.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        return (String(endpoint[..<colon]), port)
    }

    public static func listenerScope(_ addresses: [String]) -> ListenerScope {
        let loopback = addresses.allSatisfy { address in
            let clean = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            return clean == "127.0.0.1" || clean == "::1" || clean == "localhost"
        }
        return loopback ? .local : .lan
    }

    public static func scanListeners() throws -> [Listener] {
        let output = try CommandRunner.output("/usr/sbin/lsof",
            ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-FpcLun"], allowEmptyLsof: true)
        return parseListeners(output)
    }

    public static func scan() throws -> ScanSnapshot {
        let listeners = try scanListeners()
        let pids = Array(Set(listeners.map(\.pid))).sorted()
        let cwdByPID = try descriptorFacts(pids, "cwd")
        let executableByPID = try descriptorFacts(pids, "txt")
        var limitations: [String] = []
        let processTable: [Int32: ProcessFact]
        do {
            processTable = parseProcessTable(try CommandRunner.output("/bin/ps", ["-axo", "pid=,ppid=,comm="]))
        } catch {
            processTable = [:]
            limitations.append("The process table was unavailable; parent evidence is incomplete.")
        }

        var projects: [String: ProjectMarker] = [:]
        for cwd in Set(cwdByPID.values) {
            if let project = findProject(cwd) { projects[cwd] = project }
        }
        let activities = listeners.map { listener in
            let table = processTable[listener.pid]
            let process = ProcessFact(pid: listener.pid, ppid: table?.ppid, command: listener.command,
                executablePath: executableByPID[listener.pid] ?? table?.executablePath,
                uid: listener.uid, user: listener.user, cwd: cwdByPID[listener.pid])
            let parents = parentChain(for: process, in: processTable)
            let project = process.cwd.flatMap { projects[$0] }
            let bundle = applicationBundle(for: process, parents: parents)
            let inference = inferOwner(process: process, project: project, bundle: bundle)
            return Activity(listener: listener, process: process, parentChain: parents,
                projectMarker: project, applicationBundle: bundle,
                scope: listenerScope(listener.addresses), inference: inference)
        }
        return ScanSnapshot(activities: activities, limitations: limitations)
    }

    private static func descriptorFacts(_ pids: [Int32], _ descriptor: String) throws -> [Int32: String] {
        var results: [Int32: String] = [:]
        for start in stride(from: 0, to: pids.count, by: 100) {
            let chunk = pids[start..<min(start + 100, pids.count)]
            let output = try CommandRunner.output("/usr/sbin/lsof",
                ["-a", "-p", chunk.map(String.init).joined(separator: ","), "-d", descriptor, "-Fpn"],
                allowEmptyLsof: true)
            var currentPID: Int32?
            for raw in output.split(whereSeparator: \.isNewline) {
                guard let field = raw.first else { continue }
                let value = String(raw.dropFirst())
                if field == "p" { currentPID = Int32(value) }
                if field == "n", let currentPID, results[currentPID] == nil {
                    results[currentPID] = value
                }
            }
        }
        return results
    }

    private static func parseProcessTable(_ output: String) -> [Int32: ProcessFact] {
        var table: [Int32: ProcessFact] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard pieces.count >= 3, let pid = Int32(pieces[0]), let ppid = Int32(pieces[1]) else { continue }
            let rawCommand = pieces.dropFirst(2).joined(separator: " ")
            let executable = rawCommand.hasPrefix("/") ? rawCommand : nil
            let command = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? rawCommand
            table[pid] = ProcessFact(pid: pid, ppid: ppid, command: command,
                executablePath: executable, uid: nil, user: nil, cwd: nil)
        }
        return table
    }

    private static func parentChain(for process: ProcessFact, in table: [Int32: ProcessFact]) -> [ProcessFact] {
        var result: [ProcessFact] = []
        var seen: Set<Int32> = [process.pid]
        var parentPID = process.ppid
        while let pid = parentPID, pid > 0, !seen.contains(pid), result.count < 16 {
            seen.insert(pid)
            guard let parent = table[pid] else { break }
            result.append(parent)
            parentPID = parent.ppid
        }
        return result
    }

    private static func applicationBundle(for process: ProcessFact, parents: [ProcessFact]) -> ApplicationBundle? {
        if let path = process.executablePath, let bundle = bundlePath(path) {
            return ApplicationBundle(name: bundle.name, path: bundle.path, sourcePID: process.pid, direct: true)
        }
        if let parent = parents.first, let path = parent.executablePath, let bundle = bundlePath(path) {
            return ApplicationBundle(name: bundle.name, path: bundle.path, sourcePID: parent.pid, direct: false)
        }
        return nil
    }

    private static func bundlePath(_ path: String) -> (name: String, path: String)? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/") {
            parts.append(String(part))
            if part.lowercased().hasSuffix(".app") {
                let name = String(part.dropLast(4))
                return name.isEmpty ? nil : (name, "/" + parts.joined(separator: "/"))
            }
        }
        return nil
    }

    private static func inferOwner(process: ProcessFact, project: ProjectMarker?, bundle: ApplicationBundle?) -> OwnerInference {
        if let project {
            return OwnerInference(label: project.name, category: .project, confidence: "high",
                reason: "CWD is within a project root containing \(project.source) at \(project.markerPath).")
        }
        if let bundle {
            let reason = bundle.direct ? "The executable is inside \(bundle.path)." :
                "Direct parent PID \(bundle.sourcePID) runs inside \(bundle.path)."
            return OwnerInference(label: bundle.name, category: .application,
                confidence: bundle.direct ? "high" : "medium", reason: reason)
        }
        if let path = process.executablePath, isSystemExecutable(path) {
            return OwnerInference(label: URL(fileURLWithPath: path).lastPathComponent,
                category: .systemService, confidence: "high",
                reason: "Executable path \(path) is in an operating-system-managed location.")
        }
        return OwnerInference(label: "Unknown", category: .unknown, confidence: "none",
            reason: "No accepted project marker, application bundle, or system executable path established an owner.")
    }

    private static func isSystemExecutable(_ path: String) -> Bool {
        ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"].contains {
            path.hasPrefix($0)
        }
    }

    private static func findProject(_ cwd: String) -> ProjectMarker? {
        guard cwd.hasPrefix("/"), cwd != "/" else { return nil }
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let markers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod"]
        while directory != "/" {
            if !rejectProjectPath(directory, cwd: cwd) {
                for marker in markers {
                    let markerPath = (directory as NSString).appendingPathComponent(marker)
                    if FileManager.default.fileExists(atPath: markerPath) {
                        return ProjectMarker(name: projectName(directory, marker: marker), root: directory,
                            source: marker, markerPath: markerPath)
                    }
                }
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private static func rejectProjectPath(_ root: String, cwd: String) -> Bool {
        let lowerSegments = root.split(separator: "/").map { $0.lowercased() }
        if lowerSegments.contains(where: { $0.hasSuffix(".app") || ["node_modules", "cache", "caches", ".cache"].contains($0) }) {
            return true
        }
        let managed = ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/opt", "/private/var"]
        if managed.contains(where: { within(root, $0) }) { return true }
        let home = NSHomeDirectory()
        if within(root, home + "/Library") || root == home { return true }
        if within(root, home), let first = root.dropFirst(home.count).split(separator: "/").first,
           first.hasPrefix(".") { return true }
        return !within(cwd, root)
    }

    private static func within(_ candidate: String, _ parent: String) -> Bool {
        candidate == parent || candidate.hasPrefix(parent + "/")
    }

    private static func projectName(_ directory: String, marker: String) -> String {
        if marker == "package.json",
           let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(marker)),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        if marker == "pyproject.toml",
           let data = FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(marker)),
           let contents = String(data: data, encoding: .utf8) {
            var inProjectSection = false
            for line in contents.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("[") {
                    inProjectSection = text == "[project]"
                } else if inProjectSection, text.hasPrefix("name"), let equal = text.firstIndex(of: "=") {
                    let candidate = text[text.index(after: equal)...].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= 2,
                       (candidate.first == "\"" && candidate.last == "\"" ||
                        candidate.first == "'" && candidate.last == "'") {
                        return String(candidate.dropFirst().dropLast())
                    }
                }
            }
        }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}
