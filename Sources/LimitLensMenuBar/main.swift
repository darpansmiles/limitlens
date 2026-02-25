/*
This file is the native macOS menu bar entrypoint for LimitLens. It wires together
snapshot refresh, threshold evaluation, status item rendering, notification dispatch,
and user-facing settings controls.

It exists as a separate file because the menu bar lifecycle is an AppKit runtime with
its own event loop, timer semantics, and UI actions that should not leak into core logic.

This file talks to `SnapshotService`, `ThresholdEngine`, `SettingsStore`,
`NotificationCoordinator`, `SettingsWindowController`, and `LaunchAtLoginManager`
to turn core data into a live, interactive top-bar experience.
*/

import AppKit
import Foundation
import LimitLensCore

@MainActor
final class LimitLensMenuBarApp: NSObject, NSApplicationDelegate {
    private enum VisualSeverity {
        case unknown
        case normal
        case warning
        case critical

        var symbol: String {
            switch self {
            case .unknown:
                return "○"
            case .normal:
                return "●"
            case .warning:
                return "▲"
            case .critical:
                return "■"
            }
        }

        var color: NSColor {
            switch self {
            case .unknown:
                return .tertiaryLabelColor
            case .normal:
                return .systemGreen
            case .warning:
                return .systemOrange
            case .critical:
                return .systemRed
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsStore = SettingsStore()
    private let snapshotService = SnapshotService()
    private let notificationCoordinator = NotificationCoordinator()
    private let launchManager = LaunchAtLoginManager()

    private var runtimeState = ThresholdRuntimeState.empty
    private var currentSettings = LimitLensSettings.default
    private var activeRefreshInterval = 0
    private var refreshTimer: Timer?
    private var currentSnapshot: GlobalSnapshot?
    private var settingsWindowController: SettingsWindowController?

    private var appliedLaunchAtLogin: Bool?
    private var appliedLaunchExecutablePath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notificationCoordinator.requestPermissions()

        runtimeState = settingsStore.loadRuntimeState()
        currentSettings = settingsStore.loadSettings()

        configureStatusItem()
        applyLaunchPreference()
        refreshSnapshot(sendNotifications: false)
        startOrUpdateTimer(force: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsStore.saveRuntimeState(runtimeState)
    }

    private func configureStatusItem() {
        updateStatusItemAppearance(with: nil)
        rebuildMenu()
    }

    private func updateStatusItemAppearance(with snapshot: GlobalSnapshot?) {
        guard let button = statusItem.button else {
            return
        }

        guard let snapshot else {
            button.title = "LL booting..."
            return
        }

        let severity = overallSeverity(for: snapshot)
        let compactText = SnapshotFormatter.compactStatusText(snapshot)

        let iconAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: severity.color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
        ]

        let textAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]

        let result = NSMutableAttributedString(
            string: "\(severity.symbol) ",
            attributes: iconAttributes
        )
        result.append(NSAttributedString(string: "LL \(compactText)", attributes: textAttributes))
        button.attributedTitle = result
    }

    private func startOrUpdateTimer(force: Bool = false, snapshot: GlobalSnapshot? = nil) {
        let interval = resolveRefreshInterval(snapshot: snapshot)
        guard force || interval != activeRefreshInterval else {
            return
        }

        refreshTimer?.invalidate()
        activeRefreshInterval = interval

        // The refresh timer drives the always-on background monitoring loop.
        refreshTimer = Timer.scheduledTimer(
            timeInterval: TimeInterval(interval),
            target: self,
            selector: #selector(handleRefreshTimerTick),
            userInfo: nil,
            repeats: true
        )
    }

    private func refreshSnapshot(sendNotifications: Bool) {
        // Reloading each cycle keeps external edits to settings.json live.
        currentSettings = settingsStore.loadSettings()
        startOrUpdateTimer(snapshot: currentSnapshot)

        let snapshot = snapshotService.collectSnapshot(using: currentSettings)
        currentSnapshot = snapshot
        startOrUpdateTimer(snapshot: snapshot)

        updateStatusItemAppearance(with: snapshot)

        var mutableState = runtimeState
        let events = ThresholdEngine.evaluate(
            snapshot: snapshot,
            settings: currentSettings,
            state: &mutableState,
            now: Date()
        )
        runtimeState = mutableState
        settingsStore.saveRuntimeState(runtimeState)

        if sendNotifications {
            for event in events {
                notificationCoordinator.send(event: event, mode: currentSettings.notificationMode)
            }
        }

        applyLaunchPreference()
        rebuildMenu()
    }

    private func applyLaunchPreference() {
        // The LaunchAgent points to this running executable path.
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let noChange =
            (appliedLaunchAtLogin == currentSettings.launchAtLogin) &&
            (appliedLaunchExecutablePath == executablePath)

        guard !noChange else {
            return
        }

        launchManager.setEnabled(currentSettings.launchAtLogin, executablePath: executablePath)
        appliedLaunchAtLogin = currentSettings.launchAtLogin
        appliedLaunchExecutablePath = executablePath
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "LimitLens", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let timestampTitle: String
        if let snapshot = currentSnapshot {
            timestampTitle = "Last refresh: \(dualTimestamp(snapshot.capturedAt))"
        } else {
            timestampTitle = "Last refresh: pending"
        }

        let timestampItem = NSMenuItem(title: timestampTitle, action: nil, keyEquivalent: "")
        timestampItem.isEnabled = false
        menu.addItem(timestampItem)

        let cadenceItem = NSMenuItem(title: "Refresh cadence: \(activeRefreshInterval)s", action: nil, keyEquivalent: "")
        cadenceItem.isEnabled = false
        menu.addItem(cadenceItem)

        let thresholdItem = NSMenuItem(
            title: "Thresholds: \(thresholdSummaryText())",
            action: nil,
            keyEquivalent: ""
        )
        thresholdItem.isEnabled = false
        menu.addItem(thresholdItem)

        menu.addItem(NSMenuItem.separator())

        if let snapshot = currentSnapshot {
            for provider in snapshot.providers {
                menu.addItem(providerMenuItem(for: provider))
            }
        } else {
            let pending = NSMenuItem(title: "Collecting provider signals...", action: nil, keyEquivalent: "")
            pending.isEnabled = false
            menu.addItem(pending)
        }

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(handleRefreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(handleOpenSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let openSettingsFileItem = NSMenuItem(title: "Open Raw Settings File", action: #selector(handleOpenSettingsFile), keyEquivalent: "")
        openSettingsFileItem.target = self
        menu.addItem(openSettingsFileItem)

        let openNotificationsItem = NSMenuItem(
            title: "Open macOS Notification Settings",
            action: #selector(handleOpenNotificationSettings),
            keyEquivalent: ""
        )
        openNotificationsItem.target = self
        menu.addItem(openNotificationsItem)

        let notificationModeItem = NSMenuItem(title: "Notification Mode", action: nil, keyEquivalent: "")
        notificationModeItem.submenu = buildNotificationModeMenu()
        menu.addItem(notificationModeItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(handleToggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = currentSettings.launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let permissionNote = NSMenuItem(title: "Permission required: Notifications", action: nil, keyEquivalent: "")
        permissionNote.isEnabled = false
        menu.addItem(permissionNote)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit LimitLens", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func providerMenuItem(for snapshot: ProviderSnapshot) -> NSMenuItem {
        let severity = severity(for: snapshot)
        let pressureText: String

        if let pressure = snapshot.pressurePercent {
            pressureText = "\(Int(pressure.rounded()))%"
        } else {
            pressureText = "n/a"
        }

        var text = "\(severity.symbol) \(snapshot.provider.rawValue.capitalized)  pressure=\(pressureText)  \(snapshot.currentStatusSummary)"

        if let signal = snapshot.historicalSignals.sorted(by: { $0.observedAt > $1.observedAt }).first {
            // Keeping signal age visible makes historical warnings actionable.
            text += "  | last signal \(relativeAge(from: signal.observedAt))"
        }

        if !snapshot.errors.isEmpty {
            text += "  | source issue"
        }

        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: severity.color,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            ]
        )
        return item
    }

    private func buildNotificationModeMenu() -> NSMenu {
        let submenu = NSMenu()
        for mode in NotificationMode.allCases {
            let item = NSMenuItem(title: modeDisplayName(mode), action: #selector(handleSetNotificationMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (currentSettings.notificationMode == mode) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func thresholdSummaryText() -> String {
        let list = currentSettings.defaultThresholds.sorted().map(String.init).joined(separator: "/")
        return list.isEmpty ? "none" : list
    }

    private func overallSeverity(for snapshot: GlobalSnapshot) -> VisualSeverity {
        let maxPressure = snapshot.providers.compactMap(\.pressurePercent).max() ?? 0

        if maxPressure >= 95 {
            return .critical
        }
        if maxPressure >= 80 {
            return .warning
        }

        // Recent rate-limit evidence still deserves warning state even without pressure metrics.
        let hasRecentSignal = snapshot.providers.contains { provider in
            provider.historicalSignals.contains { signal in
                Date().timeIntervalSince(signal.observedAt) <= 3_600
            }
        }

        if hasRecentSignal {
            return .warning
        }
        if maxPressure > 0 {
            return .normal
        }

        return .unknown
    }

    private func resolveRefreshInterval(snapshot: GlobalSnapshot?) -> Int {
        let baseInterval = max(10, currentSettings.refreshIntervalSeconds)
        guard let snapshot else {
            return baseInterval
        }

        let maxPressure = snapshot.providers.compactMap(\.pressurePercent).max() ?? 0
        if maxPressure >= 95 {
            return 10
        }
        if maxPressure >= 80 {
            return min(baseInterval, 20)
        }
        return baseInterval
    }

    private func severity(for snapshot: ProviderSnapshot) -> VisualSeverity {
        if let pressure = snapshot.pressurePercent {
            if pressure >= 95 {
                return .critical
            }
            if pressure >= 80 {
                return .warning
            }
            return .normal
        }

        if !snapshot.historicalSignals.isEmpty {
            return .warning
        }

        return .unknown
    }

    private func modeDisplayName(_ mode: NotificationMode) -> String {
        switch mode {
        case .off:
            return "Off"
        case .sound:
            return "Sound"
        case .banner:
            return "Banner"
        case .soundAndBanner:
            return "Sound + Banner"
        }
    }

    @objc
    private func handleRefreshNow() {
        refreshSnapshot(sendNotifications: false)
    }

    @objc
    private func handleRefreshTimerTick() {
        refreshSnapshot(sendNotifications: true)
    }

    @objc
    private func handleOpenSettingsWindow() {
        let controller = SettingsWindowController(settings: currentSettings) { [weak self] updated in
            guard let self else {
                return
            }

            self.currentSettings = updated
            self.settingsStore.saveSettings(updated)

            // Applying immediately ensures threshold and cadence changes take effect now.
            self.applyLaunchPreference()
            self.startOrUpdateTimer(force: true, snapshot: self.currentSnapshot)
            self.refreshSnapshot(sendNotifications: false)
        }

        settingsWindowController = controller
        controller.present()
    }

    @objc
    private func handleOpenSettingsFile() {
        settingsStore.saveSettings(currentSettings)
        NSWorkspace.shared.open(settingsStore.settingsFileURL())
    }

    @objc
    private func handleOpenNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func handleSetNotificationMode(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let mode = NotificationMode(rawValue: raw)
        else {
            return
        }

        currentSettings.notificationMode = mode
        settingsStore.saveSettings(currentSettings)
        rebuildMenu()
    }

    @objc
    private func handleToggleLaunchAtLogin() {
        currentSettings.launchAtLogin.toggle()
        settingsStore.saveSettings(currentSettings)
        applyLaunchPreference()
        rebuildMenu()
    }

    @objc
    private func handleQuit() {
        NSApplication.shared.terminate(nil)
    }
}

// Accessory policy keeps the app in menu bar only, without a dock icon.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = LimitLensMenuBarApp()
application.delegate = appDelegate
application.run()
