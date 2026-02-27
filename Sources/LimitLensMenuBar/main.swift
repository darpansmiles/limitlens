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
import LimitLensMenuBarSupport

@MainActor
final class LimitLensMenuBarApp: NSObject, NSApplicationDelegate {
    private struct RefreshComputation: Sendable {
        let settings: LimitLensSettings
        let settingsWarnings: [String]
        let snapshot: GlobalSnapshot
        let runtimeState: ThresholdRuntimeState
        let events: [ThresholdEvent]
    }

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
    private let notificationCoordinator = NotificationCoordinator()
    private let launchManager = LaunchAtLoginManager()
    private let menuWelcomeTTLSeconds: TimeInterval = 48 * 60 * 60

    private var runtimeState = ThresholdRuntimeState.empty
    private var currentSettings = LimitLensSettings.default
    private var activeRefreshInterval = 0
    private var refreshTimer: Timer?
    private var currentSnapshot: GlobalSnapshot?
    private var settingsWindowController: SettingsWindowController?

    private var notificationStatusText = "Checking..."
    private var lastNotificationDeliveryIssue: String?
    private var launchStatusText = "Not configured"
    private var settingsLoadWarnings: [String] = []
    private var runtimeStateWarnings: [String] = []
    private var refreshInFlight = false
    private var queuedRefreshWantsNotifications = false

    private var appliedLaunchAtLogin: Bool?
    private var appliedLaunchExecutablePath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtimeStateResult = settingsStore.loadRuntimeStateWithDiagnostics()
        runtimeState = runtimeStateResult.state
        runtimeStateWarnings = runtimeStateResult.warnings
        markMenuWelcomeSeenIfNeeded()
        loadSettingsFromStore()

        configureStatusItem()
        refreshNotificationAuthorizationState()
        maybeRequestNotificationPermissionIfNeeded()

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

    private func refreshNotificationAuthorizationState() {
        notificationCoordinator.refreshAuthorizationState { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.notificationStatusText = self.notificationCoordinator.authorizationSummaryText()
                self.rebuildMenu()
            }
        }
    }

    private func updateStatusItemAppearance(with snapshot: GlobalSnapshot?) {
        guard let button = statusItem.button else {
            return
        }

        guard let snapshot else {
            button.title = "LL booting..."
            return
        }

        let severity = visualSeverity(from: SeverityEvaluator.globalSeverity(for: snapshot, settings: currentSettings))
        let compactText = SnapshotFormatter.compactStatusText(snapshot, settings: currentSettings)

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
        if refreshInFlight {
            // We coalesce stacked timer ticks into one trailing refresh request.
            queuedRefreshWantsNotifications = queuedRefreshWantsNotifications || sendNotifications
            return
        }

        refreshInFlight = true
        let runtimeStateAtStart = runtimeState

        Task { [weak self] in
            guard let self else {
                return
            }

            // Heavy parsing and command execution run off the main actor to keep UI responsive.
            let computation = await Task.detached(priority: .utility) { () -> RefreshComputation in
                let settingsStore = SettingsStore()
                let settingsResult = settingsStore.loadSettingsWithDiagnostics()
                let snapshotService = SnapshotService()
                let snapshot = snapshotService.collectSnapshot(using: settingsResult.settings)

                var mutableState = runtimeStateAtStart
                let events = ThresholdEngine.evaluate(
                    snapshot: snapshot,
                    settings: settingsResult.settings,
                    state: &mutableState,
                    now: Date()
                )
                settingsStore.saveRuntimeState(mutableState)

                return RefreshComputation(
                    settings: settingsResult.settings,
                    settingsWarnings: settingsResult.warnings,
                    snapshot: snapshot,
                    runtimeState: mutableState,
                    events: events
                )
            }.value

            self.applyRefreshComputation(computation, sendNotifications: sendNotifications)
        }
    }

    private func applyRefreshComputation(_ computation: RefreshComputation, sendNotifications: Bool) {
        currentSettings = computation.settings
        settingsLoadWarnings = computation.settingsWarnings
        currentSnapshot = computation.snapshot
        runtimeState = computation.runtimeState

        startOrUpdateTimer(snapshot: computation.snapshot)
        updateStatusItemAppearance(with: computation.snapshot)
        refreshNotificationAuthorizationState()
        maybeRequestNotificationPermissionIfNeeded()

        if sendNotifications {
            for event in computation.events {
                notificationCoordinator.send(event: event, mode: currentSettings.notificationMode) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.handleNotificationResult(result)
                    }
                }
            }
        }

        applyLaunchPreference()
        rebuildMenu()

        refreshInFlight = false
        if queuedRefreshWantsNotifications {
            let queuedWantsNotifications = queuedRefreshWantsNotifications
            queuedRefreshWantsNotifications = false
            refreshSnapshot(sendNotifications: queuedWantsNotifications)
        }
    }

    private func handleNotificationResult(_ result: NotificationSendResult) {
        switch result {
        case .sent, .skippedDisabled, .soundOnly:
            lastNotificationDeliveryIssue = nil
        case .blockedByPermission:
            lastNotificationDeliveryIssue = "Notification banner blocked by macOS permission."
        case .failed(let message):
            lastNotificationDeliveryIssue = "Notification delivery failed: \(message)"
        }

        rebuildMenu()
    }

    private func applyLaunchPreference() {
        let resolution: (path: String?, warning: String?) =
            currentSettings.launchAtLogin ? resolveLaunchExecutablePath() : (nil, nil)
        let desiredPath = currentSettings.launchAtLogin ? resolution.path : nil

        let noChange =
            (appliedLaunchAtLogin == currentSettings.launchAtLogin) &&
            (appliedLaunchExecutablePath == desiredPath)

        guard !noChange else {
            if let warning = resolution.warning {
                launchStatusText = warning
            }
            return
        }

        let result = launchManager.setEnabled(currentSettings.launchAtLogin, executablePath: desiredPath)

        switch result {
        case .success:
            if currentSettings.launchAtLogin {
                launchStatusText = "Enabled"
            } else {
                launchStatusText = "Disabled"
            }
        case .failure(let message):
            launchStatusText = message
        }

        if let warning = resolution.warning {
            launchStatusText = warning
        }

        appliedLaunchAtLogin = currentSettings.launchAtLogin
        appliedLaunchExecutablePath = desiredPath
    }

    private func resolveLaunchExecutablePath() -> (path: String?, warning: String?) {
        if Bundle.main.bundleURL.pathExtension == "app", let bundled = Bundle.main.executableURL?.path {
            return (bundled, nil)
        }

        let commandPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

        // Development `swift run` paths are not stable across clean/rebuild cycles.
        if commandPath.contains("/.build/") {
            return (nil, "Launch at login needs an installed app bundle (not a development build path).")
        }

        return (commandPath, nil)
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

        if shouldShowMenuWelcome() {
            menu.addItem(NSMenuItem.separator())

            let welcomeTitle = NSMenuItem(title: "Welcome to LimitLens", action: nil, keyEquivalent: "")
            welcomeTitle.isEnabled = false
            menu.addItem(welcomeTitle)

            if let snapshot = currentSnapshot {
                let detection = ProviderDetectionEvaluator.evaluate(snapshot: snapshot)
                for status in detection {
                    let marker = status.detected ? "✓" : "✗"
                    let statusItem = NSMenuItem(
                        title: "\(marker) \(status.displayName) \(status.detected ? "detected" : "not found")",
                        action: nil,
                        keyEquivalent: ""
                    )
                    statusItem.isEnabled = false
                    menu.addItem(statusItem)
                }
            } else {
                let pending = NSMenuItem(title: "Detecting providers...", action: nil, keyEquivalent: "")
                pending.isEnabled = false
                menu.addItem(pending)
            }

            let severityHint = NSMenuItem(
                title: "Severity colors: green=normal, amber=warning, red=critical.",
                action: nil,
                keyEquivalent: ""
            )
            severityHint.isEnabled = false
            menu.addItem(severityHint)

            let configureItem = NSMenuItem(title: "Configure Paths →", action: #selector(handleConfigurePathsFromWelcome), keyEquivalent: "")
            configureItem.target = self
            menu.addItem(configureItem)
        }

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

        let notificationStatusItem = NSMenuItem(title: "Notifications: \(notificationStatusText)", action: nil, keyEquivalent: "")
        notificationStatusItem.isEnabled = false
        menu.addItem(notificationStatusItem)

        let launchStatusItem = NSMenuItem(title: "Launch at login: \(launchStatusText)", action: nil, keyEquivalent: "")
        launchStatusItem.isEnabled = false
        menu.addItem(launchStatusItem)

        if let issue = lastNotificationDeliveryIssue {
            let issueItem = NSMenuItem(title: "Alert issue: \(issue)", action: nil, keyEquivalent: "")
            issueItem.isEnabled = false
            menu.addItem(issueItem)
        }

        for warning in (runtimeStateWarnings + settingsLoadWarnings) {
            let warningItem = NSMenuItem(title: "Config warning: \(warning)", action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            menu.addItem(warningItem)
        }

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

        let quitItem = NSMenuItem(title: "Quit LimitLens", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func providerMenuItem(for snapshot: ProviderSnapshot) -> NSMenuItem {
        let severity = visualSeverity(from: SeverityEvaluator.providerSeverity(for: snapshot, settings: currentSettings))
        let pressureText: String

        if let pressure = snapshot.pressurePercent {
            pressureText = "\(Int(pressure.rounded()))%"
        } else {
            pressureText = "n/a"
        }

        var text = "\(severity.symbol) \(snapshot.providerDisplayName)  pressure=\(pressureText)  \(snapshot.currentStatusSummary)"

        if let signal = snapshot.historicalSignals.sorted(by: { $0.observedAt > $1.observedAt }).first {
            // Keeping signal age visible makes historical warnings actionable.
            text += "  | last signal \(relativeAge(from: signal.observedAt))"
        }

        if !snapshot.errors.isEmpty {
            text += "  | source issue"
        }

        let focusField = settingsFocusField(for: snapshot.provider)
        let hasFixAction = !snapshot.errors.isEmpty && focusField != nil
        if hasFixAction {
            text += "  | ⚠ Fix"
        }

        let item = NSMenuItem(
            title: text,
            action: hasFixAction ? #selector(handleProviderFixAction(_:)) : nil,
            keyEquivalent: ""
        )
        item.isEnabled = hasFixAction
        item.target = hasFixAction ? self : nil
        item.representedObject = hasFixAction ? snapshot.provider.rawValue : nil
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
        let defaults = currentSettings.defaultThresholds.sorted().map(String.init).joined(separator: "/")
        let defaultText = defaults.isEmpty ? "none" : defaults

        let overrideParts = currentSettings.perProviderThresholds
            .filter { !$0.value.isEmpty }
            .map { key, values in
                let normalized = Array(Set(values.filter { (0...100).contains($0) })).sorted()
                return (key, normalized.map(String.init).joined(separator: "/"))
            }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }

        guard !overrideParts.isEmpty else {
            return "default \(defaultText)"
        }

        let visible = overrideParts.prefix(2).map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        let remainder = overrideParts.count - min(2, overrideParts.count)
        if remainder > 0 {
            return "default \(defaultText); overrides \(visible), +\(remainder) more"
        }
        return "default \(defaultText); overrides \(visible)"
    }

    private func resolveRefreshInterval(snapshot: GlobalSnapshot?) -> Int {
        let baseInterval = max(10, currentSettings.refreshIntervalSeconds)
        guard let snapshot else {
            return baseInterval
        }

        let severities = snapshot.providers.map { SeverityEvaluator.providerSeverity(for: $0, settings: currentSettings) }
        if severities.contains(.critical) {
            return 10
        }
        if severities.contains(.warning) {
            return min(baseInterval, 20)
        }
        return baseInterval
    }

    private func markMenuWelcomeSeenIfNeeded(now: Date = Date()) {
        guard runtimeState.menuWelcomeFirstShownAt == nil else {
            return
        }

        // Persisting first-seen time lets the 48-hour hide rule survive process restarts.
        runtimeState.menuWelcomeFirstShownAt = now
        settingsStore.saveRuntimeState(runtimeState)
    }

    private func shouldShowMenuWelcome(now: Date = Date()) -> Bool {
        guard runtimeState.menuWelcomeDismissedAt == nil else {
            return false
        }

        guard let firstShownAt = runtimeState.menuWelcomeFirstShownAt else {
            return true
        }

        return now.timeIntervalSince(firstShownAt) < menuWelcomeTTLSeconds
    }

    private func dismissMenuWelcome(now: Date = Date()) {
        guard runtimeState.menuWelcomeDismissedAt == nil else {
            return
        }

        runtimeState.menuWelcomeDismissedAt = now
        settingsStore.saveRuntimeState(runtimeState)
    }

    private func loadSettingsFromStore() {
        let settingsResult = settingsStore.loadSettingsWithDiagnostics()
        currentSettings = settingsResult.settings
        settingsLoadWarnings = settingsResult.warnings
    }

    private func maybeRequestNotificationPermissionIfNeeded() {
        guard requiresNotificationAuthorization(mode: currentSettings.notificationMode) else {
            return
        }

        notificationCoordinator.refreshAuthorizationState { [weak self] state in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.notificationStatusText = self.notificationCoordinator.authorizationSummaryText()
                guard state == .notDetermined else {
                    self.rebuildMenu()
                    return
                }

                self.notificationCoordinator.requestPermissions { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.refreshNotificationAuthorizationState()
                    }
                }
            }
        }
    }

    private func requiresNotificationAuthorization(mode: NotificationMode) -> Bool {
        mode == .banner || mode == .soundAndBanner
    }

    private func visualSeverity(from severity: SeverityLevel) -> VisualSeverity {
        switch severity {
        case .critical:
            return .critical
        case .warning:
            return .warning
        case .normal:
            return .normal
        case .unknown:
            return .unknown
        }
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
        openSettingsWindow(focusField: nil)
    }

    @objc
    private func handleConfigurePathsFromWelcome() {
        openSettingsWindow(focusField: nil)
    }

    @objc
    private func handleProviderFixAction(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let focusField = settingsFocusField(for: ProviderName(rawValue: raw))
        else {
            return
        }

        openSettingsWindow(focusField: focusField)
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
        maybeRequestNotificationPermissionIfNeeded()
        refreshNotificationAuthorizationState()
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

    private func openSettingsWindow(focusField: SettingsWindowController.FocusField?) {
        let controller = SettingsWindowController(settings: currentSettings, focusField: focusField) { [weak self] updated in
            guard let self else {
                return
            }

            self.currentSettings = updated
            self.settingsStore.saveSettings(updated)
            self.dismissMenuWelcome()

            // Applying immediately ensures threshold and cadence changes take effect now.
            self.applyLaunchPreference()
            self.startOrUpdateTimer(force: true, snapshot: self.currentSnapshot)
            self.refreshSnapshot(sendNotifications: false)
        }

        settingsWindowController = controller
        controller.present()
    }

    private func settingsFocusField(for provider: ProviderName) -> SettingsWindowController.FocusField? {
        switch provider {
        case .codex:
            return .codexPath
        case .claude:
            return .claudePath
        case .antigravity:
            return .antigravityLogsPath
        case .custom:
            return nil
        }
    }
}

// Accessory policy keeps the app in menu bar only, without a dock icon.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = LimitLensMenuBarApp()
application.delegate = appDelegate
application.run()
