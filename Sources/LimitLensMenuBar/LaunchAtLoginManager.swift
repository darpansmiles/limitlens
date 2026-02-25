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

enum LaunchAtLoginResult {
    case success
    case failure(String)
}

final class LaunchAtLoginManager {
    private let fileManager = FileManager.default
    private let label = "com.limitlens.menubar"
    private let userID = String(getuid())

    var launchAgentURL: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    func isEnabled() -> Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool, executablePath: String?) -> LaunchAtLoginResult {
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
            "StandardOutPath": fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/LimitLens.launchd.log").path,
            "StandardErrorPath": fileManager.homeDirectoryForCurrentUser
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
        _ = ProcessSupport.run(
            executable: "launchctl",
            arguments: ["bootout", "gui/\(userID)", launchAgentURL.path]
        )

        let bootstrap = ProcessSupport.run(
            executable: "launchctl",
            arguments: ["bootstrap", "gui/\(userID)", launchAgentURL.path]
        )

        guard bootstrap.exitCode == 0 else {
            let errorText = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure("launchctl bootstrap failed: \(errorText.isEmpty ? "unknown error" : errorText)")
        }

        return .success
    }

    private func removeLaunchAgent() -> LaunchAtLoginResult {
        _ = ProcessSupport.run(
            executable: "launchctl",
            arguments: ["bootout", "gui/\(userID)", launchAgentURL.path]
        )

        if fileManager.fileExists(atPath: launchAgentURL.path) {
            do {
                try fileManager.removeItem(at: launchAgentURL)
            } catch {
                return .failure("Unable to remove launch agent plist: \(error.localizedDescription)")
            }
        }

        return .success
    }
}
