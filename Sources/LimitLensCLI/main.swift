/*
This file is the production Swift CLI entrypoint for LimitLens. It parses terminal
arguments, resolves settings overrides, executes snapshot collection, and renders
output in either human-friendly or JSON form.

It exists separately because the CLI is a first-class interface with its own runtime
loop semantics (single-shot and watch mode). Keeping it isolated from the menu bar app
ensures terminal behavior stays predictable and scriptable.

This file talks to `SettingsStore` for persisted configuration, `SnapshotService` for
provider aggregation, and `SnapshotFormatter` for display output.
*/

import Foundation
import LimitLensCore

enum CLIError: Error, LocalizedError {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(String, String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let value):
            return "Unknown argument: \(value)"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "Invalid value for \(flag): \(value)"
        }
    }
}

struct CLIArguments {
    var json = false
    var watch = false
    var intervalSeconds: Int?
    var codexPath: String?
    var claudePath: String?
    var antigravityLogsPath: String?
    var help = false

    static func parse(_ values: [String]) throws -> CLIArguments {
        var args = CLIArguments()
        var index = 0

        while index < values.count {
            let current = values[index]
            switch current {
            case "-h", "--help":
                args.help = true
            case "--json":
                args.json = true
            case "--watch":
                args.watch = true
            case "--interval":
                guard index + 1 < values.count else {
                    throw CLIError.missingValue("--interval")
                }
                let value = values[index + 1]
                guard let parsed = Int(value), parsed > 0 else {
                    throw CLIError.invalidValue("--interval", value)
                }
                args.intervalSeconds = parsed
                index += 1
            case "--codex-path":
                guard index + 1 < values.count else {
                    throw CLIError.missingValue("--codex-path")
                }
                args.codexPath = values[index + 1]
                index += 1
            case "--claude-path":
                guard index + 1 < values.count else {
                    throw CLIError.missingValue("--claude-path")
                }
                args.claudePath = values[index + 1]
                index += 1
            case "--antigravity-logs-path":
                guard index + 1 < values.count else {
                    throw CLIError.missingValue("--antigravity-logs-path")
                }
                args.antigravityLogsPath = values[index + 1]
                index += 1
            default:
                throw CLIError.unknownArgument(current)
            }

            index += 1
        }

        return args
    }
}

@main
struct LimitLensCLI {
    static func main() {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.help {
                printHelp()
                return
            }

            let settingsStore = SettingsStore()
            let settingsResult = settingsStore.loadSettingsWithDiagnostics()
            var settings = settingsResult.settings
            for warning in settingsResult.warnings {
                fputs("warning: \(warning)\n", stderr)
            }

            // CLI flags override persisted settings for this process execution.
            if let codexPath = arguments.codexPath {
                settings.codexSessionsPath = codexPath
            }
            if let claudePath = arguments.claudePath {
                settings.claudeProjectsPath = claudePath
            }
            if let antigravityLogsPath = arguments.antigravityLogsPath {
                settings.antigravityLogsPath = antigravityLogsPath
            }
            if let interval = arguments.intervalSeconds {
                settings.refreshIntervalSeconds = interval
            }

            let snapshotService = SnapshotService()

            if arguments.watch {
                runWatchLoop(
                    settings: settings,
                    snapshotService: snapshotService,
                    json: arguments.json
                )
            } else {
                runOnce(settings: settings, snapshotService: snapshotService, json: arguments.json)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            printHelp()
            exit(1)
        }
    }

    private static func runWatchLoop(settings: LimitLensSettings, snapshotService: SnapshotService, json: Bool) {
        let interval = max(10, settings.refreshIntervalSeconds)

        while true {
            runOnce(settings: settings, snapshotService: snapshotService, json: json)
            // A fixed sleep keeps runtime behavior easy to reason about in terminal sessions.
            Thread.sleep(forTimeInterval: TimeInterval(interval))
        }
    }

    private static func runOnce(settings: LimitLensSettings, snapshotService: SnapshotService, json: Bool) {
        let snapshot = snapshotService.collectSnapshot(using: settings)
        if json {
            print(SnapshotFormatter.renderJSON(snapshot), terminator: "")
        } else {
            print(SnapshotFormatter.renderHuman(snapshot), terminator: "")
        }
    }

    private static func printHelp() {
        let text = """
        LimitLens CLI

        Usage:
          limitlens [--json] [--watch] [--interval 60]
                    [--codex-path PATH] [--claude-path PATH]
                    [--antigravity-logs-path PATH]

        Examples:
          limitlens
          limitlens --json
          limitlens --watch --interval 30
        """
        print(text)
    }
}
