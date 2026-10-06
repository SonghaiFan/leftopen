import AppKit
import LeftOpenCore
import SwiftUI

struct PortlessProjectView: View {
    let project: ProjectMarker?
    let urls: [URL]
    let readError: String?
    let otherHostnames: Set<String>
    @AppStorage("leftopen.portlessStateDirectory") private var directory = "~/.portless"
    @State private var name = ""
    @State private var command = "npm run dev"
    @State private var message: String?

    private var aliases: [String: String] {
        UserDefaults.standard.dictionary(forKey: "leftopen.portlessAliases") as? [String: String] ?? [:]
    }

    private var conflict: Bool {
        aliases.contains { $0.key != project?.root && $0.value == name }
            || otherHostnames.contains("\(name).localhost")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Fixed project address · Portless", "固定项目地址 · Portless"))
                .font(.callout.weight(.semibold))
            ForEach(urls, id: \.absoluteString) { url in
                Text(url.absoluteString).font(.caption).textSelection(.enabled)
                HStack {
                    Button(L("Open", "打开")) { NSWorkspace.shared.open(url) }
                    Button(L("Copy URL", "复制网址")) { copy(url.absoluteString) }
                }
            }
            if urls.isEmpty {
                Text(L("No matching active Portless route.", "未发现匹配的运行中 Portless 路由。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let project {
                TextField(L("Project alias (e.g. myapp)", "项目别名（如 myapp）"), text: $name)
                TextField(L("Start command", "启动命令"), text: $command)
                HStack {
                    Button(L("Save alias", "保存别名")) {
                        var saved = aliases
                        saved[project.root] = name
                        UserDefaults.standard.set(saved, forKey: "leftopen.portlessAliases")
                        message = L("Alias saved for this project.", "已保存此项目的别名。")
                    }
                    Button(L("Copy start command", "复制启动命令")) {
                        if let value = Portless.launchCommand(name: name, projectRoot: project.root, command: command) {
                            copy(value)
                        }
                    }
                }
                .disabled(!Portless.validName(name) || conflict || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !Portless.validName(name) || conflict {
                    Text(conflict ? L("Alias is already used by another project or route.", "此别名已被其他项目或路由使用。")
                         : L("Use lowercase letters, numbers, hyphens or dotted names.", "请使用小写字母、数字、连字符或点分隔的名称。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Saving an alias does not create a route. Install Portless, then run the copied command in Terminal. HTTPS depends on your proxy configuration.",
                       "保存别名后，请先安装 Portless，再在终端运行复制的命令。HTTPS 取决于你的代理配置。"))
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption) }
            }
            DisclosureGroup(L("Portless setup", "Portless 设置")) {
                TextField(L("State directory", "状态目录"), text: $directory)
                Button(L("Copy install command", "复制安装命令")) { copy("npm install -g portless") }
                Button(L("Portless documentation", "Portless 文档")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/vercel-labs/portless")!)
                }
                if let readError {
                    Text(readError).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
        .task(id: project?.root) {
            if let project { name = aliases[project.root] ?? Portless.suggestedName(project.name) }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
