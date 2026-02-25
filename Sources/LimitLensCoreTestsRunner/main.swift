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
            try Self.expect(higher.map(\.threshold) == [75, 80], "Expected 75 and 80 to trigger on upward crossing")
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
}

private var runner = CoreTestsRunner()
runner.runAll()

print("\nResult: \(runner.passed) passed, \(runner.failed) failed")
exit(runner.failed == 0 ? 0 : 1)
