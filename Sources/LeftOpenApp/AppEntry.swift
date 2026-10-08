import AppKit
import Darwin
import LeftOpenCore

/// Dispatch before SwiftUI constructs MenuModel and starts address reconciliation.
@main
enum AppEntry {
    @MainActor
    static func main() async {
        switch HomebrewCleanupPolicy.invocation(Array(CommandLine.arguments.dropFirst())) {
        case .application:
            LeftOpenApp.main()
        case .invalid:
            FileHandle.standardError.write(Data("Invalid LeftOpen cleanup arguments.\n".utf8))
            exit(2)
        case .cleanup:
            exit(await UninstallManager.cleanupForHomebrew())
        }
    }
}
