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

    public static func builtInAdapters() -> [any ProviderAdapter] {
        // This list is the only place built-in adapter composition is declared.
        [
            CodexAdapter(),
            ClaudeAdapter(),
            AntigravityAdapter(),
        ]
    }

    public static func adapters(for settings: LimitLensSettings) -> [any ProviderAdapter] {
        let builtIns = builtInAdapters()
        return builtIns + externalAdapters(for: settings, reservedIDs: Set(builtIns.map(\.descriptor.id)))
    }

    public static func externalAdapters(
        for settings: LimitLensSettings,
        reservedIDs: Set<String>
    ) -> [any ProviderAdapter] {
        guard settings.allowExternalProviderCommands else {
            return []
        }

        var adapters: [any ProviderAdapter] = []
        var claimedIDs = Set(reservedIDs.map { $0.lowercased() })
        let fileManager = FileManager.default

        for definition in settings.externalProviders {
            let id = definition.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = definition.command.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !id.isEmpty, !command.isEmpty else {
                continue
            }

            guard isValidProviderID(id) else {
                continue
            }

            let dedupeID = id.lowercased()
            // First entry wins to keep duplicate ID behavior deterministic.
            guard !claimedIDs.contains(dedupeID) else {
                continue
            }

            // External commands must be absolute and executable to reduce injection risk.
            guard command.hasPrefix("/"), fileManager.isExecutableFile(atPath: command) else {
                continue
            }

            adapters.append(ExternalCommandProviderAdapter(definition: definition))
            claimedIDs.insert(dedupeID)
        }

        return adapters
    }

    public static func sortSnapshots(_ snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.sorted { lhs, rhs in
            lhs.provider < rhs.provider
        }
    }
}

private func isValidProviderID(_ id: String) -> Bool {
    regexCaptureGroups(pattern: "^[a-z0-9][a-z0-9._-]*$", in: id.lowercased()) != nil
}
