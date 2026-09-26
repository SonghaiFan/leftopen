import AppKit
import LeftOpenCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var newPort = ""
    @State private var didCopy = false
    @State private var doorOpen = true

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return L("Development build", "开发版本") }
        let build = info?["CFBundleVersion"] as? String
        return build.map { L("Version \(short) (\($0))", "版本 \(short)（\($0)）") } ?? L("Version \(short)", "版本 \(short)")
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Language", "语言"), selection: $settings.language) {
                    ForEach(LanguagePreference.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Open at login", "登录时打开"), isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { _ in launchAtLogin.toggle() }
                ))
                Picker(L("Refresh", "刷新"), selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                }
                Picker(L("Menu bar count", "菜单栏数字"), selection: $settings.menuBarBadgeMode) {
                    ForEach(MenuBarBadgeMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                if !settings.ignoredPorts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(settings.ignoredPorts, id: \.self) { port in
                                portChip(port)
                            }
                        }
                    }
                }
                TextField(L("Add port", "添加端口"), text: $newPort, prompt: Text(L("e.g. 5432", "例如 5432")))
                    .onSubmit(addPort)
            } header: {
                Text(L("Ignored Ports", "忽略的端口"))
            } footer: {
                footnote(L("Hidden from the list and counts. Search still finds them.", "不在列表和计数中显示，搜索时仍能找到。"))
            }

            Section {
                Toggle(L("Check for updates automatically", "自动检查更新"), isOn: $settings.checkForUpdates)
                updateStatus
            } header: {
                Text(L("Updates", "更新"))
            } footer: {
                footnote(L("Asks GitHub for the latest release once a day. Nothing about this Mac is sent.",
                           "每天向 GitHub 查询一次最新版本，不会发送这台 Mac 的任何信息。"))
            }

            Section {
                HStack(spacing: 12) {
                    DoorMark(isOpen: doorOpen)
                        .frame(width: 20, height: 33)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { doorOpen.toggle() }
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LeftOpen").font(.headline)
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link(L("Website", "官网"), destination: URL(string: "https://songhaifan.github.io/leftopen/")!)
                    Link("GitHub", destination: URL(string: "https://github.com/SonghaiFan/leftopen")!)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Parsed as Markdown so `code` spans render.
    private func footnote(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var updateStatus: some View {
        if let current = updates.currentVersion {
            switch updates.state {
            case let .available(release):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(L("LeftOpen \(release.version) is available", "LeftOpen \(release.version) 已发布"),
                              systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Link(L("Release Notes", "更新说明"), destination: release.page)
                    }
                    if updates.installedWithHomebrew {
                        HStack {
                            Text(UpdateChecker.upgradeCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button(didCopy ? L("Copied", "已复制") : L("Copy", "复制")) { copyUpgradeCommand() }
                                .controlSize(.small)
                        }
                    } else {
                        Button(L("Download", "下载")) { NSWorkspace.shared.open(release.page) }
                            .controlSize(.small)
                    }
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Checking…", "正在检查…")).foregroundStyle(.secondary)
                }
            case .upToDate, .idle, .failed:
                HStack {
                    Text(updates.state == .failed
                         ? L("Couldn't reach GitHub.", "无法连接 GitHub。")
                         : updates.state == .upToDate
                         ? L("\(current) is the latest version.", "\(current) 已是最新版本。")
                         : L("Version \(current)", "版本 \(current)"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Check Now", "立即检查")) { Task { await updates.check() } }
                        .controlSize(.small)
                }
            }
        } else {
            Text(L("Development builds don't check for updates.", "开发版本不检查更新。"))
                .foregroundStyle(.secondary)
        }
    }

    private func copyUpgradeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateChecker.upgradeCommand, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func portChip(_ port: Int) -> some View {
        HStack(spacing: 4) {
            Text(String(port))
                .font(.system(.callout, design: .monospaced))
            Button {
                withAnimation(.snappy(duration: 0.2)) { settings.removeIgnoredPort(port) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Stop ignoring port \(String(port))", "不再忽略端口 \(String(port))"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func addPort() {
        let trimmed = newPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else { return }
        withAnimation(.snappy(duration: 0.2)) { settings.addIgnoredPort(port) }
        newPort = ""
    }
}
