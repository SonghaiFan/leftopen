import Foundation

/// Coding-agent command-line programs that listen on a local port themselves. The port belongs to
/// a session the user is running, so the process is an app to quit, not a dev server to close:
/// closing it ends that session. Servers the agent starts are separate processes and stay dev servers.
enum CodingAgent {
    /// The agent's name when `process` is the agent program itself.
    static func name(of process: ProcessFact) -> String? {
        guard let path = process.executablePath else { return nil }
        // Claude Code's native installer runs each version from ~/.local/share/claude/versions/<version>.
        if path.contains("/.local/share/claude/versions/") { return "Claude Code" }
        return nil
    }
}
