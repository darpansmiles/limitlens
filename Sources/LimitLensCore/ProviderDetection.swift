/*
This file translates provider snapshots into first-run onboarding detection signals.
It gives both CLI and menu bar surfaces one shared interpretation of "detected" vs
"not detected" so onboarding language stays consistent.

It exists separately because onboarding detection is presentation support policy, not
provider parsing. Keeping this logic in core avoids duplicating fragile heuristics
across interfaces.

This file talks to `GlobalSnapshot` and `ProviderSnapshot` by inspecting available
evidence and emitting normalized detection summaries for requested providers.
*/

import Foundation

public struct ProviderDetectionStatus: Sendable {
    public let provider: ProviderName
    public let displayName: String
    public let detected: Bool
    public let details: String

    public init(provider: ProviderName, displayName: String, detected: Bool, details: String) {
        self.provider = provider
        self.displayName = displayName
        self.detected = detected
        self.details = details
    }
}

public enum ProviderDetectionEvaluator {
    public static func evaluate(
        snapshot: GlobalSnapshot,
        providers: [ProviderName] = ProviderName.builtInOrder
    ) -> [ProviderDetectionStatus] {
        providers.map { provider in
            detectionStatus(for: provider, snapshot: snapshot)
        }
    }

    private static func detectionStatus(for provider: ProviderName, snapshot: GlobalSnapshot) -> ProviderDetectionStatus {
        guard let providerSnapshot = snapshot.provider(provider) else {
            return ProviderDetectionStatus(
                provider: provider,
                displayName: provider.defaultDisplayName,
                detected: false,
                details: "no snapshot evidence"
            )
        }

        var evidence: [String] = []

        // We treat explicit version metadata as strong proof that the provider runtime is present.
        if let appVersion = providerSnapshot.appVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !appVersion.isEmpty {
            evidence.append("version \(appVersion)")
        }

        if providerSnapshot.currentUsagePercent != nil {
            evidence.append("usage signal")
        }
        if providerSnapshot.tokenUsage != nil {
            evidence.append("token metrics")
        }
        if providerSnapshot.contextUsage != nil {
            evidence.append("context metrics")
        }
        if !providerSnapshot.historicalSignals.isEmpty {
            evidence.append("historical signal")
        }
        if !providerSnapshot.sourceFiles.isEmpty {
            evidence.append("local source files")
        }

        // Even without explicit metrics, a non-unavailable confidence with no hard errors is usable evidence.
        if evidence.isEmpty, providerSnapshot.confidence != .unavailable, providerSnapshot.errors.isEmpty {
            evidence.append("provider reachable")
        }

        let detected = !evidence.isEmpty
        if detected {
            return ProviderDetectionStatus(
                provider: provider,
                displayName: providerSnapshot.providerDisplayName,
                detected: true,
                details: evidence.joined(separator: ", ")
            )
        }

        let details = providerSnapshot.errors.first ?? "no provider data in configured paths"
        return ProviderDetectionStatus(
            provider: provider,
            displayName: providerSnapshot.providerDisplayName,
            detected: false,
            details: details
        )
    }
}
