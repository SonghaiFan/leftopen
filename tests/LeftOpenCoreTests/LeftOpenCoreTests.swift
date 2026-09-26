import Darwin
import Network
import XCTest
@testable import LeftOpenCore

final class LeftOpenCoreTests: XCTestCase {
    func testBrowserAddressUsesObservedBindAddress() {
        func url(_ addresses: [String]) -> String? {
            let listener = Listener(pid: 42, command: "node", uid: 501, user: nil,
                                    port: 3000, addresses: addresses)
            return BrowserAddress.candidateURL(for: listener)?.absoluteString
        }

        XCTAssertEqual(url(["127.0.0.1"]), "http://127.0.0.1:3000")
        XCTAssertEqual(url(["0.0.0.0"]), "http://localhost:3000")
        XCTAssertEqual(url(["*"]), "http://localhost:3000")
        XCTAssertEqual(url(["[::]"]), "http://[::1]:3000")
        XCTAssertEqual(url(["[::1]"]), "http://[::1]:3000")
        XCTAssertEqual(url(["192.168.1.20"]), "http://192.168.1.20:3000")
        XCTAssertEqual(url(["127.0.0.1", "192.168.1.20"]), "http://192.168.1.20:3000")
        XCTAssertNil(url(["not-an-address"]))

        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: 3000, addresses: ["192.168.1.20"])
        XCTAssertEqual(BrowserAddress.probeURLs(for: listener).map(\.absoluteString), [
            "https://192.168.1.20:3000", "http://192.168.1.20:3000",
        ])
    }

    func testWebProbeShowsOnlyRespondingHTTPService() async {
        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: 3000, addresses: ["127.0.0.1"])
        let httpConfig = URLSessionConfiguration.ephemeral
        httpConfig.protocolClasses = [HeadOnlyHTTPProtocol.self]
        let httpSession = URLSession(configuration: httpConfig)
        let found = await WebProbe.detect(listener, using: httpSession)
        XCTAssertEqual(found?.absoluteString, "http://127.0.0.1:3000")
        httpSession.invalidateAndCancel()

        let otherConfig = URLSessionConfiguration.ephemeral
        otherConfig.protocolClasses = [NonHTTPProtocol.self]
        let otherSession = URLSession(configuration: otherConfig)
        let missing = await WebProbe.detect(listener, using: otherSession)
        XCTAssertNil(missing)
        otherSession.invalidateAndCancel()

        let untrustedConfig = URLSessionConfiguration.ephemeral
        untrustedConfig.protocolClasses = [UntrustedHTTPSProtocol.self]
        let untrustedSession = URLSession(configuration: untrustedConfig)
        let untrusted = await WebProbe.detect(listener, using: untrustedSession)
        XCTAssertNil(untrusted)
        untrustedSession.invalidateAndCancel()

        let redirectConfig = URLSessionConfiguration.ephemeral
        redirectConfig.protocolClasses = [RedirectHTTPProtocol.self]
        let redirectSession = URLSession(configuration: redirectConfig)
        let redirect = await WebProbe.detect(listener, using: redirectSession)
        XCTAssertEqual(redirect?.absoluteString, "http://127.0.0.1:3000")
        redirectSession.invalidateAndCancel()
    }

    func testWebProbeAgainstRealLoopbackHTTP() async throws {
        let server = try NWListener(using: .tcp, on: .any)
        defer { server.cancel() }
        let queue = DispatchQueue(label: "leftopen.web-probe-test")
        let ready = expectation(description: "Loopback server ready")
        server.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        server.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 5, maximumLength: 4096) { data, _, _, _ in
                guard let data, String(decoding: data, as: UTF8.self).hasPrefix("HEAD ") else {
                    connection.cancel()
                    return
                }
                let response = Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.start(queue: queue)
        await fulfillment(of: [ready], timeout: 2)

        let port = try XCTUnwrap(server.port.map { Int($0.rawValue) })
        let listener = Listener(pid: 42, command: "service", uid: 501, user: nil,
                                port: port, addresses: ["127.0.0.1"])
        let found = await WebProbe.detect(listener)
        XCTAssertEqual(found?.absoluteString, "http://127.0.0.1:\(port)")
    }

    func testLsofMergesIPv4AndIPv6ForSamePIDAndPort() {
        let output = """
        p42
        cnode
        u501
        Lsong
        n127.0.0.1:3000
        n[::1]:3000
        p43
        cpython
        u501
        n*:8080
        """
        let values = Scanner.parseListeners(output)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].addresses, ["127.0.0.1", "[::1]"])
        XCTAssertEqual(values[0].uid, 501)
        XCTAssertEqual(values[0].user, "song")
        XCTAssertEqual(values[1].port, 8080)
    }

    func testScopeUsesOnlyObservedBindAddresses() {
        XCTAssertEqual(Scanner.listenerScope(["127.0.0.1", "[::1]"]), .local)
        XCTAssertEqual(Scanner.listenerScope(["127.0.0.1", "*"]), .lan)
    }

    func testCloseRecheckRejectsChangedIdentity() throws {
        let activity = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let plan = ClosePlan(port: 3000, pid: 42, uid: Int32(getuid()),
            executablePath: "/opt/local/bin/node", startTime: "start one", activity: activity,
            otherPorts: [], peerPIDs: [])
        XCTAssertThrowsError(try CloseService.verify(plan: plan, activities: [activity], freshStartTime: "start two"))
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [fixtureActivity(pid: 42, path: "/opt/local/bin/python")], freshStartTime: "start one"))
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [fixtureActivity(pid: 43, path: "/opt/local/bin/node")], freshStartTime: "start one"))
    }

    func testCloseRecheckRejectsNewPortPeer() throws {
        let activity = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let plan = ClosePlan(port: 3000, pid: 42, uid: Int32(getuid()),
            executablePath: "/opt/local/bin/node", startTime: "start one", activity: activity,
            otherPorts: [], peerPIDs: [])
        XCTAssertThrowsError(try CloseService.verify(plan: plan,
            activities: [activity, fixtureActivity(pid: 43, path: "/opt/local/bin/node")],
            freshStartTime: "start one"))
    }

    func testLiveScanProducesEvidenceBasedActivities() throws {
        let snapshot = try Scanner.scan()
        print("Native scan: \(snapshot.portCount) ports, \(snapshot.activities.count) activities")
        for activity in snapshot.activities {
            XCTAssertTrue((1...65535).contains(activity.listener.port))
            XCTAssertGreaterThan(activity.process.pid, 0)
            XCTAssertFalse(activity.inference.reason.isEmpty)
            if activity.inference.category == .unknown {
                XCTAssertEqual(activity.inference.label, "Unknown")
            }
        }
    }

    func testClosePreviewRejectsAmbiguousAndProtectedProcesses() throws {
        let safe = fixtureActivity(pid: 42, path: "/opt/local/bin/node")
        let peer = fixtureActivity(pid: 43, path: "/opt/local/bin/node")
        let uid = Int32(getuid())
        let startTime: (Int32) -> String? = { _ in "start one" }
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe, peer], port: 3000,
            pid: nil, currentUID: uid, currentPID: 99, startTime: startTime))
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: 0, currentPID: 99, startTime: startTime))
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: uid, currentPID: 42, startTime: startTime))
        for activity in [
            fixtureActivity(pid: 42, path: nil),
            fixtureActivity(pid: 42, path: "/usr/bin/node"),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", uid: uid + 1),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true),
        ] {
            XCTAssertThrowsError(try CloseService.makePlan(activities: [activity], port: 3000,
                pid: nil, currentUID: uid, currentPID: 99, startTime: startTime))
        }
        XCTAssertThrowsError(try CloseService.makePlan(activities: [safe], port: 3000,
            pid: nil, currentUID: uid, currentPID: 99, startTime: { _ in nil }))
    }

    func testClosePreviewReportsOtherPortsForSamePID() throws {
        let uid = Int32(getuid())
        let plan = try CloseService.makePlan(activities: [
            fixtureActivity(pid: 42, path: "/opt/local/bin/node"),
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", port: 3001),
        ], port: 3000, pid: nil, currentUID: uid, currentPID: 99,
        startTime: { _ in "start one" })
        XCTAssertEqual(plan.otherPorts, [3001])
        XCTAssertEqual(plan.peerPIDs, [])
    }

    func testUIExplainsWhyKnownProtectedTargetsCannotClose() {
        XCTAssertNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/opt/local/bin/node")))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/usr/bin/node")))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: "/opt/local/bin/node", appBundle: true)))
        XCTAssertNotNil(CloseService.protectionReason(for:
            fixtureActivity(pid: 42, path: nil)))
    }

    func testKeepAliveServicesAreRefusedWithAStopCommand() {
        var brew = fixtureActivity(pid: 42, path: "/opt/homebrew/opt/syncthing/bin/syncthing")
        brew.launchdJob = LaunchdJob(label: "homebrew.mxcl.syncthing", pid: 41, keepAlive: true)
        XCTAssertTrue(CloseService.protectionReason(for: brew)?.contains("brew services stop syncthing") == true)

        var agent = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/node")
        agent.launchdJob = LaunchdJob(label: "com.example.gateway", pid: 42, keepAlive: true)
        XCTAssertTrue(CloseService.protectionReason(for: agent)?
            .contains("launchctl bootout gui/\(getuid())/com.example.gateway") == true)

        // Without KeepAlive a SIGTERM sticks until the next login, so it stays closable.
        var oneShot = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/node")
        oneShot.launchdJob = LaunchdJob(label: "com.example.once", pid: 42, keepAlive: false)
        XCTAssertNil(CloseService.protectionReason(for: oneShot))
    }

    func testPortCategoryFollowsWhoStartedTheProcess() {
        let uid = Int32(getuid())
        func category(path: String = "/opt/homebrew/bin/node", ppid: Int32? = 500, parents: [String] = [],
                      appBundle: Bool = false, project: Bool = false, launchd: Bool = false,
                      owner: Int32 = Int32(getuid())) -> PortCategory {
            let base = fixtureActivity(pid: 42, path: path, uid: owner, appBundle: appBundle)
            let process = ProcessFact(pid: 42, ppid: ppid, command: "node", executablePath: path,
                uid: owner, user: nil, cwd: base.process.cwd)
            let chain = parents.enumerated().map { index, name in
                ProcessFact(pid: Int32(100 + index), ppid: nil, command: name, executablePath: nil, uid: uid, user: nil, cwd: nil)
            }
            var activity = Activity(listener: base.listener, process: process, parentChain: chain,
                projectMarker: project ? ProjectMarker(name: "site", root: "/p", source: ".git", markerPath: "/p/.git") : nil,
                applicationBundle: base.applicationBundle, scope: .local, inference: base.inference)
            if launchd { activity.launchdJob = LaunchdJob(label: "homebrew.mxcl.postgresql", pid: 42, keepAlive: true) }
            return PortCategory.classify([activity])
        }

        XCTAssertEqual(category(project: true), .devServer)
        XCTAssertEqual(category(parents: ["-zsh", "login"]), .devServer)
        XCTAssertEqual(category(parents: ["npm", "bash", "tmux"]), .devServer)
        XCTAssertEqual(category(ppid: 1), .devServer, "orphaned after its terminal closed")
        XCTAssertEqual(category(ppid: 1, launchd: true), .background)
        XCTAssertEqual(category(parents: ["zsh"], launchd: true), .background)
        XCTAssertEqual(category(parents: ["zsh"], appBundle: true), .app)
        XCTAssertEqual(category(appBundle: true, project: true), .app, "an editor's own server follows the editor")
        XCTAssertEqual(category(path: "/usr/libexec/rapportd", ppid: 1), .system)
        XCTAssertEqual(category(ppid: 1, owner: uid + 1), .system)
        XCTAssertEqual(category(parents: ["some-daemon"]), .other)
    }

    func testCoreTextFollowsTheSelectedLanguage() {
        defer { Localization.current = .english }
        XCTAssertEqual(PortCategory.devServer.title, "Dev Servers")

        Localization.current = .chinese
        XCTAssertEqual(PortCategory.devServer.title, "开发服务器")
        var service = fixtureActivity(pid: 42, path: "/opt/homebrew/bin/syncthing")
        service.launchdJob = LaunchdJob(label: "homebrew.mxcl.syncthing", pid: 42, keepAlive: true)
        XCTAssertEqual(CloseService.protectionReason(for: service),
                       "launchd 会让 homebrew.mxcl.syncthing 保持运行，关闭后会立即重启。请用 `brew services stop syncthing` 停止它。")
        // Callers branch on the flag, not on the wording, so the outcome is the same in any language.
        XCTAssertTrue(CloseError("已发送", signalSent: true).signalSent)
        XCTAssertFalse(CloseError("已拒绝").signalSent)
    }

    func testReleaseVersionComparesNumbersNotText() {
        func v(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }
        XCTAssertGreaterThan(v("v0.3.6"), v("0.3.5"))
        XCTAssertGreaterThan(v("0.10.0"), v("0.9.9"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertFalse(v("0.3.5") > v("v0.3.5"))
        XCTAssertEqual(v("v0.3.5").description, "0.3.5")
        XCTAssertNil(ReleaseVersion("1.0.0-beta"))
        XCTAssertNil(ReleaseVersion(""))
    }

    func testLaunchctlParsing() {
        let list = "PID\tStatus\tLabel\n34135\t0\thomebrew.mxcl.syncthing\n-\t0\tcom.apple.idle\n8490\t0\tapplication.com.google.Chrome.1.2\n"
        XCTAssertEqual(Scanner.parseLaunchctlList(list),
                       [34135: "homebrew.mxcl.syncthing", 8490: "application.com.google.Chrome.1.2"])

        let keepAlive = "gui/501/x = {\n\tstate = running\n\tproperties = partial import | keepalive | runatload\n}"
        let nestedOnly = "gui/501/x = {\n\tendpoints = {\n\t\tproperties = keepalive\n\t}\n\tproperties = runatload | inferred program\n}"
        XCTAssertTrue(Scanner.launchctlPrintHasKeepAlive(keepAlive))
        XCTAssertFalse(Scanner.launchctlPrintHasKeepAlive(nestedOnly))
    }

    func testNodePackageLocatorSkipsIndirectionAndPrefersInnermostPackage() {
        let global = NodePackageLocator.locate(inArguments: "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway --port 18789")
        XCTAssertEqual(global?.name, "openclaw")
        XCTAssertEqual(global?.directory, "/opt/homebrew/lib/node_modules/openclaw")

        let scoped = NodePackageLocator.locate(inPath: "/x/node_modules/@scope/tool/bin/cli.js", resolvingSymlinks: false)
        XCTAssertEqual(scoped?.name, "@scope/tool")
        XCTAssertEqual(scoped?.directory, "/x/node_modules/@scope/tool")

        let pnpm = NodePackageLocator.locate(inPath: "/p/node_modules/.pnpm/vite@5.0.0/node_modules/vite/bin/vite.js", resolvingSymlinks: false)
        XCTAssertEqual(pnpm?.name, "vite")
        XCTAssertEqual(pnpm?.directory, "/p/node_modules/.pnpm/vite@5.0.0/node_modules/vite")

        XCTAssertNil(NodePackageLocator.locate(inPath: "/p/node_modules/.bin/next", resolvingSymlinks: false))
        XCTAssertNil(NodePackageLocator.locate(inArguments: "node server.js --port 3000"))
    }

    func testUptimeFormatterFormatsVariousDurations() {
        XCTAssertEqual(UptimeFormatter.format(etime: "00:15"), "< 1m")
        XCTAssertEqual(UptimeFormatter.format(etime: "00:15", compact: true), "< 1m")

        XCTAssertEqual(UptimeFormatter.format(etime: "05:30"), "5m")
        XCTAssertEqual(UptimeFormatter.format(etime: "05:30", compact: true), "5m")

        XCTAssertEqual(UptimeFormatter.format(etime: "01:15:20"), "1h 15m")
        XCTAssertEqual(UptimeFormatter.format(etime: "01:15:20", compact: true), "1h")

        XCTAssertEqual(UptimeFormatter.format(etime: "02:00:10"), "2h")
        XCTAssertEqual(UptimeFormatter.format(etime: "02:00:10", compact: true), "2h")

        XCTAssertEqual(UptimeFormatter.format(etime: "01-04:20:00"), "1d 4h")
        XCTAssertEqual(UptimeFormatter.format(etime: "01-04:20:00", compact: true), "1d")

        XCTAssertEqual(UptimeFormatter.format(etime: "02-00:10:00"), "2d")
        XCTAssertEqual(UptimeFormatter.format(etime: "02-00:10:00", compact: true), "2d")

        XCTAssertNil(UptimeFormatter.format(etime: ""))
        XCTAssertNil(UptimeFormatter.format(etime: "invalid"))
    }

    func testParseProcessTableWithAndWithoutEtime() {
        let withEtime = """
            1     0 01-16:20:00 /sbin/launchd
          500   200 02:15:30 /opt/local/bin/node
          600   500 00:30 python
        """
        let table = Scanner.parseProcessTable(withEtime)
        XCTAssertEqual(table[1]?.uptime, "1d 16h")
        XCTAssertEqual(table[1]?.compactUptime, "1d")
        XCTAssertEqual(table[1]?.rawElapsedTime, "01-16:20:00")
        XCTAssertEqual(table[500]?.uptime, "2h 15m")
        XCTAssertEqual(table[500]?.compactUptime, "2h")
        XCTAssertEqual(table[600]?.uptime, "< 1m")

        let legacyWithoutEtime = """
            1     0 /sbin/launchd
          500   200 /opt/local/bin/node
        """
        let legacyTable = Scanner.parseProcessTable(legacyWithoutEtime)
        XCTAssertEqual(legacyTable[1]?.command, "launchd")
        XCTAssertNil(legacyTable[1]?.uptime)
        XCTAssertEqual(legacyTable[500]?.command, "node")
    }

    func testParseProcessTableWithRssAndMemoryUsage() {
        let withRss = """
            1     0 01-16:20:00 12500 /sbin/launchd
          500   200 02:15:30 45000 /opt/local/bin/node
          600   500 00:30 1500000 python
        """
        let table = Scanner.parseProcessTable(withRss)
        XCTAssertEqual(table[1]?.uptime, "1d 16h")
        XCTAssertEqual(table[1]?.rssKB, 12500)
        XCTAssertEqual(table[1]?.memoryUsage, "12.2 MB")
        XCTAssertEqual(table[500]?.uptime, "2h 15m")
        XCTAssertEqual(table[500]?.rssKB, 45000)
        XCTAssertEqual(table[500]?.memoryUsage, "43.9 MB")
        XCTAssertEqual(table[600]?.rssKB, 1500000)
        XCTAssertEqual(table[600]?.memoryUsage, "1.4 GB")
    }

    func testBatchClosePlanPreparation() throws {
        // Batch preparation verifies start times with ps, so its fixture PIDs must be alive.
        let processes = [Process(), Process()]
        defer {
            for process in processes where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        for process in processes {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            try process.run()
        }

        let uid = Int32(getuid())
        let act1 = fixtureActivity(pid: processes[0].processIdentifier, path: "/opt/local/bin/node", port: 3000, uid: uid)
        let act2 = fixtureActivity(pid: processes[1].processIdentifier, path: "/opt/local/bin/python", port: 8000, uid: uid)
        let protectedAct = fixtureActivity(pid: 103, path: "/usr/bin/python", port: 9000, uid: uid)

        let plans = try CloseService.prepareBatch(activities: [act1, act2, protectedAct])
        // protectedAct should be skipped
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(Set(plans.map(\.pid)), Set(processes.map(\.processIdentifier)))
    }

    func testCommandRunnerReturnsOutput() throws {
        XCTAssertEqual(try CommandRunner.output("/bin/echo", ["hello"]), "hello\n")
    }

    func testCommandRunnerStopsHungCommandAtDeadline() {
        let started = Date()
        XCTAssertThrowsError(try CommandRunner.output("/bin/sleep", ["30"], timeout: 0.3)) { error in
            guard case ScanError.timedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCommandRunnerStopsRunawayOutput() {
        XCTAssertThrowsError(try CommandRunner.output("/usr/bin/yes", [], maxOutputBytes: 64 * 1024)) { error in
            guard case ScanError.outputTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func fixtureActivity(pid: Int32, path: String?, port: Int = 3000,
                                 uid: Int32? = Int32(getuid()), appBundle: Bool = false) -> Activity {
        let listener = Listener(pid: pid, command: "node", uid: uid, user: nil,
            port: port, addresses: ["127.0.0.1"])
        let process = ProcessFact(pid: pid, ppid: nil, command: "node", executablePath: path,
            uid: uid, user: nil, cwd: "/private/tmp/project")
        let inference = OwnerInference(label: "Unknown", category: .unknown, confidence: "none",
            reason: "No evidence.")
        let bundle = appBundle ? ApplicationBundle(name: "Test", path: "/Applications/Test.app",
            sourcePID: pid, direct: true) : nil
        return Activity(listener: listener, process: process, parentChain: [], projectMarker: nil,
            applicationBundle: bundle, scope: .local, inference: inference)
    }
}

private final class HeadOnlyHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        guard request.httpMethod == "HEAD",
              let response = HTTPURLResponse(url: url, statusCode: 404,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class NonHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: URLResponse(url: url, mimeType: nil,
            expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class UntrustedHTTPSProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.serverCertificateUntrusted))
        } else if let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}

private final class RedirectHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.scheme == "https" {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: url.host == "127.0.0.1" ? 302 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { }
}
