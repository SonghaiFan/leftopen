// Standalone UI fixture: no MenuModel, real service, authorization or general clipboard access.
import AppKit
import LeftOpenCore
import SwiftUI

func L(_ english: String, _ chinese: String) -> String { chinese }

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let pasteboard = NSPasteboard.withUniqueName()
let report = FailureDiagnostics(stage: "address.install", code: "serviceStopFailed", tool: "osascript", exitCode: 1,
    output: "LEFTOPEN_DIAGNOSTIC:{\"stage\":\"launchd.bootout\",\"exitCode\":5}", version: "0.5.4", build: "1011.2")
let view = Form {
    Section("项目地址 · 隔离测试") {
        LabeledContent("固定地址") { Button("修复…") {}.disabled(true) }
        Text("未能停止 LeftOpen 的旧地址服务，请重试设置。")
            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        ErrorDiagnosticsView(report: report, pasteboard: pasteboard)
    }
}.formStyle(.grouped).controlSize(.small).frame(width: 380, height: 400)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 380, height: 400),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "LeftOpen Diagnostics UI Test"
window.contentView = NSHostingView(rootView: view)
window.center()
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)
var verified = false
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    MainActor.assumeIsolated {
        if !verified, pasteboard.string(forType: .string) != nil {
            precondition(pasteboard.string(forType: .string) == report.text, "Clipboard differs from displayed diagnostic")
            verified = true
            print("PASS: clicked Copy wrote the exact safe diagnostic to the isolated clipboard")
            fflush(stdout)
        }
        if !window.isVisible {
            pasteboard.releaseGlobally()
            application.terminate(nil)
        }
    }
}
application.run()
