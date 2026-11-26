import Darwin
import XCTest
@testable import LeftOpenCore

final class AutomationBrowserTests: XCTestCase {
    private let executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private let temporaryDirectory = URL(fileURLWithPath: "/private/tmp/automation-fixture")
    private var argv: [String] {
        [executable, "--no-startup-window", "--remote-debugging-pipe",
         "--user-data-dir=/private/tmp/automation-fixture/playwright_chromiumdev_profile-test"]
    }

    func testRecognizesOnlyDedicatedChromeMainProcess() {
        XCTAssertNotNil(AutomationBrowserScanner.profile(executable: executable, arguments: argv, temporaryDirectory: temporaryDirectory))
        let invalid: [[String]] = [
            [executable], Array(argv.dropLast()), Array(argv.dropFirst()),
            argv.filter { $0 != "--no-startup-window" }, argv.filter { $0 != "--remote-debugging-pipe" },
            argv + ["--type=renderer"], argv + ["--user-data-dir=/Users/example/Library/Application Support/Google/Chrome"],
            argv + ["--user-data-dir", "/private/tmp/profile"],
            [executable, "--no-startup-window --remote-debugging-pipe", argv.last!],
            Array(argv.dropLast()) + ["--user-data-dir=/Users/example/playwright_chromiumdev_profile-test"],
            Array(argv.dropLast()) + ["--user-data-dir=/private/tmp/automation-fixture/normal-profile"],
            Array(argv.dropLast()) + ["--user-data-dir=/private/tmp/automation-fixture/playwright_chromiumdev_profile-"],
        ]
        for arguments in invalid {
            XCTAssertNil(AutomationBrowserScanner.profile(executable: executable, arguments: arguments, temporaryDirectory: temporaryDirectory))
        }
        for path in ["/tmp/Google Chrome", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper", "/bin/sh"] {
            XCTAssertNil(AutomationBrowserScanner.profile(executable: path, arguments: argv, temporaryDirectory: temporaryDirectory))
        }
    }

    func testProfileSymlinkCannotPointAtNormalProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = directory.appendingPathComponent("playwright_chromiumdev_profile-test")
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: URL(fileURLWithPath: NSHomeDirectory()))
        let arguments = Array(argv.dropLast()) + ["--user-data-dir=" + profile.path]
        XCTAssertNil(AutomationBrowserScanner.profile(executable: executable, arguments: arguments, temporaryDirectory: directory))
    }

    private func browser(pid: Int32 = 424242, uid: Int32 = Int32(getuid()), start: String = "100:1", profile: String = "/tmp/profile", path: String? = nil) -> AutomationBrowser {
        AutomationBrowser(process: ProcessFact(pid: pid, ppid: 1, command: "Google Chrome", executablePath: path ?? executable,
            uid: uid, user: nil, cwd: nil), profilePath: profile, startTime: start, startedAt: Date(timeIntervalSince1970: 100))
    }

    func testChangedOrMissingIdentityNeverSignals() throws {
        let original = browser()
        let plan = try CloseService.makeBrowserPlan(original)
        for fresh in [nil, browser(start: "101:1"), browser(uid: Int32(getuid()) + 1), browser(profile: "/tmp/other"), browser(path: "/bin/sh"), browser(pid: 424243)] {
            XCTAssertThrowsError(try CloseService.performBrowser(plan, signal: SIGTERM, read: { _ in fresh },
                running: { _ in XCTFail("No outcome check before a signal"); return false },
                send: { _, _ in XCTFail("Must not signal a changed process"); return 0 }, wait: {}))
        }
        XCTAssertThrowsError(try CloseService.makeBrowserPlan(browser(uid: 0)))
        XCTAssertThrowsError(try CloseService.makeBrowserPlan(browser(pid: getpid())))
    }

    func testGentleThenExplicitForceUsesSameIdentityAndExpiry() throws {
        let original = browser()
        let plan = try CloseService.makeBrowserPlan(original)
        var signals: [Int32] = []
        let send: (Int32, Int32) -> Int32 = { pid, signal in
            XCTAssertEqual(pid, original.process.pid)
            signals.append(signal)
            return 0
        }
        XCTAssertThrowsError(try CloseService.performBrowser(plan, signal: SIGKILL, read: { _ in original }, send: send, wait: {}))
        XCTAssertTrue(signals.isEmpty)
        let result = try CloseService.performBrowser(plan, signal: SIGTERM, read: { _ in original }, running: { _ in true }, send: send, wait: {})
        XCTAssertEqual(result.targetExited, false)
        XCTAssertFalse(result.portFree)
        XCTAssertFalse(result.targetStoppedListening)
        XCTAssertEqual(signals, [SIGTERM])
        let offer = try XCTUnwrap(result.forceCloseOffer)
        XCTAssertThrowsError(try CloseService.verifyOfferAge(offer, now: Date().addingTimeInterval(121)))
        XCTAssertThrowsError(try CloseService.performBrowser(plan, signal: SIGKILL, offer: offer, read: { _ in self.browser(start: "reused") }, send: send, wait: {}))
        XCTAssertEqual(signals, [SIGTERM])
        let forced = try CloseService.performBrowser(plan, signal: SIGKILL, offer: offer, read: { _ in original }, running: { _ in false }, send: send, wait: {})
        XCTAssertEqual(forced.targetExited, true)
        XCTAssertNil(forced.forceCloseOffer)
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
    }

    func testExitAndUnknownOutcomeDoNotOfferForce() throws {
        let original = browser()
        let plan = try CloseService.makeBrowserPlan(original)
        let exited = try CloseService.performBrowser(plan, signal: SIGTERM, read: { _ in original }, running: { _ in false }, send: { _, _ in 0 }, wait: {})
        XCTAssertEqual(exited.targetExited, true)
        XCTAssertNil(exited.forceCloseOffer)
        XCTAssertThrowsError(try CloseService.performBrowser(plan, signal: SIGTERM, read: { _ in original },
            running: { _ in throw CloseError("unavailable") }, send: { _, _ in 0 }, wait: {})) {
                XCTAssertTrue(($0 as? CloseError)?.signalSent == true)
            }
        XCTAssertThrowsError(try CloseService.performBrowser(plan, signal: SIGTERM, read: { _ in original },
            running: { _ in XCTFail("No polling after failed signal"); return false }, send: { _, _ in -1 }, wait: {}))
    }

    func testKernelArgvReaderAndExitObservationOnOwnedChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let (path, arguments) = try AutomationBrowserScanner.arguments(child.processIdentifier)
        XCTAssertEqual(path, "/bin/sleep")
        XCTAssertEqual(arguments.last, "20")
        XCTAssertNil(try AutomationBrowserScanner.read(child.processIdentifier))
        let info = try XCTUnwrap(AutomationBrowserScanner.identity(child.processIdentifier))
        let owned = browser(pid: child.processIdentifier, start: AutomationBrowserScanner.start(info))
        XCTAssertTrue(try AutomationBrowserScanner.isRunning(owned))
        child.terminate()
        child.waitUntilExit()
        XCTAssertFalse(try AutomationBrowserScanner.isRunning(owned))
    }
    func testLiveDedicatedChromeClosesWithoutTouchingControlSession() throws {
        guard ProcessInfo.processInfo.environment["LEFTOPEN_TEST_CHROME"] == "1" else {
            throw XCTSkip("Set LEFTOPEN_TEST_CHROME=1 for the isolated local Chrome integration check.")
        }
        let node = ProcessInfo.processInfo.environment["LEFTOPEN_TEST_NODE"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: node), FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("Chrome and Node are required for the opt-in fixture.")
        }
        let root = FileManager.default.temporaryDirectory
        let profile = root.appendingPathComponent("playwright_chromiumdev_profile-" + UUID().uuidString)
        let controlProfile = root.appendingPathComponent("leftopen-control-" + UUID().uuidString)
        func launch(_ profile: URL) throws -> (Process, Int32) {
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: node)
            launcher.arguments = ["-e", """
                const {spawn}=require('node:child_process');
                const c=spawn(process.argv[1], ['--headless=new','--no-startup-window','--remote-debugging-pipe','--no-first-run','--no-default-browser-check','--user-data-dir='+process.argv[2]], {stdio:['ignore','ignore','ignore','pipe','pipe']});
                c.on('spawn',()=>process.stdout.write(c.pid+'\\n'));
                c.on('exit',()=>process.exit(0));
                process.on('SIGTERM',()=>c.kill('SIGTERM'));
                """, executable, profile.path]
            let output = Pipe()
            launcher.standardOutput = output
            try launcher.run()
            let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            return (launcher, try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))))
        }
        let (automation, pid) = try launch(profile)
        defer {
            if automation.isRunning { automation.terminate() }
            automation.waitUntilExit()
            try? FileManager.default.removeItem(at: profile)
        }
        let (control, controlPID) = try launch(controlProfile)
        defer {
            if control.isRunning { control.terminate() }
            control.waitUntilExit()
            try? FileManager.default.removeItem(at: controlProfile)
        }
        Thread.sleep(forTimeInterval: 1)
        let browser = try XCTUnwrap(AutomationBrowserScanner.read(pid))
        XCTAssertNil(try AutomationBrowserScanner.read(controlPID))
        let snapshot = try Scanner.scan()
        XCTAssertTrue(snapshot.automationBrowsers.contains { $0.id == browser.id })
        XCTAssertFalse(snapshot.automationBrowsers.contains { $0.process.pid == controlPID })
        // Both sessions use pipes; no TCP listener is needed for discovery or close.
        XCTAssertFalse(snapshot.activities.contains { $0.process.pid == pid })
        let result = try CloseService.execute(CloseService.prepare(browser: browser))
        XCTAssertEqual(result.targetExited, true)
        XCTAssertNil(result.forceCloseOffer)
        XCTAssertNotNil(try AutomationBrowserScanner.identity(controlPID))
        XCTAssertTrue(control.isRunning)
    }
}
