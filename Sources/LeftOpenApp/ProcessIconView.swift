import AppKit
import LeftOpenCore
import SwiftUI

enum ProcessIconType: Equatable {
    case appBundle(path: String)
    /// Favicon fetched from the live server. `backgroundColor` is nil when the image is opaque.
    case dynamicImage(image: NSImage, backgroundColor: Color?)
    /// Icon found on disk (project `public/`, node package assets…). `backgroundColor` is nil when the image is opaque.
    case imageFile(path: String, backgroundColor: Color?)
    case symbol(name: String, color: Color)
}

/// Derives a tile background for icons with transparency so favicons stay legible on light and dark menus.
/// Returns nil for (mostly) opaque images, which render full-bleed instead.
enum IconBackgroundAnalyzer {
    private static let sampleSize = 24
    private static let transparencyThreshold = 0.15

    static func backgroundColor(for image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = sampleSize, height = sampleSize
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        var transparent = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            if a < 0.1 {
                transparent += 1
                continue
            }
            // Un-premultiply so light icons on transparent ground don't skew dark.
            r += Double(pixels[i]) / 255
            g += Double(pixels[i + 1]) / 255
            b += Double(pixels[i + 2]) / 255
            weight += a
        }
        let total = width * height
        guard weight > 0, Double(transparent) / Double(total) >= transparencyThreshold else { return nil }
        return Color(red: r / weight, green: g / weight, blue: b / weight)
    }
}

final class DynamicFaviconFetcher: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = DynamicFaviconFetcher()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.0
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Accept self-signed certificates on localhost (e.g. Syncthing, local dev HTTPS)
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Loopback hosts to try for a listener, derived from what it actually binds to:
    /// `[::1]`-only servers (common with Node) refuse `127.0.0.1`.
    static func probeHosts(for addresses: [String]) -> [String] {
        var hosts: [String] = []
        func add(_ h: String) { if !hosts.contains(h) { hosts.append(h) } }
        for raw in addresses {
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            switch clean {
            case "*": add("127.0.0.1"); add("[::1]")
            case "0.0.0.0", "127.0.0.1", "localhost": add("127.0.0.1")
            case "::", "::1": add("[::1]")
            default: add(clean.contains(":") ? "[\(clean)]" : clean)
            }
        }
        return hosts.isEmpty ? ["127.0.0.1"] : hosts
    }

    func fetchFavicon(port: Int, hosts: [String] = ["127.0.0.1"]) async -> NSImage? {
        for host in hosts {
            for scheme in ["http", "https"] {
                guard let rootURL = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
                var req = URLRequest(url: rootURL)
                req.setValue("localhost:\(port)", forHTTPHeaderField: "Host")
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")

                do {
                    let (data, response) = try await session.data(for: req)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                       let html = String(data: data, encoding: .utf8) {
                        for iconURL in extractIconURLs(from: html, base: rootURL) {
                            if let img = await fetchImage(url: iconURL, host: "localhost:\(port)") {
                                return img
                            }
                        }
                    }
                } catch let error as URLError where error.code == .cannotConnectToHost {
                    // Nothing bound on this host at all; don't bother with the fallback paths.
                    continue
                } catch {}

                for fallbackPath in ["favicon.ico", "apple-touch-icon.png"] {
                    if let favURL = URL(string: "\(scheme)://\(host):\(port)/\(fallbackPath)"),
                       let img = await fetchImage(url: favURL, host: "localhost:\(port)") {
                        return img
                    }
                }
            }
        }
        return nil
    }

    private func fetchImage(url: URL, host: String) async -> NSImage? {
        var req = URLRequest(url: url)
        req.setValue(host, forHTTPHeaderField: "Host")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    private func extractIconURLs(from html: String, base: URL) -> [URL] {
        IconLinkParser.hrefs(in: html).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }
}

/// Pulls `href`s out of `<link rel="…icon…">` tags. Shared by the live fetcher and the
/// on-disk project scan (a Vite/Tauri project's `index.html` declares its own favicon).
enum IconLinkParser {
    private static let tagRegex = try! NSRegularExpression(pattern: #"<link[^>]+>"#, options: .caseInsensitive)
    private static let hrefRegex = try! NSRegularExpression(pattern: #"(?<![a-zA-Z-])href=["']([^"'>]+)["']"#, options: .caseInsensitive)

    static func hrefs(in html: String) -> [String] {
        var results: [String] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in tagRegex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            guard tag.lowercased().contains("icon") else { continue }
            let tagRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            guard let hrefMatch = hrefRegex.firstMatch(in: tag, range: tagRange),
                  let hrefR = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            let href = String(tag[hrefR])
            // Skip unrendered template placeholders like `favicon-{{status}}.png`.
            guard !href.contains("{") else { continue }
            results.append(href)
        }
        return results
    }
}

@MainActor
final class ProcessIconCache: ObservableObject {
    static let shared = ProcessIconCache()
    private let imageCache = NSCache<NSString, NSImage>()
    private var backgroundCache: [String: Color?] = [:]
    // Keyed by Activity.id (port:pid) so a different server reusing a port is re-probed.
    private var dynamicFavicons: [String: ProcessIconType] = [:]
    private var attemptedFavicons = Set<String>()
    // Per-directory resolution (project root or npm package dir); a stored nil means "looked, nothing there".
    private var directoryIconCache: [String: ProcessIconType?] = [:]

    /// Bumped whenever a fetched favicon lands so views re-resolve.
    @Published private(set) var dynamicVersion: Int = 0

    private init() {}

    func dynamicFavicon(for activity: Activity) -> ProcessIconType? {
        dynamicFavicons[activity.id]
    }

    func loadDynamicFaviconIfNeeded(for activity: Activity) {
        let key = activity.id
        guard dynamicFavicons[key] == nil, !attemptedFavicons.contains(key) else { return }
        attemptedFavicons.insert(key)

        let port = activity.listener.port
        let hosts = DynamicFaviconFetcher.probeHosts(for: activity.listener.addresses)
        Task {
            guard let image = await DynamicFaviconFetcher.shared.fetchFavicon(port: port, hosts: hosts) else { return }
            let background = IconBackgroundAnalyzer.backgroundColor(for: image)
            dynamicFavicons[key] = .dynamicImage(image: image, backgroundColor: background)
            dynamicVersion &+= 1
        }
    }

    func image(forFile path: String) -> NSImage {
        let key = path as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if ["png", "svg", "ico", "jpg", "jpeg", "icns"].contains(ext) {
            if let direct = NSImage(contentsOfFile: path) {
                imageCache.setObject(direct, forKey: key)
                return direct
            }
        }
        // IconServices icons carry dozens of lazily rendered reps; SwiftUI's Image(nsImage:) picks
        // badly among them at small sizes and draws garbage. Flatten to one bitmap first.
        let image = Self.rasterized(NSWorkspace.shared.icon(forFile: path), pixels: 128)
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static func rasterized(_ source: NSImage, pixels: Int) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let flat = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        flat.addRepresentation(rep)
        return flat
    }

    func backgroundColor(forFile path: String) -> Color? {
        if let cached = backgroundCache[path] { return cached }
        let color = IconBackgroundAnalyzer.backgroundColor(for: image(forFile: path))
        backgroundCache[path] = color
        return color
    }

    /// Returns `.some(nil)` for a directory already scanned without a result.
    func cachedDirectoryIcon(_ dir: String) -> ProcessIconType?? {
        directoryIconCache[dir]
    }

    func setCachedDirectoryIcon(_ type: ProcessIconType?, _ dir: String) {
        directoryIconCache[dir] = .some(type)
    }
}

struct ProcessIconResolver {
    @MainActor
    static func resolve(for activity: Activity) -> ProcessIconType {
        // Tier 1: Native macOS Application Bundle
        if let bundlePath = activity.applicationBundle?.path, FileManager.default.fileExists(atPath: bundlePath) {
            return .appBundle(path: bundlePath)
        }
        if let execPath = activity.process.executablePath, let found = bundlePath(from: execPath), FileManager.default.fileExists(atPath: found) {
            return .appBundle(path: found)
        }

        // Tier 2: Icon the project ships itself, else a framework symbol from its manifest.
        if let project = activity.projectMarker {
            if let cached = ProcessIconCache.shared.cachedDirectoryIcon(project.root) {
                if let cached { return cached }
            } else {
                let resolved = projectIconPath(in: project.root).map { imageFile($0) } ?? detectFramework(in: project)
                ProcessIconCache.shared.setCachedDirectoryIcon(resolved, project.root)
                if let resolved { return resolved }
            }
        }

        // Tier 2b: Icon shipped inside the npm package a global CLI runs from (e.g. its bundled web UI).
        if let args = activity.process.arguments, let package = NodePackageLocator.locate(inArguments: args) {
            if let cached = ProcessIconCache.shared.cachedDirectoryIcon(package.directory) {
                if let cached { return cached }
            } else {
                let resolved = packageIconPath(in: package.directory).map { imageFile($0) }
                ProcessIconCache.shared.setCachedDirectoryIcon(resolved, package.directory)
                if let resolved { return resolved }
            }
        }

        // Tier 3: Favicon fetched from the live server (populated asynchronously by ProcessIconView).
        if let fetched = ProcessIconCache.shared.dynamicFavicon(for: activity) {
            return fetched
        }

        // Tier 4: Command & Executable Identification
        let cmd = activity.process.command.lowercased()
        let exec = (activity.process.executablePath as NSString?)?.lastPathComponent.lowercased() ?? ""
        let args = (activity.process.arguments ?? "").lowercased()
        let label = activity.inference.label.lowercased()
        let target = exec.isEmpty ? cmd : exec

        if target.contains("docker") || target.contains("colima") || target.contains("containerd") || target.contains("podman") {
            return .symbol(name: "shippingbox.fill", color: Color(red: 0.08, green: 0.55, blue: 0.94))
        }
        if target.contains("postgres") || target.contains("pg_ctl") {
            return .symbol(name: "cylinder.split.1x2.fill", color: Color(red: 0.20, green: 0.39, blue: 0.58))
        }
        if target.contains("redis") || target.contains("valkey") || target.contains("keydb") || target.contains("dragonfly") {
            return .symbol(name: "cylinder.split.1x2.fill", color: Color(red: 0.85, green: 0.20, blue: 0.18))
        }
        if target.contains("mysql") || target.contains("mariadb") {
            return .symbol(name: "cylinder.split.1x2.fill", color: Color(red: 0.93, green: 0.58, blue: 0.15))
        }
        if target.contains("clickhouse") || target.contains("surreal") {
            return .symbol(name: "cylinder.split.1x2.fill", color: Color(red: 0.95, green: 0.70, blue: 0.10))
        }
        if target.contains("mongod") || target.contains("mongo") {
            return .symbol(name: "leaf.fill", color: Color(red: 0.25, green: 0.64, blue: 0.33))
        }
        if target.contains("qdrant") || target.contains("milvus") || target.contains("chroma") {
            return .symbol(name: "circle.grid.3x3.fill", color: Color(red: 0.30, green: 0.60, blue: 0.85))
        }
        if target.contains("meilisearch") || target.contains("typesense") {
            return .symbol(name: "magnifyingglass", color: Color(red: 0.95, green: 0.25, blue: 0.45))
        }
        if target.contains("ollama") || target.contains("llama") || target.contains("vllm") || target.contains("lmstudio") || target.contains("open-webui") || target.contains("localai") || target.contains("jan") || target.contains("dify") || args.contains("ollama") || label.contains("ollama") {
            if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") && (target.contains("ollama") || args.contains("ollama")) {
                return .appBundle(path: "/Applications/Ollama.app")
            }
            return .symbol(name: "brain.head.profile", color: .purple)
        }
        if target.contains("comfyui") || args.contains("comfyui") {
            return .symbol(name: "paintpalette.fill", color: Color(red: 0.95, green: 0.45, blue: 0.20))
        }
        if target.contains("ngrok") || target.contains("cloudflared") || target.contains("localtunnel") || target.contains("tailscale") {
            return .symbol(name: "network", color: Color(red: 0.20, green: 0.70, blue: 0.85))
        }
        if target.contains("stripe") {
            return .symbol(name: "creditcard.fill", color: Color(red: 0.40, green: 0.45, blue: 0.90))
        }
        if target.contains("supabase") {
            return .symbol(name: "bolt.fill", color: Color(red: 0.25, green: 0.80, blue: 0.55))
        }
        if target.contains("nginx") || target.contains("caddy") || target.contains("httpd") || target.contains("apache") || target.contains("traefik") {
            return .symbol(name: "server.rack", color: .teal)
        }
        if target.contains("syncthing") || args.contains("syncthing") || label.contains("syncthing") {
            if FileManager.default.fileExists(atPath: "/Applications/Syncthing.app") {
                return .appBundle(path: "/Applications/Syncthing.app")
            }
            return .symbol(name: "arrow.triangle.2.circlepath.circle.fill", color: Color(red: 0.15, green: 0.60, blue: 0.85))
        }
        if target == "node" || target == "bun" || target == "deno" || target == "ts-node" || target == "npm" || target == "yarn" || target == "pnpm" {
            return .symbol(name: "curlybraces", color: Color(red: 0.35, green: 0.65, blue: 0.25))
        }
        if target.contains("python") || target == "uvicorn" || target == "gunicorn" || target == "flask" || target == "fastapi" || target == "django" || target == "jupyter" {
            return .symbol(name: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.23, green: 0.47, blue: 0.68))
        }
        if target == "cargo" || target == "rustc" {
            return .symbol(name: "gearshape.2.fill", color: Color(red: 0.88, green: 0.35, blue: 0.16))
        }
        if target == "go" || target == "dlv" {
            return .symbol(name: "bolt.fill", color: Color(red: 0.0, green: 0.66, blue: 0.82))
        }
        if target.contains("java") || target.contains("gradle") || target.contains("kotlin") {
            return .symbol(name: "cup.and.saucer.fill", color: Color(red: 0.88, green: 0.25, blue: 0.15))
        }
        if target.contains("ruby") || target.contains("rails") || target.contains("puma") {
            return .symbol(name: "diamond.fill", color: Color(red: 0.80, green: 0.15, blue: 0.15))
        }

        // Category fallbacks
        switch activity.inference.category {
        case .project:
            return .symbol(name: "folder.fill", color: .blue)
        case .application:
            return .symbol(name: "app.fill", color: .gray)
        case .service:
            return .symbol(name: "server.rack", color: .indigo)
        case .systemService:
            return .symbol(name: "gearshape.fill", color: .secondary)
        case .unknown:
            return .symbol(name: "terminal", color: .secondary)
        }
    }

    /// Highest-fidelity icon a project ships itself: desktop app icons (Tauri/Electron) first,
    /// then whatever its `index.html` declares, then common web-framework conventions.
    private static let projectIconCandidates = [
        // Tauri / Electron app icons
        "src-tauri/icons/icon.icns", "src-tauri/icons/icon.png", "app-icon.png",
        "build/icon.icns", "build/icon.png", "buildResources/icon.png", "resources/icon.png",
        // Next.js app router
        "app/apple-icon.png", "app/icon.png", "app/icon.svg", "app/favicon.ico",
        "src/app/apple-icon.png", "src/app/icon.png", "src/app/icon.svg", "src/app/favicon.ico",
        // Vite / CRA / Nuxt / Astro (`public/`), SvelteKit (`static/`)
        "public/apple-touch-icon.png", "public/icon.png", "public/icon.svg", "public/logo.svg", "public/logo.png",
        "public/favicon.svg", "public/favicon.png", "public/favicon.ico",
        "static/apple-touch-icon.png", "static/favicon.svg", "static/favicon.png", "static/favicon.ico",
        "assets/favicon.svg", "assets/favicon.png", "assets/favicon.ico",
        // Bare roots
        "favicon.svg", "favicon.png", "favicon.ico", "icon.png",
    ]

    static func projectIconPath(in root: String) -> String? {
        let fm = FileManager.default
        func existing(_ rel: String) -> String? {
            let path = (root as NSString).appendingPathComponent(rel)
            return fm.fileExists(atPath: path) ? path : nil
        }

        let appIcons = projectIconCandidates.prefix { $0.hasPrefix("src-tauri/") || $0 == "app-icon.png" || $0.hasPrefix("build") || $0.hasPrefix("resources/") }
        for rel in appIcons { if let p = existing(rel) { return p } }

        // Vite-style root index.html: `<link rel="icon" href="/x.png?v=1">` → public/x.png or x.png
        if let data = fm.contents(atPath: (root as NSString).appendingPathComponent("index.html")),
           let html = String(data: data, encoding: .utf8) {
            for href in IconLinkParser.hrefs(in: html) where !href.hasPrefix("http") && !href.hasPrefix("//") {
                let rel = href.split(separator: "?", maxSplits: 1)[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !rel.isEmpty, !rel.contains("..") else { continue }
                if let p = existing("public/" + rel) ?? existing(rel) { return p }
            }
        }

        for rel in projectIconCandidates.dropFirst(appIcons.count) { if let p = existing(rel) { return p } }
        return nil
    }

    /// Whether it is worth sending an HTTP probe to this listener. Skips OS services and
    /// known non-HTTP daemons (databases) so we don't spam their logs with protocol errors.
    static func shouldProbeFavicon(for activity: Activity) -> Bool {
        guard activity.inference.category != .systemService else { return false }
        let exec = (activity.process.executablePath as NSString?)?.lastPathComponent.lowercased()
        let target = exec ?? activity.process.command.lowercased()
        let nonHTTP = ["postgres", "pg_ctl", "redis", "valkey", "keydb", "mysql", "mariadb", "mongod", "rabbitmq", "memcached"]
        return !nonHTTP.contains { target.contains($0) }
    }

    private static func bundlePath(from path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for part in path.split(separator: "/") {
            parts.append(String(part))
            if part.lowercased().hasSuffix(".app") {
                return "/" + parts.joined(separator: "/")
            }
        }
        return nil
    }

    @MainActor
    private static func imageFile(_ path: String) -> ProcessIconType {
        .imageFile(path: path, backgroundColor: ProcessIconCache.shared.backgroundColor(forFile: path))
    }

    /// Conventional icon filenames, best first.
    private static let packageIconNames = [
        "apple-touch-icon.png", "icon.png", "favicon.svg", "favicon.png", "favicon.ico", "logo.svg", "logo.png",
    ]

    /// Shallow search (≤ 3 levels, skipping node_modules and dot-dirs) for a bundled UI icon in an
    /// npm package. Packages lay out their built UI however they like, so no directory is assumed.
    static func packageIconPath(in root: String) -> String? {
        let fm = FileManager.default
        var found: [String: String] = [:]   // filename → shallowest path
        var frontier = [root]
        for _ in 0..<3 {
            var next: [String] = []
            for dir in frontier {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where !entry.hasPrefix(".") && entry != "node_modules" {
                    let path = (dir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        next.append(path)
                    } else if packageIconNames.contains(entry), found[entry] == nil {
                        found[entry] = path
                    }
                }
            }
            if let best = packageIconNames.first(where: { found[$0] != nil }) { return found[best] }
            frontier = next
        }
        return nil
    }

    private static func detectFramework(in project: ProjectMarker) -> ProcessIconType? {
        if project.source == "package.json" {
            let pkgPath = (project.root as NSString).appendingPathComponent("package.json")
            if let data = FileManager.default.contents(atPath: pkgPath),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let deps = (json["dependencies"] as? [String: Any]) ?? [:]
                let devDeps = (json["devDependencies"] as? [String: Any]) ?? [:]
                let allDeps = Set(deps.keys).union(devDeps.keys)

                if allDeps.contains("next") {
                    return .symbol(name: "arrow.triangle.swap", color: .primary)
                }
                if allDeps.contains("vite") {
                    return .symbol(name: "bolt.fill", color: .purple)
                }
                if allDeps.contains("astro") {
                    return .symbol(name: "flame.fill", color: .orange)
                }
                if allDeps.contains("nuxt") || allDeps.contains("vue") {
                    return .symbol(name: "v.circle.fill", color: .green)
                }
                if allDeps.contains("svelte") || allDeps.contains("@sveltejs/kit") {
                    return .symbol(name: "s.circle.fill", color: .orange)
                }
                if allDeps.contains("react") || allDeps.contains("react-dom") {
                    return .symbol(name: "atom", color: .cyan)
                }
                if allDeps.contains("express") || allDeps.contains("@nestjs/core") || allDeps.contains("fastify") {
                    return .symbol(name: "server.rack", color: Color(red: 0.35, green: 0.65, blue: 0.25))
                }
            }
            return .symbol(name: "curlybraces", color: Color(red: 0.35, green: 0.65, blue: 0.25))
        }

        if project.source == "Cargo.toml" {
            return .symbol(name: "gearshape.2.fill", color: Color(red: 0.88, green: 0.35, blue: 0.16))
        }
        if project.source == "pyproject.toml" {
            return .symbol(name: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.23, green: 0.47, blue: 0.68))
        }
        if project.source == "go.mod" {
            return .symbol(name: "bolt.fill", color: Color(red: 0.0, green: 0.66, blue: 0.82))
        }
        if project.source == "Package.swift" {
            return .symbol(name: "swift", color: Color(red: 0.98, green: 0.38, blue: 0.18))
        }
        if project.source == "pubspec.yaml" {
            return .symbol(name: "app.connected.to.app.below.fill", color: Color(red: 0.10, green: 0.60, blue: 0.98))
        }
        if project.source == "Gemfile" {
            return .symbol(name: "diamond.fill", color: Color(red: 0.80, green: 0.15, blue: 0.15))
        }
        if project.source == "composer.json" {
            return .symbol(name: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.40, green: 0.45, blue: 0.70))
        }
        if project.source == "pom.xml" || project.source == "build.gradle" || project.source == "build.gradle.kts" {
            return .symbol(name: "cup.and.saucer.fill", color: Color(red: 0.88, green: 0.25, blue: 0.15))
        }
        if project.source == "deno.json" || project.source == "deno.jsonc" {
            return .symbol(name: "d.circle.fill", color: .primary)
        }
        if project.source == "bunfig.toml" {
            return .symbol(name: "circle.fill", color: Color(red: 0.95, green: 0.85, blue: 0.70))
        }
        if project.source == "mix.exs" {
            return .symbol(name: "drop.fill", color: Color(red: 0.55, green: 0.25, blue: 0.65))
        }

        return nil
    }
}

struct ProcessIconView: View {
    let activity: Activity
    var size: CGFloat = 20
    // Observed so rows re-resolve once a fetched favicon lands.
    @ObservedObject private var cache = ProcessIconCache.shared

    var body: some View {
        let iconType = ProcessIconResolver.resolve(for: activity)
        Group {
            switch iconType {
            case .appBundle(let path):
                Image(nsImage: cache.image(forFile: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))

            case .imageFile(let path, let backgroundColor):
                imageTile(cache.image(forFile: path), backgroundColor: backgroundColor)

            case .dynamicImage(let image, let backgroundColor):
                imageTile(image, backgroundColor: backgroundColor)

            case .symbol(let name, let color):
                symbolTile(name: name, color: color)
            }
        }
        .task(id: activity.id) {
            guard case .symbol = iconType, ProcessIconResolver.shouldProbeFavicon(for: activity) else { return }
            cache.loadDynamicFaviconIfNeeded(for: activity)
        }
    }

    /// Opaque images fill the tile; transparent ones sit inset on a tint derived from the image itself.
    @ViewBuilder
    private func imageTile(_ image: NSImage, backgroundColor: Color?) -> some View {
        if let backgroundColor {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(backgroundColor.opacity(0.14))
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.68, height: size * 0.68)
            }
            .frame(width: size, height: size)
        } else {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    private func symbolTile(name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(color.opacity(0.12))
            Image(systemName: name)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}
