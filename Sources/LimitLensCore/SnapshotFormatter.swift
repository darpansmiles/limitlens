/*
This file renders normalized snapshots into user-facing text forms. It centralizes
human-readable formatting and JSON serialization so every interface communicates status
with consistent language and timestamp conventions.

It exists separately because presentation policy should not be embedded in adapters
or runtime loops. Centralized formatters make it easy to evolve output style without
changing parsing or threshold logic.

This file talks to snapshot models for raw values and emits either terminal prose,
JSON output, or compact status summaries suitable for menu bar labels.
*/

import Foundation

public enum SnapshotFormatter {
    public static func renderJSON(_ snapshot: GlobalSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(snapshot) else {
            return "{}\n"
        }

        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    public static func renderHuman(_ snapshot: GlobalSnapshot) -> String {
        var lines: [String] = []
        lines.append("LimitLens Snapshot: \(dualTimestamp(snapshot.capturedAt)) (\(relativeAge(from: snapshot.capturedAt)))")
        lines.append("")

        for provider in snapshot.providers {
            lines.append(renderProvider(provider))
        }

        lines.append("")
        lines.append("Note: exact remaining quota is only shown when provider logs expose it.")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func compactStatusText(_ snapshot: GlobalSnapshot) -> String {
        let codex = snapshot.provider(.codex)
        let claude = snapshot.provider(.claude)
        let antigravity = snapshot.provider(.antigravity)

        let codexText: String
        if let percent = codex?.pressurePercent {
            codexText = "Cdx \(Int(percent.rounded()))%"
        } else {
            codexText = "Cdx -"
        }

        let claudeText: String
        if let percent = claude?.pressurePercent {
            claudeText = "Cla \(Int(percent.rounded()))%"
        } else {
            claudeText = "Cla -"
        }

        let antigravityText: String
        if let signal = antigravity?.historicalSignals.first {
            antigravityText = "AG !"
            _ = signal // Keeps intent explicit: AG indicator turns warning on historical rate-limit.
        } else {
            antigravityText = "AG ok"
        }

        return "\(codexText) | \(claudeText) | \(antigravityText)"
    }

    private static func renderProvider(_ provider: ProviderSnapshot) -> String {
        var lines: [String] = []
        lines.append("\(provider.provider.rawValue.capitalized):")

        let pressureText: String
        if let pressure = provider.pressurePercent {
            pressureText = "\(String(format: "%.2f", pressure))%"
        } else {
            pressureText = "n/a"
        }

        lines.append("  current status: \(provider.currentStatusSummary), pressure=\(pressureText)")

        if let reset = provider.windowResetAt {
            lines.append("  window reset: \(dualTimestamp(reset)) (\(relativeAge(from: reset, futureLabel: "in")))")
        } else {
            lines.append("  window reset: n/a")
        }

        if let latestSignal = provider.historicalSignals.sorted(by: { $0.observedAt > $1.observedAt }).first {
            lines.append("  historical signal: \(latestSignal.kind) at \(dualTimestamp(latestSignal.observedAt)) (\(relativeAge(from: latestSignal.observedAt)))")
        } else {
            lines.append("  historical signal: none")
        }

        return lines.joined(separator: "\n")
    }
}
