/*
This file manages launch-at-login behavior for the menu bar executable. It uses a user
LaunchAgent plist so the app can auto-start even when running outside an app bundle.

It exists separately because startup registration is a system-integration concern with
stateful side effects that should remain isolated from menu and snapshot logic.

This file talks to `LimitLensSettings` via the menu layer, and it talks to the local
filesystem and `launchctl` command to install, reload, or remove LaunchAgent entries.
*/

import Darwin
import Foundation
import LimitLensCore

public enum LaunchAtLoginResult {
    case success
    case failure(String)
}

public final class LaunchAtLoginManager {
    public typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> ProcessResult

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let label: String
    private let userID: String
    private let commandRunner: CommandRunner

    public init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        label: String = "com.limitlens.menubar",
        userID: String = String(getuid()),
        commandRunner: @escaping CommandRunner = { executable, arguments in
            ProcessSupport.run(executable: executable, arguments: arguments)
        }
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.label = label
        self.userID = userID
        self.commandRunner = commandRunner
    }

    public var launchAgentURL: URL {
        homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    public func isEnabled() -> Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    public func setEnabled(_ enabled: Bool, executablePath: String?) -> LaunchAtLoginResult {
        if enabled {
            guard let executablePath else {
                return .failure("No stable executable path is available for launch-at-login.")
            }
            return installLaunchAgent(executablePath: executablePath)
        } else {
            return removeLaunchAgent()
        }
    }

    private func installLaunchAgent(executablePath: String) -> LaunchAtLoginResult {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure("Unable to create LaunchAgents directory: \(error.localizedDescription)")
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            // This keeps logs discoverable while debugging startup behavior.
            "StandardOutPath": homeDirectory
                .appendingPathComponent("Library/Logs/LimitLens.launchd.log").path,
            "StandardErrorPath": homeDirectory
                .appendingPathComponent("Library/Logs/LimitLens.launchd.err.log").path,
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            return .failure("Unable to serialize launch agent plist.")
        }

        do {
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            return .failure("Unable to write launch agent plist: \(error.localizedDescription)")
        }

        // We boot out first so repeated updates replace older registration cleanly.
        _ = runLaunchctl(arguments: ["bootout", "gui/\(userID)", launchAgentURL.path])

        let bootstrap = runLaunchctl(arguments: ["bootstrap", "gui/\(userID)", launchAgentURL.path])

        guard bootstrap.exitCode == 0 else {
            let errorText = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("launchctl bootstrap failed: \(errorText.isEmpty ? "unknown error" : errorText)")
        }

        return .success
    }

    private func removeLaunchAgent() -> LaunchAtLoginResult {
        _ = runLaunchctl(arguments: ["bootout", "gui/\(userID)", launchAgentURL.path])

        if fileManager.fileExists(atPath: launchAgentURL.path) {
            do {
                try fileManager.removeItem(at: launchAgentURL)
            } catch {
                return .failure("Unable to remove launch agent plist: \(error.localizedDescription)")
            }
        }

        return .success
    }

    private func runLaunchctl(arguments: [String]) -> ProcessResult {
        commandRunner("launchctl", arguments)
    }
}
