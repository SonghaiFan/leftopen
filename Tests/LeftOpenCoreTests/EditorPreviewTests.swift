import XCTest
@testable import LeftOpenCore

final class EditorPreviewTests: XCTestCase {
    private let mapped = ["/Users/test/.vscode/extensions/ritwickdey.liveserver-5.7.10/node_modules/fsevents/fsevents.node"]
    private let script = "<!-- Code injected by live-server --> new WebSocket(address); if (msg.data == 'refreshcss') refreshCSS();"

    private func listener(port: Int = 8123) -> Listener {
        Listener(pid: 42, command: "Editor Helper", uid: Int32(getuid()), user: nil,
                 port: port, addresses: ["*"])
    }

    func testDetectsAnyPortOnlyWithBothRuntimeAndResponseEvidence() {
        XCTAssertEqual(EditorPreview.detect(listener(), mappedPaths: mapped, fetch: { _ in self.script }), .liveServer)
        XCTAssertNil(EditorPreview.detect(listener(port: 5500), mappedPaths: mapped, fetch: { _ in "Ordinary HTML" }))
        var calls = 0
        XCTAssertNil(EditorPreview.detect(listener(port: 5500), mappedPaths: [], fetch: { _ in calls += 1; return self.script }))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(EditorPreview.matches("Documentation mentions Code injected by live-server"))
    }

    func testDirectoryListingFindsSameOriginPreviewAndBoundsRequests() {
        var urls: [URL] = []
        let result = EditorPreview.detect(listener(), mappedPaths: mapped) { url in
            urls.append(url)
            if url.path == "/" {
                return "listing directory <a href=\"https://outside.example/page.html\">outside</a><a href=\"one.html\">one</a><a href=\"two.html\">two</a><a href=\"three.html\">three</a>"
            }
            return url.path == "/two.html" ? self.script : "No signature"
        }
        XCTAssertEqual(result, .liveServer)
        XCTAssertEqual(urls.map(\.path), ["/", "/one.html", "/two.html"])
        XCTAssertTrue(urls.allSatisfy { $0.host == "127.0.0.1" && $0.port == 8123 })
    }

    func testLANOnlyListenerIsNotProbed() {
        let remote = Listener(pid: 42, command: "Editor Helper", uid: Int32(getuid()), user: nil,
                              port: 8123, addresses: ["192.168.1.10"])
        XCTAssertNil(EditorPreview.detect(remote, mappedPaths: mapped, fetch: { _ in XCTFail("Must stay on loopback"); return self.script }))
    }

    func testPreviewSeparatesFromHostWithoutInventingProjectOrAllowingClose() {
        let process = ProcessFact(pid: 42, ppid: 99, command: "Editor Helper",
            executablePath: "/Applications/Editor.app/Contents/MacOS/Helper", uid: Int32(getuid()), user: nil, cwd: "/")
        let app = ApplicationBundle(name: "Editor", path: "/Applications/Editor.app", sourcePID: 42, direct: true)
        let inference = OwnerInference(label: "Editor", category: .application, confidence: "high", reason: "App executable")
        var preview = Activity(listener: listener(), process: process, parentChain: [], projectMarker: nil,
                               applicationBundle: app, scope: .lan, inference: inference)
        preview.editorPreview = .liveServer
        let host = Activity(listener: listener(port: 9999), process: process, parentChain: [], projectMarker: nil,
                            applicationBundle: app, scope: .local, inference: inference)
        let categories = PortCategory.byActivity([preview, host])
        XCTAssertEqual(categories[preview.id], .devServer)
        XCTAssertEqual(categories[host.id], .app)
        XCTAssertNotEqual(preview.listenerGroupID, host.listenerGroupID)
        XCTAssertNotNil(CloseService.protectionReason(for: preview))
        XCTAssertNotNil(CloseService.protectionReason(for: host))
        XCTAssertNil(preview.projectMarker)
        XCTAssertEqual(PortCategory.classify([host, preview]), .app)
    }
}
