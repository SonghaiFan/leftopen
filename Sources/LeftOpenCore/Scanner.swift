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

public enum UptimeFormatter {
    public static func format(etime: String, compact: Bool = false) -> String? {
        let trimmed = etime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var days = 0
        var remaining = trimmed

        if let dashIndex = remaining.firstIndex(of: "-") {
            let dayStr = remaining[..<dashIndex]
            guard let d = Int(dayStr) else { return nil }
            days = d
            remaining = String(remaining[remaining.index(after: dashIndex)...])
        }

        let timeParts = remaining.split(separator: ":").compactMap { Int($0) }
        guard !timeParts.isEmpty else { return nil }

        let hours: Int
        let minutes: Int

        switch timeParts.count {
        case 2: // mm:ss
            hours = 0
            minutes = timeParts[0]
        case 3: // hh:mm:ss
            hours = timeParts[0]
            minutes = timeParts[1]
        default:
            return nil
        }

        if compact {
            if days > 0 {
                return "\(days)d"
            } else if hours > 0 {
                return "\(hours)h"
            } else if minutes > 0 {
                return "\(minutes)m"
            } else {
                return "< 1m"
            }
        }

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "< 1m"
        }
    }
}

extension ProcessFact {
    public var compactUptime: String? {
        guard let rawElapsedTime else { return uptime }
        return UptimeFormatter.format(etime: rawElapsedTime, compact: true) ?? uptime
    }
}

/// Finds the npm package a process was launched from by looking for `/node_modules/<pkg>/`
/// in its executable path or launch arguments. Indirection directories (`.bin`, `.pnpm`) are
/// skipped and the innermost real package wins, so pnpm layouts resolve to the actual package.
public enum NodePackageLocator {
    public struct Package: Equatable, Sendable {
        public let name: String
        public let directory: String
    }

    public static func locate(inArguments arguments: String) -> Package? {
        for token in arguments.split(whereSeparator: \.isWhitespace) {
            if let found = locate(inPath: String(token)) { return found }
        }
        return nil
    }

    public static func locate(inPath path: String, resolvingSymlinks: Bool = true) -> Package? {
        var searchRange = path.startIndex..<path.endIndex
        var best: Package?
        while let range = path.range(of: "/node_modules/", range: searchRange) {
            let segments = path[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
            if let first = segments.first, !first.isEmpty, !first.hasPrefix(".") {
                var name = String(first)
                if first.hasPrefix("@"), segments.count > 1, !segments[1].isEmpty {
                    name += "/" + segments[1]
                }
                best = Package(name: name, directory: String(path[..<range.upperBound]) + name)
            }
            searchRange = range.upperBound..<path.endIndex
        }
        if best == nil, resolvingSymlinks, path.contains("/node_modules/.bin/"), path.hasPrefix("/") {
            // `.bin/next` is a symlink into the real package; follow it once.
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if resolved != path { return locate(inPath: resolved, resolvingSymlinks: false) }
        }
        return best
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
        let argumentsByPID = commandArguments(pids)
        var limitations: [String] = []
        let processTable: [Int32: ProcessFact]
        do {
            processTable = parseProcessTable(try CommandRunner.output("/bin/ps", ["-axo", "pid=,ppid=,etime=,rss=,comm="]))
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
                uid: listener.uid, user: listener.user, cwd: cwdByPID[listener.pid],
                uptime: table?.uptime, rawElapsedTime: table?.rawElapsedTime,
                arguments: argumentsByPID[listener.pid],
                rssKB: table?.rssKB)
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

    private static func commandArguments(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        var results: [Int32: String] = [:]
        for start in stride(from: 0, to: pids.count, by: 100) {
            let chunk = pids[start..<min(start + 100, pids.count)]
            let pidArgs = chunk.map(String.init).joined(separator: ",")
            if let output = try? CommandRunner.output("/bin/ps", ["-ww", "-p", pidArgs, "-o", "pid=,command="]) {
                for line in output.split(whereSeparator: \.isNewline) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let firstSpace = trimmed.firstIndex(where: \.isWhitespace),
                          let pid = Int32(trimmed[..<firstSpace]) else { continue }
                    let args = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
                    results[pid] = args
                }
            }
        }
        return results
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

    static func parseProcessTable(_ output: String) -> [Int32: ProcessFact] {
        var table: [Int32: ProcessFact] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pieces = line.split(whereSeparator: \.isWhitespace)
            guard pieces.count >= 3, let pid = Int32(pieces[0]), let ppid = Int32(pieces[1]) else { continue }
            let etime: String?
            let rssKB: UInt64?
            let rawCommand: String
            if pieces.count >= 4 && (pieces[2].contains(":") || pieces[2].contains("-")) {
                etime = String(pieces[2])
                if pieces.count >= 5, let rss = UInt64(pieces[3]) {
                    rssKB = rss
                    rawCommand = pieces.dropFirst(4).joined(separator: " ")
                } else {
                    rssKB = nil
                    rawCommand = pieces.dropFirst(3).joined(separator: " ")
                }
            } else {
                etime = nil
                if pieces.count >= 4, let rss = UInt64(pieces[2]) {
                    rssKB = rss
                    rawCommand = pieces.dropFirst(3).joined(separator: " ")
                } else {
                    rssKB = nil
                    rawCommand = pieces.dropFirst(2).joined(separator: " ")
                }
            }
            let executable = rawCommand.hasPrefix("/") ? rawCommand : nil
            let command = executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? rawCommand
            let uptime = etime.flatMap { UptimeFormatter.format(etime: $0) }
            table[pid] = ProcessFact(pid: pid, ppid: ppid, command: command,
                executablePath: executable, uid: nil, user: nil, cwd: nil,
                uptime: uptime, rawElapsedTime: etime, rssKB: rssKB)
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
        if let interpreter = inferInterpreterOwner(process: process) {
            return interpreter
        }
        if let service = inferStandaloneService(process: process) {
            return service
        }
        if let path = process.executablePath, isUserInstalledExecutable(path) {
            let binaryName = URL(fileURLWithPath: path).lastPathComponent
            let humanLabel = formatBinaryName(binaryName)
            return OwnerInference(label: humanLabel, category: .service, confidence: "medium",
                reason: "Executable \(path) is a user-installed binary.")
        }
        return OwnerInference(label: "Unknown", category: .unknown, confidence: "none",
            reason: "No accepted project marker, application bundle, or system executable path established an owner.")
    }

    private static func inferInterpreterOwner(process: ProcessFact) -> OwnerInference? {
        let cmd = process.command.lowercased()
        let generic = ["node", "bun", "deno", "ts-node", "ruby", "perl"]
        guard generic.contains(cmd) || cmd.hasPrefix("python") else { return nil }

        // Check launch arguments for global npm package or python module
        if let args = process.arguments {
            if let package = NodePackageLocator.locate(inArguments: args) {
                let humanLabel = formatBinaryName(package.name)
                return OwnerInference(label: humanLabel, category: .service, confidence: "high",
                    reason: "Running npm package \(package.name) via \(process.command).")
            }
            if cmd.contains("python"), let module = extractPythonModule(from: args) {
                let humanLabel = formatBinaryName(module)
                return OwnerInference(label: humanLabel, category: .service, confidence: "high",
                    reason: "Running Python module \(module).")
            }
            if let framework = extractCLIOrFramework(from: args) {
                return OwnerInference(label: framework.label, category: .service, confidence: "high",
                    reason: framework.reason)
            }
        }

        // A daemon run from its own dot-directory (`~/.foo/`) is usually the tool called foo.
        // Skip runtime/version-manager/editor dirs where the cwd says nothing about the owner.
        if let cwd = process.cwd {
            let home = NSHomeDirectory()
            if cwd.hasPrefix(home + "/.") {
                let rest = cwd.dropFirst((home + "/.").count)
                let toolDir = String(rest.split(separator: "/").first ?? "")
                let notTools: Set<String> = [
                    "cache", "local", "config", "trash", "npm", "nvm", "bun", "pnpm", "yarn", "volta", "deno",
                    "cargo", "rustup", "pyenv", "venv", "virtualenvs", "gem", "rbenv", "asdf", "m2", "gradle",
                    "docker", "ssh", "vscode", "vscode-server", "cursor", "tmp",
                ]
                if !toolDir.isEmpty && !notTools.contains(toolDir.lowercased()) {
                    let humanLabel = formatBinaryName(toolDir)
                    return OwnerInference(label: humanLabel, category: .service, confidence: "medium",
                        reason: "Working directory is ~/.\(toolDir), the configuration directory of a tool by that name.")
                }
            }
        }
        return nil
    }

    private static func extractCLIOrFramework(from args: String) -> (label: String, reason: String)? {
        let lower = args.lowercased()
        let frameworks: [(pattern: String, label: String, reason: String)] = [
            ("streamlit run", "Streamlit", "Running Streamlit web application."),
            ("gradio", "Gradio", "Running Gradio machine learning interface."),
            ("jupyter-lab", "JupyterLab", "Running JupyterLab notebook server."),
            ("jupyter notebook", "Jupyter", "Running Jupyter notebook server."),
            ("uvicorn", "Uvicorn", "Running Uvicorn ASGI server."),
            ("gunicorn", "Gunicorn", "Running Gunicorn WSGI server."),
            ("celery", "Celery", "Running Celery distributed task worker."),
            ("comfyui", "ComfyUI", "Running ComfyUI interface server."),
            ("vllm", "vLLM", "Running vLLM inference server."),
        ]
        for item in frameworks {
            if lower.contains(item.pattern) {
                return (item.label, item.reason)
            }
        }
        return nil
    }

    private static func extractPythonModule(from args: String) -> String? {
        let pieces = args.split(whereSeparator: \.isWhitespace).map(String.init)
        if let mIndex = pieces.firstIndex(of: "-m"), mIndex + 1 < pieces.count {
            return pieces[mIndex + 1]
        }
        return nil
    }

    private static func inferStandaloneService(process: ProcessFact) -> OwnerInference? {
        let binary = (process.executablePath as NSString?)?.lastPathComponent.lowercased() ?? process.command.lowercased()

        let knownServices: [String: (label: String, reason: String)] = [
            "syncthing": ("Syncthing", "Standalone Syncthing continuous file synchronization daemon."),
            "ollama": ("Ollama", "Standalone Ollama local AI model server."),
            "llama-server": ("llama.cpp", "Local llama.cpp LLM inference server."),
            "llama.cpp": ("llama.cpp", "Local llama.cpp LLM inference server."),
            "vllm": ("vLLM", "High-throughput LLM serving engine."),
            "lmstudio": ("LM Studio", "LM Studio local AI server."),
            "lm-studio": ("LM Studio", "LM Studio local AI server."),
            "comfyui": ("ComfyUI", "Modular Stable Diffusion GUI & server."),
            "open-webui": ("Open WebUI", "Self-hosted AI interface server."),
            "localai": ("LocalAI", "OpenAI-compatible local AI server."),
            "jan": ("Jan", "Jan local AI assistant runtime."),
            "dify": ("Dify", "Dify LLM application development platform."),
            "text-generation-webui": ("Text Gen WebUI", "Text generation web UI server."),
            "qdrant": ("Qdrant", "Vector similarity search engine."),
            "milvus": ("Milvus", "Cloud-native vector database."),
            "chroma": ("Chroma", "AI embedding vector database."),
            "chromadb": ("Chroma", "AI embedding vector database."),
            "meilisearch": ("Meilisearch", "Fast, typo-tolerant search engine."),
            "typesense": ("Typesense", "Open source typo-tolerant search engine."),
            "clickhouse": ("ClickHouse", "Fast column-oriented DBMS."),
            "clickhouse-server": ("ClickHouse", "Fast column-oriented DBMS."),
            "surreal": ("SurrealDB", "Scalable multi-model cloud database."),
            "surrealdb": ("SurrealDB", "Scalable multi-model cloud database."),
            "dragonfly": ("Dragonfly", "Modern in-memory datastore."),
            "redis-server": ("Redis", "Standalone Redis in-memory database server."),
            "redis": ("Redis", "Standalone Redis in-memory database server."),
            "valkey-server": ("Valkey", "Standalone Valkey in-memory database server."),
            "postgres": ("PostgreSQL", "Standalone PostgreSQL relational database server."),
            "pg_ctl": ("PostgreSQL", "Standalone PostgreSQL database controller."),
            "mysqld": ("MySQL", "Standalone MySQL database server."),
            "mariadbd": ("MariaDB", "Standalone MariaDB database server."),
            "mongod": ("MongoDB", "Standalone MongoDB document database server."),
            "dockerd": ("Docker", "Standalone Docker container daemon."),
            "docker-proxy": ("Docker", "Docker port forwarding proxy."),
            "caddy": ("Caddy", "Standalone Caddy web server."),
            "nginx": ("Nginx", "Standalone Nginx web server / reverse proxy."),
            "httpd": ("Apache", "Standalone Apache HTTP server."),
            "traefik": ("Traefik", "Standalone Traefik cloud native reverse proxy."),
            "minio": ("MinIO", "Standalone MinIO high performance object storage."),
            "rabbitmq-server": ("RabbitMQ", "Standalone RabbitMQ message broker."),
            "ngrok": ("ngrok", "Reverse proxy tunnel to localhost."),
            "cloudflared": ("Cloudflare Tunnel", "Cloudflare Zero Trust tunnel client."),
            "localtunnel": ("localtunnel", "Exposes localhost to the world."),
            "tailscale": ("Tailscale", "Tailscale mesh VPN / Funnel service."),
            "tailscaled": ("Tailscale", "Tailscale mesh VPN daemon."),
            "stripe": ("Stripe CLI", "Stripe developer CLI & webhook forwarder."),
            "supabase": ("Supabase", "Supabase local development stack."),
        ]

        if let match = knownServices[binary] {
            return OwnerInference(label: match.label, category: .service, confidence: "high", reason: match.reason)
        }
        return nil
    }

    private static func isUserInstalledExecutable(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let roots = [
            "/opt/homebrew/", "/usr/local/",          // Homebrew (Apple Silicon / Intel) and manual installs
            "/opt/local/", "/nix/",                   // MacPorts, Nix
            home + "/.cargo/", home + "/go/", home + "/.local/",
            home + "/.nvm/", home + "/.volta/", home + "/.bun/", home + "/.deno/", home + "/.npm-global/",
            home + "/.pyenv/", home + "/.rbenv/", home + "/.asdf/",
        ]
        return roots.contains { path.hasPrefix($0) }
    }

    private static func formatBinaryName(_ name: String) -> String {
        let custom: [String: String] = [
            "openclaw": "OpenClaw",
            "syncthing": "Syncthing",
            "ollama": "Ollama",
            "llama-server": "llama.cpp",
            "vllm": "vLLM",
            "lmstudio": "LM Studio",
            "comfyui": "ComfyUI",
            "open-webui": "Open WebUI",
            "localai": "LocalAI",
            "dify": "Dify",
            "qdrant": "Qdrant",
            "milvus": "Milvus",
            "chroma": "Chroma",
            "chromadb": "Chroma",
            "meilisearch": "Meilisearch",
            "typesense": "Typesense",
            "clickhouse": "ClickHouse",
            "clickhouse-server": "ClickHouse",
            "surreal": "SurrealDB",
            "surrealdb": "SurrealDB",
            "dragonfly": "Dragonfly",
            "redis-server": "Redis",
            "redis": "Redis",
            "postgres": "PostgreSQL",
            "mysqld": "MySQL",
            "mariadbd": "MariaDB",
            "mongod": "MongoDB",
            "nginx": "Nginx",
            "caddy": "Caddy",
            "traefik": "Traefik",
            "docker": "Docker",
            "dockerd": "Docker",
            "uvicorn": "Uvicorn",
            "gunicorn": "Gunicorn",
            "fastapi": "FastAPI",
            "streamlit": "Streamlit",
            "gradio": "Gradio",
            "ngrok": "ngrok",
            "cloudflared": "Cloudflare Tunnel",
            "localtunnel": "localtunnel",
            "tailscale": "Tailscale",
            "tailscaled": "Tailscale",
            "stripe": "Stripe CLI",
            "supabase": "Supabase",
        ]
        if let known = custom[name.lowercased()] { return known }
        if name.count <= 3 { return name.uppercased() }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func isSystemExecutable(_ path: String) -> Bool {
        ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/"].contains {
            path.hasPrefix($0)
        }
    }

    private static func findProject(_ cwd: String) -> ProjectMarker? {
        guard cwd.hasPrefix("/"), cwd != "/" else { return nil }
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let markers = [
            ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod",
            "Package.swift", "pubspec.yaml", "Gemfile", "mix.exs", "composer.json",
            "pom.xml", "build.gradle", "build.gradle.kts", "deno.json", "deno.jsonc", "bunfig.toml"
        ]
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
        let fm = FileManager.default
        let markerPath = (directory as NSString).appendingPathComponent(marker)
        if marker == "package.json",
           let data = fm.contents(atPath: markerPath),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        if marker == "composer.json" || marker == "deno.json",
           let data = fm.contents(atPath: markerPath),
           let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let name = value["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if marker == "composer.json", let slash = trimmed.lastIndex(of: "/") {
                return String(trimmed[trimmed.index(after: slash)...])
            }
            return trimmed
        }
        if marker == "pyproject.toml",
           let data = fm.contents(atPath: markerPath),
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
        if marker == "pubspec.yaml",
           let data = fm.contents(atPath: markerPath),
           let contents = String(data: data, encoding: .utf8) {
            for line in contents.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("name:") {
                    let name = text.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " '\"\t"))
                    if !name.isEmpty { return name }
                }
            }
        }
        if marker == "Package.swift",
           let data = fm.contents(atPath: markerPath),
           let contents = String(data: data, encoding: .utf8) {
            if let regex = try? NSRegularExpression(pattern: #"name:\s*"([^"]+)""#),
               let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..<contents.endIndex, in: contents)),
               let r = Range(match.range(at: 1), in: contents) {
                let name = String(contents[r])
                if !name.isEmpty { return name }
            }
        }
        if marker == "pom.xml",
           let data = fm.contents(atPath: markerPath),
           let contents = String(data: data, encoding: .utf8) {
            if let regex = try? NSRegularExpression(pattern: #"<artifactId>([^<]+)</artifactId>"#),
               let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..<contents.endIndex, in: contents)),
               let r = Range(match.range(at: 1), in: contents) {
                let name = String(contents[r]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}
