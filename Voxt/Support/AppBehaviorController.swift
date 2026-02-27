import AppKit
import ServiceManagement

enum AppBehaviorController {
    @MainActor
    static func applyDockVisibility(showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    @MainActor
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func launchAtLoginIsEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
