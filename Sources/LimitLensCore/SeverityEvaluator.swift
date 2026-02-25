/*
This file defines shared severity semantics for provider and global status evaluation.
It ensures CLI text, menu visuals, and compact badges all interpret pressure and
historical signals using the same rules.

It exists separately because severity policy is product meaning. If each UI surface
implements its own warning logic, users receive contradictory signals.

This file talks to `ProviderSnapshot` and `GlobalSnapshot` models and is consumed by
formatters and the menu bar runtime.
*/

import Foundation

public enum SeverityLevel: String, Codable, Comparable, Sendable {
    case unknown
    case normal
    case warning
    case critical

    public static func < (lhs: SeverityLevel, rhs: SeverityLevel) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: SeverityLevel) -> Int {
        switch value {
        case .unknown:
            return 0
        case .normal:
            return 1
        case .warning:
            return 2
        case .critical:
            return 3
        }
    }
}

public enum SeverityEvaluator {
    public static func providerSeverity(
        for snapshot: ProviderSnapshot,
        now: Date = Date(),
        historicalSignalFreshnessSeconds: TimeInterval = 3_600
    ) -> SeverityLevel {
        if let pressure = snapshot.pressurePercent {
            if pressure >= 95 {
                return .critical
            }
            if pressure >= 80 {
                return .warning
            }
            return .normal
        }

        // Historical signals only count as warnings when recent enough to be actionable.
        let hasRecentSignal = snapshot.historicalSignals.contains { signal in
            now.timeIntervalSince(signal.observedAt) <= historicalSignalFreshnessSeconds
        }

        return hasRecentSignal ? .warning : .unknown
    }

    public static func globalSeverity(
        for snapshot: GlobalSnapshot,
        now: Date = Date(),
        historicalSignalFreshnessSeconds: TimeInterval = 3_600
    ) -> SeverityLevel {
        snapshot.providers
            .map { providerSeverity(for: $0, now: now, historicalSignalFreshnessSeconds: historicalSignalFreshnessSeconds) }
            .max() ?? .unknown
    }
}
