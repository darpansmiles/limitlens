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

    public static func renderFirstRunWelcome(_ snapshot: GlobalSnapshot) -> String {
        let detection = ProviderDetectionEvaluator.evaluate(snapshot: snapshot)
        var lines: [String] = []

        lines.append("┌────────────────────────────────────────────────────────────────────────┐")
        lines.append("│ Welcome to LimitLens                                                  │")
        lines.append("│ Local provider detection (first run):                                │")
        for status in detection {
            let marker = status.detected ? "✓" : "✗"
            let message = status.detected
                ? "\(status.displayName) detected"
                : "\(status.displayName) not found"
            lines.append("│ \(marker) \(message)".padRight(to: 70) + " │")
        }
        lines.append("│                                                                        │")
        lines.append("│ Severity color map: green=normal, amber=warning, red=critical,        │")
        lines.append("│ gray=unknown.                                                          │")
        lines.append("└────────────────────────────────────────────────────────────────────────┘")

        return lines.joined(separator: "\n") + "\n\n"
    }

    public static func compactStatusText(_ snapshot: GlobalSnapshot, settings: LimitLensSettings = .default) -> String {
        let ordered = ProviderRegistry.sortSnapshots(snapshot.providers)
        var segments: [String] = []

        for provider in ordered.prefix(3) {
            let severity = SeverityEvaluator.providerSeverity(for: provider, settings: settings)
            let label = provider.providerShortLabel.isEmpty ? provider.providerDisplayName : provider.providerShortLabel

            if let percent = provider.pressurePercent {
                segments.append("\(label) \(Int(percent.rounded()))%")
                continue
            }

            // Severity marker remains explicit even when exact pressure is unavailable.
            switch severity {
            case .critical:
                segments.append("\(label) !!")
            case .warning:
                segments.append("\(label) !")
            case .normal:
                segments.append("\(label) ok")
            case .unknown:
                segments.append("\(label) -")
            }
        }

        let remaining = max(0, ordered.count - 3)
        if remaining > 0 {
            segments.append("+\(remaining)")
        }

        return segments.joined(separator: " | ")
    }

    private static func renderProvider(_ provider: ProviderSnapshot) -> String {
        var lines: [String] = []
        lines.append("\(provider.providerDisplayName):")

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

        for error in provider.errors {
            lines.append("  error: \(error)")
        }

        if !provider.errors.isEmpty, let remediation = provider.remediation?.trimmingCharacters(in: .whitespacesAndNewlines), !remediation.isEmpty {
            lines.append("  Try: \(remediation)")
        }

        return lines.joined(separator: "\n")
    }
}

private extension String {
    func padRight(to width: Int) -> String {
        guard count < width else {
            return self
        }
        return self + String(repeating: " ", count: width - count)
    }
}
