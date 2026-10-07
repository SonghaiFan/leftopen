import AppKit
import LeftOpenCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var fixed = FixedAddressManager.shared
    @ObservedObject private var navigation = SettingsWindowController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCopy = false
    @State private var doorOpen = true
    @State private var volumePreviewTask: Task<Void, Never>?
    @State private var previewSoundToggle = false

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return L("Development build", "开发版本") }
        let build = info?["CFBundleVersion"] as? String
        return build.map { L("Version \(short) (\($0))", "版本 \(short)（\($0)）") } ?? L("Version \(short)", "版本 \(short)")
    }

    var body: some View {
        Form {
            switch navigation.section {
            case .general:
                generalSettings
                monitoringSettings
            case .projects:
                addressSettings
            case .behavior:
                closingSettings
                soundSettings
            case .about:
                updateSettings
                aboutSettings
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppAppearance.surface)
        .controlSize(.small)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .task { await fixed.refreshAddressSetup() }
        .onChange(of: navigation.section) {
            volumePreviewTask?.cancel()
            if navigation.section == .projects { Task { await fixed.refreshAddressSetup() } }
        }
        .onDisappear { volumePreviewTask?.cancel() }
    }

    private var generalSettings: some View {
        Section {
            Picker(L("Language", "语言"), selection: $settings.language) {
                ForEach(LanguagePreference.allCases) { Text($0.title).tag($0) }
            }
            Toggle(L("Open at login", "登录时打开"), isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { _ in launchAtLogin.toggle() }
            ))
        } header: {
            Text(L("General", "通用"))
        }
    }

    private var monitoringSettings: some View {
        Section {
            Picker(L("Refresh", "刷新"), selection: $settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
            }
            Picker(L("Menu bar count", "菜单栏数字"), selection: $settings.menuBarBadgeMode) {
                ForEach(MenuBarBadgeMode.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            sectionHeader(L("Port Monitoring", "端口监控"),
                help: L("How often LeftOpen scans and what the menu bar shows.", "设置 LeftOpen 的扫描频率和菜单栏显示内容。"))
        }
    }

    private var closingSettings: some View {
        Section {
            Toggle(L("Protect apps and system services", "保护 App 和系统服务"),
                   isOn: $settings.safetyProtectionEnabled.animation(motion))
        } header: {
            sectionHeader(L("Closing Safety", "关闭安全保护"), help: settings.safetyProtectionEnabled
                ? L("Prevents closing app-owned, macOS, and automatically restarted service ports. Project servers remain closable.",
                    "阻止关闭属于 App、macOS 和会自动重启的服务端口；项目服务器仍可关闭。")
                : L("Protection is off. LeftOpen will let you try to close any port owned by your user. Process identity is still rechecked before SIGTERM.",
                    "保护已关闭。LeftOpen 将允许尝试关闭当前用户的任何端口；发送 SIGTERM 前仍会重新确认进程身份。"))
        }
    }

    private var soundSettings: some View {
        Section {
            Toggle(L("Play sounds when ports change", "端口变化时播放提示音"),
                   isOn: $settings.soundEffectsEnabled)
            if settings.soundEffectsEnabled {
                Slider(value: $settings.soundVolume, in: 0...1) {
                    Text(L("Volume", "音量"))
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .labelsHidden()
                .onChange(of: settings.soundVolume) {
                    volumePreviewTask?.cancel()
                    volumePreviewTask = Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        previewSoundToggle.toggle()
                        (previewSoundToggle ? DoorSound.doorOpen : DoorSound.doorClose).play()
                    }
                }
            }
        } header: {
            Text(L("Sounds", "声音"))
        }
    }

    private var updateSettings: some View {
        Section {
            Toggle(L("Check for updates automatically", "自动检查更新"), isOn: $settings.checkForUpdates)
            updateStatus
                .animation(motion, value: updates.state)
        } header: {
            sectionHeader(L("Updates", "更新"),
                help: L("Asks GitHub for the latest release once a day. Nothing about this Mac is sent.",
                        "每天向 GitHub 查询一次最新版本，不会发送这台 Mac 的任何信息。"))
        }
    }

    private var aboutSettings: some View {
        Section {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    DoorMark(isOpen: doorOpen)
                        .frame(width: 20, height: 33)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let wasOpen = doorOpen
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { doorOpen.toggle() }
                            if wasOpen { DoorSound.doorClose.play() } else { DoorSound.doorOpen.play() }
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LeftOpen")
                            .font(.headline)
                        Text(version)
                            .font(AppAppearance.secondary)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    footerLink(systemImage: "globe", url: "https://leftopen.songhai.site/",
                               label: L("Website", "官网"))
                    githubLink
                }
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text(L("Gently close the doors left ajar.", "轻轻关上那些虚掩的门。"))
                        .font(AppAppearance.secondary)
                        .italic()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    signature
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var addressSettings: some View {
        Section {
            LabeledContent(L("Fixed addresses", "固定地址")) {
                if fixed.isWorking {
                    ProgressView().controlSize(.small)
                } else if fixed.addressesReady {
                    Label(L("Ready", "已就绪"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else if fixed.addressSetupState == .checking {
                    Text(L("Checking…", "正在检查…")).foregroundStyle(.secondary)
                } else {
                    Button(fixed.addressSetupState == .needsRepair
                           ? L("Repair…", "修复…") : L("Set Up…", "设置…")) {
                        Task { await fixed.configureAddresses() }
                    }
                }
            }
            Toggle(L("Show projects in the panel", "在面板中显示项目"), isOn: $settings.showProjectDock)
            if let error = fixed.setupError {
                Text(error).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            sectionHeader(L("Project Addresses", "项目地址"),
                help: L("Stable addresses like https://myapp.localhost that follow a project across ports. Setup asks macOS once to trust a local certificate, run a loopback-only service on port 443, and manage exact hosts entries (“osascript” and “security” may ask separately). Project files are never changed; hiding projects keeps their addresses.",
                        "使用 https://myapp.localhost 这样的固定地址，端口变化后自动跟随。首次设置会向 macOS 请求一次授权：信任本地证书、运行只监听本机的 443 服务、管理精确的 hosts 条目（「osascript」和「security」可能分别弹窗）。不修改项目文件；隐藏项目不会停用地址。"))
        }
    }

    /// A section title that carries its explanation as a hover tooltip instead of standing
    /// footer text, so the form reads at a glance and the detail is there when wanted.
    private func sectionHeader(_ title: String, help: String) -> some View {
        Text(title)
            .help(LocalizedStringKey(help))
            .accessibilityHint(help)
    }

    private func footerLink(systemImage: String, url: String, label: String) -> some View {
        Link(destination: URL(string: url)!) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var githubLink: some View {
        let star = L("Star LeftOpen on GitHub", "在 GitHub 上给 LeftOpen 点个 Star")
        Link(destination: URL(string: "https://github.com/SonghaiFan/leftopen")!) {
            if let url = Bundle.module.url(forResource: "GitHubMark", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(star)
        .accessibilityLabel(star)
    }

    @ViewBuilder
    private var signature: some View {
        if let url = Bundle.module.url(forResource: "FranklinSignature", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .frame(width: 66, height: 20)
                .opacity(0.35)
                .accessibilityLabel(L("Franklin signature", "Franklin 签名"))
        }
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
}
