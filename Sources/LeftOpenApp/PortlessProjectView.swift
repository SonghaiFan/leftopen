import AppKit
import LeftOpenCore
import SwiftUI

struct PortlessProjectView: View {
    let activity: Activity
    let webURL: URL?
    let urls: [URL]
    let readError: String?
    @ObservedObject private var fixed = FixedAddressManager.shared
    @State private var name = ""

    private var binding: FixedAddressBinding? { fixed.binding(for: activity) }
    private var managedURL: URL? { binding.flatMap { fixed.urls[$0.id] } }
    private var blocker: FixedAddressEligibility.Blocker? {
        FixedAddressEligibility.blocker(for: activity, webURL: webURL, currentUID: Int32(getuid()))
    }
    private var eligible: Bool { blocker == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Fixed address", "固定地址")).font(AppAppearance.sectionTitle)
            if let url = managedURL {
                Text(url.absoluteString).font(AppAppearance.secondary).textSelection(.enabled)
                HStack {
                    Button(L("Open", "打开")) { NSWorkspace.shared.open(url) }
                    Button(L("Copy", "复制")) { copy(url.absoluteString) }
                    Button(L("Disable", "停用")) { Task { await fixed.disable(activity) } }
                }
                Text(L("Follows this project's service when its port changes. Keep LeftOpen running.",
                       "端口变化时自动跟随此项目的服务，保持 LeftOpen 运行即可。"))
                    .font(AppAppearance.secondary).foregroundStyle(.secondary)
            } else if binding != nil {
                Text(L("Enabled · reconnecting", "已启用 · 正在连接"))
                    .font(AppAppearance.secondary).foregroundStyle(.secondary)
                HStack {
                    if fixed.addressesReady {
                        Button(L("Retry", "重试")) { enable() }
                    } else {
                        Button(L("Set up in Settings", "前往设置")) { SettingsWindowController.shared.show(section: .projects) }
                    }
                    Button(L("Disable", "停用")) { Task { await fixed.disable(activity) } }
                }
            } else {
                Button {
                    if fixed.addressesReady { enable() } else { SettingsWindowController.shared.show(section: .projects) }
                } label: {
                    Label(fixed.addressesReady ? L("Enable fixed address", "启用固定地址")
                          : L("Set up in Settings", "前往设置"), systemImage: "link")
                }
                .disabled(!eligible)
                Text(eligible
                     ? (fixed.addressesReady
                        ? L("Ready to use. No separate installation needed.", "已就绪，无需另行安装。")
                        : L("Complete local address setup once in Settings.", "在设置中集中完成首次本地地址授权。"))
                     : (blocker?.message ?? ""))
                    .font(AppAppearance.secondary).foregroundStyle(.secondary)
            }
            if fixed.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Setting up…", "正在设置…")).font(AppAppearance.secondary)
                }
            }
            if let error = fixed.error { Text(error).font(AppAppearance.secondary).foregroundStyle(.orange).textSelection(.enabled) }
            DisclosureGroup(L("Address options", "地址选项")) {
                TextField(L("Name (automatic when empty)", "名称（留空自动命名）"), text: $name)
                if binding != nil {
                    Button(L("Apply name", "应用名称")) { enable() }
                        .disabled(!eligible || (!name.isEmpty && !Portless.validName(name)))
                }
                if binding != nil && !fixed.usesHTTPS {
                    Button(L("Set up HTTPS in Settings", "在设置中启用 HTTPS")) { SettingsWindowController.shared.show(section: .projects) }
                    Text(L("Local address authorization is managed in Settings.", "本地地址授权统一在设置中管理。"))
                        .font(AppAppearance.secondary).foregroundStyle(.secondary)
                }
                if !urls.isEmpty {
                    Text(L("Existing Portless addresses", "已有的 Portless 地址")).font(.caption.weight(.semibold))
                    ForEach(urls, id: \.absoluteString) { url in
                        HStack {
                            Text(url.absoluteString).font(AppAppearance.secondary).textSelection(.enabled)
                            Button(L("Open", "打开")) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if let readError { Text(readError).font(AppAppearance.secondary).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(fixed.isWorking)
        .task(id: activity.projectMarker?.root) { name = binding?.name ?? "" }
    }

    private func enable() { Task { await fixed.enable(activity, name: name) } }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
