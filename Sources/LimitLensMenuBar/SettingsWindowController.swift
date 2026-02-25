/*
This file implements a native settings window for the menu bar application. It gives
users direct controls for source paths, thresholds, notification behavior, cadence,
and launch-at-login without editing JSON manually.

It exists as a separate file because settings UI concerns are distinct from the menu
runtime loop. Isolating this controller keeps menu orchestration focused on refresh
and alerts, while this window handles validation and preference editing.

This file talks to `LimitLensSettings` for the editable model and reports saved values
back to the app delegate through an `onSave` callback.
*/

import AppKit
import Foundation
import LimitLensCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private var workingSettings: LimitLensSettings
    private let onSave: (LimitLensSettings) -> Void
    private let notificationModes = NotificationMode.allCases

    private let codexPathField = NSTextField()
    private let claudePathField = NSTextField()
    private let antigravityLogsPathField = NSTextField()
    private let refreshIntervalField = NSTextField()
    private let cooldownField = NSTextField()

    private let defaultThresholdsField = NSTextField()
    private let codexThresholdsField = NSTextField()
    private let claudeThresholdsField = NSTextField()
    private let antigravityThresholdsField = NSTextField()

    private let notificationModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(settings: LimitLensSettings, onSave: @escaping (LimitLensSettings) -> Void) {
        self.workingSettings = settings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LimitLens Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        configureWindowContent()
        apply(settings: settings)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            return
        }

        // Centering keeps this utility panel predictable across display setups.
        window.center()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureWindowContent() {
        guard let window else {
            return
        }

        let root = NSVisualEffectView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.material = .sidebar
        root.state = .active

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "LimitLens Preferences")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: "Tune thresholds, refresh cadence, notifications, and source paths.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let formGrid = makeFormGrid()

        let permissionNote = NSTextField(labelWithString: "Notifications permission is required for banner/sound alerts.")
        permissionNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        permissionNote.textColor = .secondaryLabelColor

        let buttonBar = makeButtonBar()

        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(subtitleLabel)
        container.addArrangedSubview(formGrid)
        container.addArrangedSubview(permissionNote)
        container.addArrangedSubview(buttonBar)

        root.addSubview(container)

        window.contentView = root

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    private func makeFormGrid() -> NSGridView {
        populateNotificationPopup()

        // The grid keeps form alignment clean while staying native AppKit.
        let grid = NSGridView(views: [
            [label("Codex Sessions Path"), codexPathField],
            [label("Claude Projects Path"), claudePathField],
            [label("Antigravity Logs Path"), antigravityLogsPathField],
            [label("Refresh Interval (sec)"), refreshIntervalField],
            [label("Notification Cooldown (min)"), cooldownField],
            [label("Default Thresholds"), defaultThresholdsField],
            [label("Codex Threshold Override"), codexThresholdsField],
            [label("Claude Threshold Override"), claudeThresholdsField],
            [label("Antigravity Override"), antigravityThresholdsField],
            [label("Notification Mode"), notificationModePopup],
            [label("Launch At Login"), launchAtLoginCheckbox],
        ])

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.xPlacement = .leading
        grid.rowAlignment = .firstBaseline

        // Column 0 is labels, column 1 stretches to absorb available width.
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 220
        grid.column(at: 1).xPlacement = .fill

        configureTextField(codexPathField)
        configureTextField(claudePathField)
        configureTextField(antigravityLogsPathField)
        configureTextField(refreshIntervalField)
        configureTextField(cooldownField)
        configureTextField(defaultThresholdsField)
        configureTextField(codexThresholdsField)
        configureTextField(claudeThresholdsField)
        configureTextField(antigravityThresholdsField)

        return grid
    }

    private func makeButtonBar() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.distribution = .gravityAreas
        bar.spacing = 10

        let openNotificationsButton = NSButton(title: "Open Notification Settings", target: self, action: #selector(handleOpenNotificationSettings))
        openNotificationsButton.bezelStyle = .rounded

        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(handleResetDefaults))
        resetButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(handleCancel))
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(handleSave))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let leading = NSStackView(views: [openNotificationsButton])
        leading.orientation = .horizontal

        let trailing = NSStackView(views: [resetButton, cancelButton, saveButton])
        trailing.orientation = .horizontal
        trailing.spacing = 8

        bar.addArrangedSubview(leading)
        bar.addArrangedSubview(NSView())
        bar.addArrangedSubview(trailing)

        return bar
    }

    private func label(_ text: String) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        view.textColor = .secondaryLabelColor
        return view
    }

    private func configureTextField(_ field: NSTextField) {
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
    }

    private func populateNotificationPopup() {
        notificationModePopup.removeAllItems()
        for mode in notificationModes {
            notificationModePopup.addItem(withTitle: modeDisplayName(mode))
        }
    }

    private func apply(settings: LimitLensSettings) {
        workingSettings = settings

        codexPathField.stringValue = settings.codexSessionsPath
        claudePathField.stringValue = settings.claudeProjectsPath
        antigravityLogsPathField.stringValue = settings.antigravityLogsPath

        refreshIntervalField.stringValue = String(settings.refreshIntervalSeconds)
        cooldownField.stringValue = String(settings.notificationCooldownMinutes)

        defaultThresholdsField.stringValue = thresholdListText(settings.defaultThresholds)
        codexThresholdsField.stringValue = thresholdListText(settings.perProviderThresholds[ProviderName.codex.rawValue] ?? [])
        claudeThresholdsField.stringValue = thresholdListText(settings.perProviderThresholds[ProviderName.claude.rawValue] ?? [])
        antigravityThresholdsField.stringValue = thresholdListText(settings.perProviderThresholds[ProviderName.antigravity.rawValue] ?? [])

        if let index = notificationModes.firstIndex(of: settings.notificationMode) {
            notificationModePopup.selectItem(at: index)
        } else {
            notificationModePopup.selectItem(at: 0)
        }

        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
    }

    @objc
    private func handleSave() {
        // We validate in one place so bad values cannot silently degrade runtime behavior.
        guard let refreshInterval = Int(refreshIntervalField.stringValue), refreshInterval > 0 else {
            presentValidationError("Refresh interval must be a positive integer.")
            return
        }

        guard let cooldown = Int(cooldownField.stringValue), cooldown >= 0 else {
            presentValidationError("Notification cooldown must be zero or a positive integer.")
            return
        }

        guard let defaultThresholds = parseThresholdList(defaultThresholdsField.stringValue, allowEmpty: false) else {
            presentValidationError("Default thresholds must be comma-separated integers between 0 and 100.")
            return
        }

        guard let codexOverride = parseThresholdList(codexThresholdsField.stringValue, allowEmpty: true) else {
            presentValidationError("Codex override thresholds must be empty or comma-separated integers between 0 and 100.")
            return
        }

        guard let claudeOverride = parseThresholdList(claudeThresholdsField.stringValue, allowEmpty: true) else {
            presentValidationError("Claude override thresholds must be empty or comma-separated integers between 0 and 100.")
            return
        }

        guard let antigravityOverride = parseThresholdList(antigravityThresholdsField.stringValue, allowEmpty: true) else {
            presentValidationError("Antigravity override thresholds must be empty or comma-separated integers between 0 and 100.")
            return
        }

        var providerThresholds: [String: [Int]] = [:]

        // Empty overrides intentionally mean "inherit default thresholds."
        if !codexOverride.isEmpty {
            providerThresholds[ProviderName.codex.rawValue] = codexOverride
        }
        if !claudeOverride.isEmpty {
            providerThresholds[ProviderName.claude.rawValue] = claudeOverride
        }
        if !antigravityOverride.isEmpty {
            providerThresholds[ProviderName.antigravity.rawValue] = antigravityOverride
        }

        let modeIndex = max(0, min(notificationModePopup.indexOfSelectedItem, notificationModes.count - 1))
        let mode = notificationModes[modeIndex]

        var updated = workingSettings
        updated.codexSessionsPath = codexPathField.stringValue
        updated.claudeProjectsPath = claudePathField.stringValue
        updated.antigravityLogsPath = antigravityLogsPathField.stringValue
        updated.refreshIntervalSeconds = refreshInterval
        updated.notificationCooldownMinutes = cooldown
        updated.defaultThresholds = defaultThresholds
        updated.perProviderThresholds = providerThresholds
        updated.notificationMode = mode
        updated.launchAtLogin = (launchAtLoginCheckbox.state == .on)

        onSave(updated)
        window?.close()
    }

    @objc
    private func handleCancel() {
        window?.close()
    }

    @objc
    private func handleResetDefaults() {
        apply(settings: .default)
    }

    @objc
    private func handleOpenNotificationSettings() {
        // This deep link opens the system Notifications settings page.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func parseThresholdList(_ value: String, allowEmpty: Bool) -> [Int]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allowEmpty ? [] : nil
        }

        let tokens = trimmed.split(separator: ",")
        var values: [Int] = []

        for token in tokens {
            let fragment = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(fragment), (0...100).contains(parsed) else {
                return nil
            }
            values.append(parsed)
        }

        // Sorting and de-duplication keeps downstream threshold comparisons stable.
        let normalized = Array(Set(values)).sorted()
        if normalized.isEmpty && !allowEmpty {
            return nil
        }

        return normalized
    }

    private func thresholdListText(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ",")
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

    private func presentValidationError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid Settings"
        alert.informativeText = message
        alert.runModal()
    }
}
