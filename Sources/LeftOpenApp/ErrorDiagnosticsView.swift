import AppKit
import LeftOpenCore
import SwiftUI

struct ErrorDiagnosticsView: View {
    let report: FailureDiagnostics
    var pasteboard: NSPasteboard = .general
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup(L("Technical details", "技术详情")) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(report.text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(4)
                }
                .frame(height: 140)
                Button {
                    pasteboard.clearContents()
                    didCopy = pasteboard.setString(report.text, forType: .string)
                } label: {
                    Label(didCopy ? L("Copied", "已复制") : L("Copy diagnostic info", "复制诊断信息"),
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("copyErrorDiagnostics")
                Text(L("Paths and certificate contents are omitted. Review before sharing in an issue.",
                       "已省略路径和证书内容，可检查后粘贴到 issue。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("errorDiagnostics")
        .onChange(of: report) { didCopy = false }
    }
}
