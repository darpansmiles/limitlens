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
        ensureStorageDirectory()
        let url = settingsFileURL()

        guard let data = try? Data(contentsOf: url) else {
            // First run path: persist defaults so users can edit immediately.
            saveSettings(.default)
            return .default
        }

        guard let decoded = try? decoder.decode(LimitLensSettings.self, from: data) else {
            // Corrupted settings fallback keeps the app alive and rewrites clean defaults.
            saveSettings(.default)
            return .default
        }

        return decoded
    }

    public func saveSettings(_ settings: LimitLensSettings) {
        ensureStorageDirectory()
        guard let encoded = try? encoder.encode(settings) else {
            return
        }
        atomicWrite(encoded, to: settingsFileURL())
    }

    public func loadRuntimeState() -> ThresholdRuntimeState {
        ensureStorageDirectory()
        let url = runtimeStateFileURL()

        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }

        return (try? decoder.decode(ThresholdRuntimeState.self, from: data)) ?? .empty
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
}
