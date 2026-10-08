import Foundation

/// Shared by the swipe action, detail view, and binding creation. No project inference is relaxed.
public enum FixedAddressEligibility {
    public enum Blocker: Equatable, Sendable {
        case unknownExecutable, differentUser, noLoopback, packageDirectory, unknownProject, unverifiedHTTP

        public var message: String {
            switch self {
            case .unknownExecutable: L("The service executable could not be identified.", "无法确认服务的可执行文件，暂不能启用固定地址。")
            case .differentUser: L("Fixed addresses require a service owned by the current user.", "固定地址仅支持已确认属于当前用户的服务。")
            case .noLoopback: L("This service does not listen on a supported loopback address.", "此服务未监听支持的本机回环地址。")
            case .packageDirectory: L("Services running from an installed package directory (such as global pi-web) are not supported yet. Use the original localhost address.", "安装包目录中的服务（如全局 pi-web）暂不支持固定地址，请继续使用原 localhost 地址。")
            case .unknownProject: L("No project could be identified for this service. Fixed addresses require a known project.", "未能识别此服务所属的项目，暂不能启用固定地址。")
            case .unverifiedHTTP: L("A local HTTP response has not been confirmed. Check that the service is ready, then refresh.", "尚未确认本地 HTTP 响应，请确认服务已启动后刷新。")
            }
        }
    }

    public static func identityBlocker(for activity: Activity, currentUID: Int32) -> Blocker? {
        guard activity.process.uid == currentUID else { return .differentUser }
        guard activity.process.executablePath != nil else { return .unknownExecutable }
        guard FixedAddressBinding.supportsLoopback(activity) else { return .noLoopback }
        guard activity.projectMarker != nil else {
            if activity.process.cwd?.split(separator: "/").contains(where: { $0.lowercased() == "node_modules" }) == true {
                return .packageDirectory
            }
            return .unknownProject
        }
        return nil
    }

    public static func blocker(for activity: Activity, webURL: URL?, currentUID: Int32) -> Blocker? {
        identityBlocker(for: activity, currentUID: currentUID)
            ?? (webURL?.scheme == "http" ? nil : .unverifiedHTTP)
    }
}
