/*
This file manages launch-at-login behavior for the menu bar executable. It uses a user
LaunchAgent plist so the app can auto-start even when running outside an app bundle.

It exists separately because startup registration is a system-integration concern with
stateful side effects that should remain isolated from menu and snapshot logic.

This file talks to `LimitLensSettings` via the menu layer, and it talks to the local
filesystem and `launchctl` command to install, reload, or remove LaunchAgent entries.
*/

import Foundation
import LimitLensCore

final class LaunchAtLoginManager {
    private let fileManager = FileManager.default
    private let label = "com.limitlens.menubar"

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

    func setEnabled(_ enabled: Bool, executablePath: String) {
        if enabled {
            installLaunchAgent(executablePath: executablePath)
        } else {
            removeLaunchAgent()
        }
    }

    private func installLaunchAgent(executablePath: String) {
        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

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
            return
        }

        try? data.write(to: launchAgentURL, options: .atomic)

        // We unload first so repeated updates replace older registration cleanly.
        _ = ProcessSupport.run(executable: "launchctl", arguments: ["unload", launchAgentURL.path])
        _ = ProcessSupport.run(executable: "launchctl", arguments: ["load", launchAgentURL.path])
    }

    private func removeLaunchAgent() {
        _ = ProcessSupport.run(executable: "launchctl", arguments: ["unload", launchAgentURL.path])
        try? fileManager.removeItem(at: launchAgentURL)
    }
}
