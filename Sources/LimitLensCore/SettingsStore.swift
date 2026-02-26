/*
This file implements durable local storage for user settings and threshold runtime
state. It is responsible for turning default policy into a concrete on-disk config
that both CLI and menu bar can share.

It exists separately because persistence behavior is cross-interface infrastructure.
Keeping settings IO centralized prevents drift between executables and gives us one
place to enforce default values and migration behavior.

This file talks to `LimitLensSettings` and `ThresholdRuntimeState` models by encoding
and decoding them as JSON files under the user's Application Support directory.
*/

import Foundation

public struct SettingsLoadResult: Sendable {
    public let settings: LimitLensSettings
    public let warnings: [String]

    public init(settings: LimitLensSettings, warnings: [String]) {
        self.settings = settings
        self.warnings = warnings
    }
}

public struct RuntimeStateLoadResult: Sendable {
    public let state: ThresholdRuntimeState
    public let warnings: [String]

    public init(state: ThresholdRuntimeState, warnings: [String]) {
        self.state = state
        self.warnings = warnings
    }
}

public struct SettingsStore {
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootDirectory = appSupport.appendingPathComponent("LimitLens", isDirectory: true)
        }
    }

    public func settingsFileURL() -> URL {
        rootDirectory.appendingPathComponent("settings.json")
    }

    public func runtimeStateFileURL() -> URL {
        rootDirectory.appendingPathComponent("runtime_state.json")
    }

    public func ensureStorageDirectory() {
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func loadSettings() -> LimitLensSettings {
        loadSettingsWithDiagnostics().settings
    }

    public func loadSettingsWithDiagnostics() -> SettingsLoadResult {
        ensureStorageDirectory()
        let url = settingsFileURL()

        guard let data = try? Data(contentsOf: url) else {
            // First run path: persist defaults so users can edit immediately.
            saveSettings(.default)
            return SettingsLoadResult(settings: .default, warnings: [])
        }

        guard let decoded = try? decoder.decode(LimitLensSettings.self, from: data) else {
            // Corrupted settings fallback keeps the app alive while preserving forensic evidence.
            let backupPath = backupCorruptFile(at: url, kind: "settings")
            saveSettings(.default)
            var warnings = ["Settings file was unreadable. Defaults were restored."]
            if let backupPath {
                warnings.append("Corrupt settings backup saved at \(backupPath).")
            } else {
                warnings.append("Unable to create backup copy of corrupt settings file.")
            }
            return SettingsLoadResult(settings: .default, warnings: warnings)
        }

        let settingsWarnings = settingsDiagnostics(for: decoded)
        return SettingsLoadResult(settings: decoded, warnings: settingsWarnings)
    }

    public func saveSettings(_ settings: LimitLensSettings) {
        ensureStorageDirectory()
        guard let encoded = try? encoder.encode(settings) else {
            return
        }
        atomicWrite(encoded, to: settingsFileURL())
    }

    public func loadRuntimeState() -> ThresholdRuntimeState {
        loadRuntimeStateWithDiagnostics().state
    }

    public func loadRuntimeStateWithDiagnostics() -> RuntimeStateLoadResult {
        ensureStorageDirectory()
        let url = runtimeStateFileURL()

        guard let data = try? Data(contentsOf: url) else {
            return RuntimeStateLoadResult(state: .empty, warnings: [])
        }

        guard let decoded = try? decoder.decode(ThresholdRuntimeState.self, from: data) else {
            let backupPath = backupCorruptFile(at: url, kind: "runtime_state")
            var warnings = ["Runtime state file was unreadable. State was reset."]
            if let backupPath {
                warnings.append("Corrupt runtime state backup saved at \(backupPath).")
            }
            return RuntimeStateLoadResult(state: .empty, warnings: warnings)
        }

        return RuntimeStateLoadResult(state: decoded, warnings: [])
    }

    public func saveRuntimeState(_ state: ThresholdRuntimeState) {
        ensureStorageDirectory()
        guard let encoded = try? encoder.encode(state) else {
            return
        }
        atomicWrite(encoded, to: runtimeStateFileURL())
    }

    private func atomicWrite(_ data: Data, to url: URL) {
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? data.write(to: tempURL, options: .atomic)
        // Replace keeps updates safe against partial write crashes.
        _ = try? fileManager.replaceItemAt(url, withItemAt: tempURL)
        // If replace failed because destination did not exist yet, fallback to move.
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.moveItem(at: tempURL, to: url)
        }
    }

    private func backupCorruptFile(at url: URL, kind: String) -> String? {
        let timestamp = Self.backupTimestampFormatter.string(from: Date())
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("\(kind).corrupt.\(timestamp).json")

        do {
            try fileManager.moveItem(at: url, to: backupURL)
            return backupURL.path
        } catch {
            do {
                try fileManager.copyItem(at: url, to: backupURL)
                return backupURL.path
            } catch {
                return nil
            }
        }
    }

    private func settingsDiagnostics(for settings: LimitLensSettings) -> [String] {
        var warnings: [String] = []

        if !settings.externalProviders.isEmpty && !settings.allowExternalProviderCommands {
            warnings.append("External providers are configured but command execution is disabled.")
        }

        var seenExternalIDs: Set<String> = []
        for provider in settings.externalProviders {
            let id = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = provider.command.trimmingCharacters(in: .whitespacesAndNewlines)
            let dedupeKey = id.lowercased()

            guard !id.isEmpty else {
                warnings.append("An external provider has an empty id and will be ignored.")
                continue
            }

            if !isValidProviderID(id) {
                warnings.append("External provider id '\(id)' is not slug-style and may be ignored.")
            }

            if seenExternalIDs.contains(dedupeKey) {
                warnings.append("Duplicate external provider id '\(id)' detected; later entries are ignored.")
                continue
            }
            seenExternalIDs.insert(dedupeKey)

            guard !command.isEmpty else {
                warnings.append("External provider '\(id)' has an empty command and will be ignored.")
                continue
            }

            if !command.hasPrefix("/") {
                warnings.append("External provider '\(id)' should use an absolute command path.")
            } else if settings.allowExternalProviderCommands, !fileManager.isExecutableFile(atPath: command) {
                warnings.append("External provider '\(id)' command is not executable at \(command).")
            }
        }

        return warnings
    }

    private func isValidProviderID(_ id: String) -> Bool {
        // Slug-style IDs avoid collisions and keep threshold keys predictable.
        regexCaptureGroups(pattern: "^[a-z0-9][a-z0-9._-]*$", in: id.lowercased()) != nil
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
