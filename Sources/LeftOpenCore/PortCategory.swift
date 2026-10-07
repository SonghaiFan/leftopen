import Foundation

/// Where a listening process comes from, which is also how it is closed for good. The same program
/// can land in any category: Postgres started in a terminal is a dev server, from `brew services`
/// a background service, inside Docker Desktop an app. So the category rests on who started the
/// process, never on lists of program names or port numbers, and the row name says what it is.
///
/// Verified editor previews are classified per listener; other sockets keep their host category.
public enum PortCategory: String, CaseIterable, Sendable {
    case devServer = "dev-server"
    case background
    case app
    case system
    case other

    public var title: String {
        switch self {
        case .devServer: L("Dev Servers", "开发服务器")
        case .background: L("Background Services", "后台服务")
        case .app: L("Apps", "App")
        case .system: L("System", "系统")
        case .other: L("Other", "其他")
        }
    }

    /// Where these ports come from and how to close them for good.
    public var hint: String {
        switch self {
        case .devServer: L("Started from a project, terminal, editor or agent. Editor-hosted previews are stopped in the editor; other servers close with SIGTERM.",
                           "从项目、终端、编辑器或 agent 启动。编辑器内的预览请在编辑器中停止；其他服务通过 SIGTERM 关闭。")
        case .background: L("Run by launchd (brew services, login items). Stop the service, or launchd may start it again.",
                            "由 launchd 管理（brew services、登录项）。请停止对应服务，否则 launchd 可能会再次启动它。")
        case .app: L("Opened by a running app. Quit the app to free them.", "由正在运行的 App 打开。退出该 App 即可释放。")
        case .system: L("Belong to macOS or another user. Sharing features are turned off in System Settings.",
                        "属于 macOS 或其他用户。共享类功能可在“系统设置”中关闭。")
        case .other: L("Origin unclear. Check the details before closing.", "来历不明。关闭前请先查看详情。")
        }
    }

    /// One category per PID, judged from every port that process listens on.
    public static func byPID(_ activities: [Activity]) -> [Int32: PortCategory] {
        Dictionary(grouping: activities, by: \.process.pid).mapValues(classify)
    }

    public static func byActivity(_ activities: [Activity]) -> [String: PortCategory] {
        let hostCategories = byPID(activities.filter { $0.editorPreview == nil })
        return Dictionary(uniqueKeysWithValues: activities.map {
            ($0.id, $0.editorPreview != nil ? classify([$0]) : hostCategories[$0.process.pid] ?? .other)
        })
    }

    /// `activities` are the listeners of a single process. Checked from the owner that most
    /// constrains how the port can be closed down to the one that constrains it least.
    public static func classify(_ activities: [Activity]) -> PortCategory {
        guard let activity = activities.first else { return .other }
        if isSystem(activity) { return .system }
        if activity.launchdJob != nil { return .background }
        if activities.allSatisfy({ $0.editorPreview != nil }) { return .devServer }
        if activity.applicationBundle?.direct == true { return .app }
        if activity.projectMarker != nil || startedFromShell(activity) || isOrphan(activity) { return .devServer }
        if activity.applicationBundle != nil { return .app }
        return .other
    }

    private static func isSystem(_ activity: Activity) -> Bool {
        if activity.inference.category == .systemService { return true }
        if let uid = activity.process.uid, uid != Int32(getuid()) { return true }
        guard let path = activity.process.executablePath else { return false }
        return ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"]
            .contains(where: path.hasPrefix)
    }

    /// A shell among the ancestors means someone ran it: a terminal, an editor's terminal or task,
    /// tmux, or an agent's command. Login shells show up as `-zsh`.
    private static func startedFromShell(_ activity: Activity) -> Bool {
        activity.parentChain.contains { parent in
            let name = (parent.command as NSString).lastPathComponent
            return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
        }
    }

    /// Reparented to launchd without being one of its jobs: the terminal or agent that started it
    /// has gone (`nohup`, `&`, a closed window), which is exactly what gets left open.
    private static func isOrphan(_ activity: Activity) -> Bool {
        activity.process.ppid == 1 && activity.launchdJob == nil
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "xonsh", "elvish"]
}
