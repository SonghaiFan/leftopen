import Foundation

public enum HomebrewCleanupPolicy {
    public enum Invocation: Equatable { case application, cleanup, invalid }

    public static func invocation(_ arguments: [String]) -> Invocation {
        if arguments == ["--homebrew-cleanup"] { return .cleanup }
        if arguments.contains(where: { $0.hasPrefix("--homebrew-") }) { return .invalid }
        return .application
    }

    /// Refuse orphaned app runtimes as well as app-launched project wrappers. Never kill them.
    public static func hasAppRuntime(processTable: String) -> Bool {
        processTable.split(separator: "\n").contains { line in
            let executable = line.trimmingCharacters(in: .whitespaces)
            return executable.contains("/Contents/Resources/Portless/node-")
        }
    }
}
