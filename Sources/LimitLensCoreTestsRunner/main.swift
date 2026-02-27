/*
This file is a lightweight unit-test harness for the shared core package. It runs
parser-fixture checks and threshold-policy checks without depending on XCTest,
which keeps verification portable in constrained local toolchains.

It exists as a separate executable because runtime validation should be callable from
CI and local terminals as a single command while remaining independent from product
binaries.

This file talks to parser and policy APIs in `LimitLensCore` and consumes fixture
resources bundled under `Sources/LimitLensCoreTestsRunner/Fixtures`.
*/

import Foundation
import LimitLensCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct CoreTestsRunner {
    private(set) var passed = 0
    private(set) var failed = 0

    mutating func runAll() {
        run("Codex parser extracts usage and reset") {
            let fixture = try Self.fixture(named: "codex_token_count.jsonl")
            let parsed = ProviderParsing.parseCodexSessionTail(fixture)

            try Self.expect(parsed.tokenUsage?.inputTokens == 57_719, "Expected input token count 57,719")
            try Self.expect(parsed.tokenUsage?.outputTokens == 122, "Expected output token count 122")
            try Self.expect(parsed.contextWindow == 258_400, "Expected model context window 258,400")

            let usagePercent = parsed.usagePercent ?? -1
            try Self.expect(abs(usagePercent - 5.0) < 0.0001, "Expected used_percent close to 5.0")

            let resetEpoch = parsed.resetAt?.timeIntervalSince1970 ?? -1
            try Self.expect(abs(resetEpoch - 1_761_430_774) < 0.001, "Expected reset epoch 1761430774")
        }

        run("Codex parser handles malformed lines safely") {
            let fixture = try Self.fixture(named: "codex_malformed.jsonl")
            let parsed = ProviderParsing.parseCodexSessionTail(fixture)

            try Self.expect(parsed.tokenUsage == nil, "Malformed fixture should not produce token usage")
            try Self.expect(parsed.usagePercent == nil, "Malformed fixture should not produce usage percent")
            try Self.expect(parsed.resetAt == nil, "Malformed fixture should not produce reset timestamp")
            try Self.expect(parsed.contextWindow == nil, "Malformed fixture should not produce context window")
        }

        run("Claude parser prefers latest non-zero usage") {
            let fixture = try Self.fixture(named: "claude_usage.jsonl")
            let usage = ProviderParsing.parseClaudeConversationTail(fixture)

            try Self.expect(usage?.inputTokens == 3, "Expected input token count 3")
            try Self.expect(usage?.outputTokens == 9, "Expected output token count 9")
        }

        run("Claude log parser extracts autocompact usage") {
            let fixture = try Self.fixture(named: "claude_log.txt")
            let context = ProviderParsing.parseClaudeContextUsage(from: fixture)

            try Self.expect(context?.tokens == 78_436, "Expected autocompact tokens 78,436")
            try Self.expect(context?.threshold == 167_000, "Expected autocompact threshold 167,000")

            let percent = context?.percentUsed ?? -1
            try Self.expect(abs(percent - 46.967664670658685) < 0.0001, "Expected autocompact percent near 46.9677")
        }

        run("Rate-limit parser captures newest matching signal") {
            let fixture = try Self.fixture(named: "claude_log.txt")
            let signal = ProviderParsing.parseLatestRateLimitSignal(from: fixture, kind: "claude_rate_limit")

            try Self.expect(signal?.kind == "claude_rate_limit", "Expected signal kind claude_rate_limit")
            try Self.expect(signal?.details != nil, "Expected captured signal details")

            let expected = parseLogTimestamp(from: "2026-02-25 13:02:04.462 [error] synthetic")
            try Self.expect(signal?.observedAt == expected, "Expected parsed timestamp anchored to matching line")
        }

        run("Rate-limit parser returns nil when no evidence exists") {
            let fixture = try Self.fixture(named: "no_rate_limit.log")
            let signal = ProviderParsing.parseLatestRateLimitSignal(from: fixture, kind: "none")

            try Self.expect(signal == nil, "Expected nil when no rate-limit line exists")
        }

        run("Rate-limit parser ignores noisy lines without trusted timestamps") {
            let log = """
            random telemetry 429 value
            this mentions rate limit but has no timestamp
            """
            let signal = ProviderParsing.parseLatestRateLimitSignal(from: log, kind: "none")
            try Self.expect(signal == nil, "Expected nil when timestamp is missing")
        }

        run("Threshold engine triggers only on upward crossing") {
            var state = ThresholdRuntimeState.empty
            let settings = Self.makeSettings(defaultThresholds: [70, 75, 80], cooldownMinutes: 30)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let first = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 72, now: now),
                settings: settings,
                state: &state,
                now: now
            )
            try Self.expect(first.map(\.threshold) == [70], "Expected first crossing to trigger threshold 70")

            let sameValue = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 72, now: now.addingTimeInterval(30)),
                settings: settings,
                state: &state,
                now: now.addingTimeInterval(30)
            )
            try Self.expect(sameValue.isEmpty, "Expected no retrigger at same pressure")

            let higher = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 82, now: now.addingTimeInterval(60)),
                settings: settings,
                state: &state,
                now: now.addingTimeInterval(60)
            )
            try Self.expect(higher.map(\.threshold) == [80], "Expected coalesced event at highest crossed threshold")
        }

        run("Threshold engine enforces cooldown and rearms after drop") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var state = ThresholdRuntimeState(
                lastPercentByProvider: [ProviderName.codex.rawValue: 60],
                lastNotifiedByProviderThreshold: [
                    providerThresholdKey(provider: .codex, threshold: 70): now,
                ]
            )

            let settings = Self.makeSettings(defaultThresholds: [70], cooldownMinutes: 30)

            let blockedByCooldown = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 71, now: now.addingTimeInterval(60)),
                settings: settings,
                state: &state,
                now: now.addingTimeInterval(60)
            )
            try Self.expect(blockedByCooldown.isEmpty, "Expected cooldown to block early retrigger")

            // Dropping below threshold re-arms the upward crossing condition.
            _ = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 65, now: now.addingTimeInterval(120)),
                settings: settings,
                state: &state,
                now: now.addingTimeInterval(120)
            )

            let afterCooldown = ThresholdEngine.evaluate(
                snapshot: Self.snapshot(provider: .codex, pressure: 75, now: now.addingTimeInterval(1_900)),
                settings: settings,
                state: &state,
                now: now.addingTimeInterval(1_900)
            )
            try Self.expect(afterCooldown.count == 1, "Expected one event after cooldown and re-arm")
            try Self.expect(afterCooldown.first?.threshold == 70, "Expected threshold 70 to fire")
        }

        run("Threshold engine skips providers without pressure metrics") {
            var state = ThresholdRuntimeState.empty
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let provider = ProviderSnapshot(
                provider: .antigravity,
                confidence: .low,
                currentStatusSummary: "No pressure metric",
                historicalSignals: [],
                sourceFiles: [],
                errors: []
            )

            let events = ThresholdEngine.evaluate(
                snapshot: GlobalSnapshot(capturedAt: now, providers: [provider]),
                settings: Self.makeSettings(defaultThresholds: [70], cooldownMinutes: 30),
                state: &state,
                now: now
            )

            try Self.expect(events.isEmpty, "Expected no events when pressure is unavailable")
        }

        run("Severity evaluator uses configured thresholds") {
            var settings = Self.makeSettings(defaultThresholds: [50, 90], cooldownMinutes: 30)
            settings.perProviderThresholds[ProviderName.claude.rawValue] = [40, 85]

            let warningSnapshot = ProviderSnapshot(
                provider: .codex,
                confidence: .high,
                currentUsagePercent: 52,
                currentStatusSummary: "52%",
                historicalSignals: [],
                sourceFiles: [],
                errors: []
            )

            let criticalSnapshot = ProviderSnapshot(
                provider: .claude,
                confidence: .high,
                currentUsagePercent: 90,
                currentStatusSummary: "90%",
                historicalSignals: [],
                sourceFiles: [],
                errors: []
            )

            try Self.expect(
                SeverityEvaluator.providerSeverity(for: warningSnapshot, settings: settings) == .warning,
                "Expected warning at configured lower threshold"
            )
            try Self.expect(
                SeverityEvaluator.providerSeverity(for: criticalSnapshot, settings: settings) == .critical,
                "Expected critical at configured highest threshold"
            )
        }

        run("Settings store preserves corrupt settings backup") {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = SettingsStore(rootDirectory: directory)
            store.ensureStorageDirectory()

            let corruptSettings = "{ not valid json ]"
            let settingsURL = store.settingsFileURL()
            try corruptSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

            let loaded = store.loadSettingsWithDiagnostics()
            try Self.expect(!loaded.warnings.isEmpty, "Expected warnings for corrupt settings file")
            try Self.expect(loaded.settings.defaultThresholds == LimitLensSettings.default.defaultThresholds, "Expected default settings after recovery")

            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let hasBackup = entries.contains(where: { $0.hasPrefix("settings.corrupt.") && $0.hasSuffix(".json") })
            try Self.expect(hasBackup, "Expected backup copy of corrupt settings file")
        }

        run("latestDirectory resolves by modification date") {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let older = directory.appendingPathComponent("z-old")
            let newer = directory.appendingPathComponent("a-new")
            try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)

            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)

            let latest = FileSystemSupport.latestDirectory(in: directory.path)
            try Self.expect(latest?.lastPathComponent == "a-new", "Expected latest directory to follow mtime")
        }

        run("Claude adapter discovers logs across non-window1 directories") {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let logFile = directory
                .appendingPathComponent("2026-02-25")
                .appendingPathComponent("window2")
                .appendingPathComponent("exthost")
                .appendingPathComponent("Anthropic.claude-code")
                .appendingPathComponent("Claude VSCode.log")

            try FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "2026-02-25 13:02:04.462 [info] autocompact: tokens=100 threshold=200".write(
                to: logFile,
                atomically: true,
                encoding: .utf8
            )

            var settings = LimitLensSettings.default
            settings.claudeProjectsPath = directory.path
            settings.antigravityLogsPath = directory.path

            let snapshot = ClaudeAdapter().collect(using: settings)
            try Self.expect(snapshot.contextUsage?.tokens == 100, "Expected context parser to read window2 log")
            try Self.expect(
                snapshot.sourceFiles.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "Claude VSCode.log" }),
                "Expected discovered source path to include Claude VSCode.log"
            )
        }

        run("External command providers are loaded at runtime") {
            let payload = #"{"confidence":"high","currentUsagePercent":64.5,"currentStatusSummary":"Runtime provider ok"}"#
            let adapter = ExternalCommandProviderAdapter(
                definition: ExternalProviderDefinition(
                    id: "runtime_provider",
                    displayName: "Runtime Provider",
                    shortLabel: "Run",
                    command: "/bin/echo",
                    arguments: [payload],
                    timeoutSeconds: 2
                )
            )

            let snapshot = adapter.collect(using: .default)
            try Self.expect(snapshot.provider.rawValue == "runtime_provider", "Expected custom provider ID")
            try Self.expect(abs((snapshot.currentUsagePercent ?? 0) - 64.5) < 0.001, "Expected custom pressure from command payload")
            try Self.expect(snapshot.currentStatusSummary == "Runtime provider ok", "Expected custom status summary")
        }

        run("External provider adapters require explicit allow flag and dedupe IDs") {
            var settings = LimitLensSettings.default
            settings.externalProviders = [
                ExternalProviderDefinition(
                    id: "dup",
                    displayName: "Duplicate 1",
                    shortLabel: "D1",
                    command: "/bin/echo"
                ),
                ExternalProviderDefinition(
                    id: "Dup",
                    displayName: "Duplicate 2",
                    shortLabel: "D2",
                    command: "/bin/echo"
                ),
                ExternalProviderDefinition(
                    id: "badcmd",
                    displayName: "Bad Command",
                    shortLabel: "Bad",
                    command: "echo"
                ),
            ]

            let disabled = ProviderRegistry.externalAdapters(for: settings, reservedIDs: [])
            try Self.expect(disabled.isEmpty, "Expected external adapters disabled by default")

            settings.allowExternalProviderCommands = true
            let enabled = ProviderRegistry.externalAdapters(for: settings, reservedIDs: [])
            try Self.expect(enabled.count == 1, "Expected one surviving external adapter after validation and dedupe")
            try Self.expect(enabled.first?.descriptor.id == "dup", "Expected first duplicate ID to win")
        }

        run("Settings decode salvages valid fields when one field has wrong type") {
            let directory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let store = SettingsStore(rootDirectory: directory)
            store.ensureStorageDirectory()

            let partialBadJSON = """
            {
              "codexSessionsPath": "~/custom-codex",
              "refreshIntervalSeconds": "oops",
              "defaultThresholds": [65, 85]
            }
            """
            try partialBadJSON.write(to: store.settingsFileURL(), atomically: true, encoding: .utf8)

            let loaded = store.loadSettingsWithDiagnostics()
            try Self.expect(loaded.settings.codexSessionsPath == "~/custom-codex", "Expected valid codexSessionsPath to be preserved")
            try Self.expect(loaded.settings.refreshIntervalSeconds == LimitLensSettings.default.refreshIntervalSeconds, "Expected invalid interval to fall back to default")
            try Self.expect(loaded.settings.defaultThresholds == [65, 85], "Expected valid thresholds to remain intact")
        }

        run("Provider detection evaluator reports detected and missing providers") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let snapshot = GlobalSnapshot(
                capturedAt: now,
                providers: [
                    ProviderSnapshot(
                        provider: .codex,
                        confidence: .medium,
                        appVersion: "1.2.3",
                        currentStatusSummary: "version 1.2.3",
                        sourceFiles: [],
                        errors: []
                    ),
                    ProviderSnapshot(
                        provider: .claude,
                        confidence: .unavailable,
                        currentStatusSummary: "No current metrics",
                        sourceFiles: [],
                        errors: ["No Claude data sources found"],
                        remediation: "Set paths in settings."
                    ),
                    ProviderSnapshot(
                        provider: .antigravity,
                        confidence: .low,
                        currentStatusSummary: "version 1.0.0",
                        sourceFiles: ["/tmp/Codex.log"],
                        errors: []
                    ),
                ]
            )

            let detection = ProviderDetectionEvaluator.evaluate(snapshot: snapshot)
            try Self.expect(detection.count == 3, "Expected built-in detection entries")
            try Self.expect(detection[0].provider == .codex && detection[0].detected, "Expected codex to be detected")
            try Self.expect(detection[1].provider == .claude && !detection[1].detected, "Expected claude to be not detected")
            try Self.expect(detection[2].provider == .antigravity && detection[2].detected, "Expected antigravity to be detected")
        }

        run("Snapshot service adds generic remediation when adapter omits it") {
            struct BrokenAdapter: ProviderAdapter {
                let descriptor = ProviderDescriptor(id: "broken", displayName: "Broken", shortLabel: "Brk")

                func collect(using settings: LimitLensSettings) -> ProviderSnapshot {
                    ProviderSnapshot(
                        provider: .custom("broken"),
                        providerDisplayName: "Broken",
                        providerShortLabel: "Brk",
                        confidence: .unavailable,
                        currentStatusSummary: "broken",
                        errors: ["No usable source"]
                    )
                }
            }

            let service = SnapshotService(adapters: [BrokenAdapter()])
            var settings = LimitLensSettings.default
            settings.allowExternalProviderCommands = false
            let snapshot = service.collectSnapshot(using: settings, now: Date(timeIntervalSince1970: 1_700_000_001))
            let broken = snapshot.provider(.custom("broken"))
            try Self.expect(broken != nil, "Expected broken provider snapshot")
            try Self.expect(
                broken?.remediation == "Open LimitLens settings and verify the provider source path.",
                "Expected generic remediation fallback"
            )
        }
    }

    private mutating func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("[PASS] \(name)")
        } catch {
            failed += 1
            print("[FAIL] \(name)")
            print("       \(error)")
        }
    }

    private static func fixture(named fileName: String) throws -> String {
        // SwiftPM may flatten processed resources, so we check both locations.
        let directURL = Bundle.module.url(forResource: fileName, withExtension: nil)
        let nestedURL = Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Fixtures")

        guard let url = directURL ?? nestedURL else {
            throw TestFailure(description: "Missing fixture: \(fileName)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure(description: message)
        }
    }

    private static func snapshot(provider: ProviderName, pressure: Double, now: Date) -> GlobalSnapshot {
        let providerSnapshot = ProviderSnapshot(
            provider: provider,
            confidence: .high,
            currentUsagePercent: pressure,
            currentStatusSummary: "\(pressure)% used",
            historicalSignals: [],
            sourceFiles: [],
            errors: []
        )

        return GlobalSnapshot(capturedAt: now, providers: [providerSnapshot])
    }

    private static func makeSettings(defaultThresholds: [Int], cooldownMinutes: Int) -> LimitLensSettings {
        var settings = LimitLensSettings.default
        settings.defaultThresholds = defaultThresholds
        settings.perProviderThresholds = [:]
        settings.notificationCooldownMinutes = cooldownMinutes
        return settings
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("limitlens-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}

private var runner = CoreTestsRunner()
runner.runAll()

print("\nResult: \(runner.passed) passed, \(runner.failed) failed")
exit(runner.failed == 0 ? 0 : 1)
