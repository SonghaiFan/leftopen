import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @State private var newPort = ""
    @State private var didCopy = false
    @State private var doorOpen = true

    private static let brewCommand = "brew install --cask songhaifan/tap/leftopen"

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { _ in launchAtLogin.toggle() }
                ))
                Picker("Refresh", selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                }
                Picker("Menu bar count", selection: $settings.menuBarBadgeMode) {
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
                TextField("Add port", text: $newPort, prompt: Text("e.g. 5432"))
                    .onSubmit(addPort)
            } header: {
                Text("Ignored Ports")
            } footer: {
                footnote("Hidden from the list and counts. Search still finds them.")
            }

            Section {
                HStack {
                    Text(Self.brewCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(didCopy ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.brewCommand, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Command Line")
            } footer: {
                footnote("Then run `leftopen --help` in Terminal.")
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
                    Link("Website", destination: URL(string: "https://songhaifan.github.io/leftopen/")!)
                    Link("GitHub", destination: URL(string: "https://github.com/SonghaiFan/leftopen")!)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .accessibilityLabel("Stop ignoring port \(String(port))")
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
