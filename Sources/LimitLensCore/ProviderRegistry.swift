/*
This file defines provider registration and ordering policy for LimitLens. It gives the
system a stable built-in provider set while allowing additional providers to be added
incrementally without rewriting snapshot orchestration.

It exists separately because provider identity and adapter wiring are architectural
concerns, not parser concerns. Keeping registry behavior centralized prevents ordering
and naming drift across CLI and menu bar surfaces.

This file talks to `ProviderAdapter`, `ProviderName`, and `ProviderSnapshot` by producing
default adapters and sorting snapshots using one shared ordering contract.
*/

import Foundation

public enum ProviderRegistry {
    public static let builtInDescriptors: [ProviderDescriptor] = [
        ProviderDescriptor(id: ProviderName.codex.rawValue, displayName: "Codex", shortLabel: "Cdx"),
        ProviderDescriptor(id: ProviderName.claude.rawValue, displayName: "Claude", shortLabel: "Cla"),
        ProviderDescriptor(id: ProviderName.antigravity.rawValue, displayName: "Antigravity", shortLabel: "AG"),
    ]

    public static func descriptor(for provider: ProviderName) -> ProviderDescriptor {
        if let found = builtInDescriptors.first(where: { $0.id == provider.rawValue }) {
            return found
        }

        return ProviderDescriptor(
            id: provider.rawValue,
            displayName: provider.defaultDisplayName,
            shortLabel: String(provider.defaultDisplayName.prefix(3))
        )
    }

    public static func defaultAdapters() -> [any ProviderAdapter] {
        // This list is the only place built-in adapter composition is declared.
        [
            CodexAdapter(),
            ClaudeAdapter(),
            AntigravityAdapter(),
        ]
    }

    public static func sortSnapshots(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.sorted { lhs, rhs in
            lhs.provider < rhs.provider
        }
    }
}
