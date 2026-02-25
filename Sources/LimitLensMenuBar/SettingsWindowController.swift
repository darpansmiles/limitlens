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
    private let builtInProviderIDs: Set<String> = [
        ProviderName.codex.rawValue,
        ProviderName.claude.rawValue,
        ProviderName.antigravity.rawValue,
    ]

    private var workingSettings: LimitLensSettings
    private let onSave: (LimitLensSettings) -> Void
    private let notificationModes = NotificationMode.allCases

    private let codexPathField = NSTextField()
    private let claudePathField = NSTextField()
    private let antigravityLogsPathField = NSTextField()
    private let refreshIntervalField = NSTextField()
    private let cooldownField = NSTextField()

    private let defaultThresholdsField = NSTokenField()
    private let codexThresholdsField = NSTokenField()
    private let claudeThresholdsField = NSTokenField()
    private let antigravityThresholdsField = NSTokenField()

    private let notificationModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let additionalOverrideNote = NSTextField(labelWithString: "")

    init(settings: LimitLensSettings, onSave: @escaping (LimitLensSettings) -> Void) {
        self.workingSettings = settings
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
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

        additionalOverrideNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        additionalOverrideNote.textColor = .secondaryLabelColor

        let permissionNote = NSTextField(labelWithString: "Notifications permission is required for banner/sound alerts.")
        permissionNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        permissionNote.textColor = .secondaryLabelColor

        let buttonBar = makeButtonBar()

        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(subtitleLabel)
        container.addArrangedSubview(formGrid)
        container.addArrangedSubview(additionalOverrideNote)
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
            [label("Codex Sessions Path"), makePathInputRow(field: codexPathField, selector: #selector(handleBrowseCodexPath))],
            [label("Claude Projects Path"), makePathInputRow(field: claudePathField, selector: #selector(handleBrowseClaudePath))],
            [label("Antigravity Logs Path"), makePathInputRow(field: antigravityLogsPathField, selector: #selector(handleBrowseAntigravityLogsPath))],
            [label("Refresh Interval (sec)"), refreshIntervalField],
            [label("Notification Cooldown (min)"), cooldownField],
            [label("Default Thresholds"), defaultThresholdsField],
            [label("Codex Threshold Override"), codexThresholdsField],
            [label("Claude Threshold Override"), claudeThresholdsField],
            [label("Antigravity Override"), antigravityThresholdsField],
            [label("Threshold Tools"), makeThresholdToolsRow()],
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

        configureThresholdField(defaultThresholdsField)
        configureThresholdField(codexThresholdsField)
        configureThresholdField(claudeThresholdsField)
        configureThresholdField(antigravityThresholdsField)

        return grid
    }

    private func makePathInputRow(field: NSTextField, selector: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill

        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let browseButton = NSButton(title: "Browse", target: self, action: selector)
        browseButton.bezelStyle = .rounded
        browseButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(field)
        row.addArrangedSubview(browseButton)
        return row
    }

    private func makeThresholdToolsRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8

        let standardButton = NSButton(title: "Apply Standard 70/75/80/85/90/95", target: self, action: #selector(handleApplyStandardThresholdPreset))
        standardButton.bezelStyle = .rounded

        let clearOverridesButton = NSButton(title: "Clear Provider Overrides", target: self, action: #selector(handleClearProviderOverrides))
        clearOverridesButton.bezelStyle = .rounded

        row.addArrangedSubview(standardButton)
        row.addArrangedSubview(clearOverridesButton)
        return row
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

    private func configureThresholdField(_ field: NSTokenField) {
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ", ")
        field.completionDelay = 0
        field.placeholderString = "e.g. 70,75,80"
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

        setThresholdTokens(defaultThresholdsField, values: settings.defaultThresholds)
        setThresholdTokens(codexThresholdsField, values: settings.perProviderThresholds[ProviderName.codex.rawValue] ?? [])
        setThresholdTokens(claudeThresholdsField, values: settings.perProviderThresholds[ProviderName.claude.rawValue] ?? [])
        setThresholdTokens(antigravityThresholdsField, values: settings.perProviderThresholds[ProviderName.antigravity.rawValue] ?? [])

        if let index = notificationModes.firstIndex(of: settings.notificationMode) {
            notificationModePopup.selectItem(at: index)
        } else {
            notificationModePopup.selectItem(at: 0)
        }

        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off

        let additionalCount = settings.perProviderThresholds.keys.filter { !builtInProviderIDs.contains($0) }.count
        additionalOverrideNote.stringValue = "Additional provider overrides preserved: \(additionalCount)"
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

        guard let defaultThresholds = parseThresholdTokens(defaultThresholdsField, allowEmpty: false) else {
            presentValidationError("Default thresholds must be tokenized integers between 0 and 100.")
            return
        }

        guard let codexOverride = parseThresholdTokens(codexThresholdsField, allowEmpty: true) else {
            presentValidationError("Codex override thresholds must be empty or tokenized integers between 0 and 100.")
            return
        }

        guard let claudeOverride = parseThresholdTokens(claudeThresholdsField, allowEmpty: true) else {
            presentValidationError("Claude override thresholds must be empty or tokenized integers between 0 and 100.")
            return
        }

        guard let antigravityOverride = parseThresholdTokens(antigravityThresholdsField, allowEmpty: true) else {
            presentValidationError("Antigravity override thresholds must be empty or tokenized integers between 0 and 100.")
            return
        }

        // We preserve non-built-in overrides so new providers can be added incrementally.
        var providerThresholds = workingSettings.perProviderThresholds.filter { !builtInProviderIDs.contains($0.key) }

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

    @objc
    private func handleApplyStandardThresholdPreset() {
        setThresholdTokens(defaultThresholdsField, values: [70, 75, 80, 85, 90, 95])
    }

    @objc
    private func handleClearProviderOverrides() {
        codexThresholdsField.objectValue = []
        codexThresholdsField.stringValue = ""
        claudeThresholdsField.objectValue = []
        claudeThresholdsField.stringValue = ""
        antigravityThresholdsField.objectValue = []
        antigravityThresholdsField.stringValue = ""
    }

    @objc
    private func handleBrowseCodexPath() {
        if let selected = chooseDirectory(startingAt: codexPathField.stringValue, prompt: "Select Codex sessions folder") {
            codexPathField.stringValue = selected
        }
    }

    @objc
    private func handleBrowseClaudePath() {
        if let selected = chooseDirectory(startingAt: claudePathField.stringValue, prompt: "Select Claude projects folder") {
            claudePathField.stringValue = selected
        }
    }

    @objc
    private func handleBrowseAntigravityLogsPath() {
        if let selected = chooseDirectory(startingAt: antigravityLogsPathField.stringValue, prompt: "Select Antigravity logs folder") {
            antigravityLogsPathField.stringValue = selected
        }
    }

    private func chooseDirectory(startingAt rawPath: String, prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = prompt

        let expanded = expandHomePath(rawPath)
        if FileManager.default.fileExists(atPath: expanded) {
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        return collapseHomePath(url.path)
    }

    private func collapseHomePath(_ absolutePath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard absolutePath.hasPrefix(home) else {
            return absolutePath
        }

        let suffix = absolutePath.dropFirst(home.count)
        if suffix.isEmpty {
            return "~"
        }
        return "~\(suffix)"
    }

    private func parseThresholdTokens(_ field: NSTokenField, allowEmpty: Bool) -> [Int]? {
        let fragments: [String]

        if let values = field.objectValue as? [Any], !values.isEmpty {
            fragments = values.map { String(describing: $0) }
        } else {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                return allowEmpty ? [] : nil
            }
            fragments = raw.split(separator: ",").map { String($0) }
        }

        var parsedValues: [Int] = []
        for fragment in fragments {
            let cleaned = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(cleaned), (0...100).contains(parsed) else {
                return nil
            }
            parsedValues.append(parsed)
        }

        let normalized = Array(Set(parsedValues)).sorted()
        if normalized.isEmpty && !allowEmpty {
            return nil
        }

        return normalized
    }

    private func setThresholdTokens(_ field: NSTokenField, values: [Int]) {
        let tokens = values.map(String.init)
        field.objectValue = tokens
        field.stringValue = tokens.joined(separator: ",")
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
