import AppKit
import ServiceManagement

/// Wraps the modern login-item API (`SMAppService`, macOS 13+) so the gadget
/// can start with the user session without writing LaunchAgent files by hand.
@MainActor
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()
    private init() {}

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when running from a real `.app` bundle, which `SMAppService` requires.
    var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isSupported else {
            throw LaunchAtLoginError.notBundled
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case notBundled

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "请从 MacGadgets.app 运行（用 Scripts/build-app.sh 打包），直接运行的命令行二进制无法注册为登录项。"
        }
    }
}
