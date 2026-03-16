import SwiftUI
import AppKit
import CoreAudio

extension AppDelegate {
    private var feedbackURL: URL {
        URL(string: "https://github.com/hehehai/voxt/issues/new/choose")!
    }

    func buildMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: AppLocalization.localizedString("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reportItem = NSMenuItem(title: AppLocalization.localizedString("Report"), action: #selector(openReportSettings), keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        let microphoneItem = NSMenuItem(title: AppLocalization.localizedString("Microphone"), action: nil, keyEquivalent: "")
        microphoneItem.submenu = buildMicrophoneMenu()
        menu.addItem(microphoneItem)

        let checkUpdatesItem = NSMenuItem(
            title: AppLocalization.localizedString("Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        let feedbackItem = NSMenuItem(
            title: AppLocalization.localizedString("Feedback"),
            action: #selector(openFeedbackPage),
            keyEquivalent: ""
        )
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        if appUpdateManager.hasUpdate, let latestVersion = appUpdateManager.latestVersion {
            let updateInfoItem = NSMenuItem(
                title: "New version: \(latestVersion)",
                action: nil,
                keyEquivalent: ""
            )
            updateInfoItem.isEnabled = false
            menu.addItem(updateInfoItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: AppLocalization.localizedString("Quit Voxt"), action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func buildMicrophoneMenu() -> NSMenu {
        let submenu = NSMenu()
        let devices = AudioInputDeviceManager.availableInputDevices()
        let resolvedSelectedID = resolvedMenuSelectedInputDeviceID(from: devices)

        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophoneFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(device.id)
            item.state = device.id == resolvedSelectedID ? .on : .off
            submenu.addItem(item)
        }

        if submenu.items.isEmpty {
            let emptyItem = NSMenuItem(title: AppLocalization.localizedString("No microphone available"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }

        return submenu
    }

    private func resolvedMenuSelectedInputDeviceID(from devices: [AudioInputDevice]) -> AudioDeviceID? {
        if let selectedInputDeviceID,
           devices.contains(where: { $0.id == selectedInputDeviceID }) {
            return selectedInputDeviceID
        }

        if let defaultDeviceID = AudioInputDeviceManager.defaultInputDeviceID(),
           devices.contains(where: { $0.id == defaultDeviceID }) {
            UserDefaults.standard.set(Int(defaultDeviceID), forKey: AppPreferenceKey.selectedInputDeviceID)
            return defaultDeviceID
        }

        if let first = devices.first {
            UserDefaults.standard.set(Int(first.id), forKey: AppPreferenceKey.selectedInputDeviceID)
            return first.id
        }

        UserDefaults.standard.set(0, forKey: AppPreferenceKey.selectedInputDeviceID)
        return nil
    }

    @objc private func checkForUpdates() {
        VoxtLog.info("Manual update check triggered from menu.")
        appUpdateManager.checkForUpdates(source: .manual)
    }

    @objc private func openFeedbackPage() {
        VoxtLog.info("Feedback page opened from menu.")
        NSWorkspace.shared.open(feedbackURL)
    }

    @objc private func openSettings() {
        openSettingsWindow(selectTab: nil)
    }

    @objc private func openReportSettings() {
        openSettingsWindow(selectTab: .report)
    }

    @objc private func selectMicrophoneFromMenu(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppPreferenceKey.selectedInputDeviceID)
    }

    func openSettingsWindow(selectTab: SettingsTab?) {
        if let window = settingsWindowController?.window {
            if let selectTab {
                NotificationCenter.default.post(
                    name: .voxtSettingsSelectTab,
                    object: nil,
                    userInfo: ["tab": selectTab.rawValue]
                )
            }
            centerAndBringWindowToFront(window)
            return
        }

        let contentView = SettingsView(
            mlxModelManager: mlxModelManager,
            customLLMManager: customLLMManager,
            historyStore: historyStore,
            appUpdateManager: appUpdateManager,
            initialTab: selectTab ?? .general
        )
        .frame(width: 760, height: 560)

        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .normal
        positionWindowTrafficLightButtons(window)

        let controller = NSWindowController(window: window)
        controller.shouldCascadeWindows = false
        settingsWindowController = controller
        window.center()
        controller.showWindow(nil)
        positionWindowTrafficLightButtons(window)

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.positionWindowTrafficLightButtons(window)
        }

        bringWindowToFront(window)
    }

    private func bringWindowToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func centerAndBringWindowToFront(_ window: NSWindow) {
        window.center()
        bringWindowToFront(window)
        positionWindowTrafficLightButtons(window)
    }

    private func positionWindowTrafficLightButtons(_ window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              let container = closeButton.superview
        else {
            return
        }

        let leftInset: CGFloat = 22
        let topInset: CGFloat = 21
        let spacing: CGFloat = 6

        let buttonSize = closeButton.frame.size
        let y = container.bounds.height - topInset - buttonSize.height
        let closeX = leftInset
        let miniaturizeX = closeX + buttonSize.width + spacing
        let zoomX = miniaturizeX + buttonSize.width + spacing

        closeButton.translatesAutoresizingMaskIntoConstraints = true
        miniaturizeButton.translatesAutoresizingMaskIntoConstraints = true
        zoomButton.translatesAutoresizingMaskIntoConstraints = true

        closeButton.setFrameOrigin(CGPoint(x: closeX, y: y))
        miniaturizeButton.setFrameOrigin(CGPoint(x: miniaturizeX, y: y))
        zoomButton.setFrameOrigin(CGPoint(x: zoomX, y: y))
    }

    @objc private func quit() {
        VoxtLog.info("Quit requested from menu.")
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Permissions Required")
        alert.informativeText = String(localized: "Voxt needs Microphone access. If you use Direct Dictation, enable Speech Recognition in System Settings → Privacy & Security.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Quit"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        }
        NSApp.terminate(nil)
    }
}
