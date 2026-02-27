/*
This file orchestrates provider adapters into one coherent snapshot. It is the service
layer that turns independent provider reads into a single system view at one capture time.

It exists separately because aggregation logic should stay independent from any specific
interface. Both CLI and menu bar runtime call this service and should always receive
identically shaped data.

This file talks to adapter implementations to collect provider snapshots and returns a
`GlobalSnapshot` that policy and presentation layers consume.
*/

import Foundation

public struct SnapshotService {
    private let builtInAdapters: [any ProviderAdapter]

    public init(adapters: [any ProviderAdapter] = ProviderRegistry.builtInAdapters()) {
        self.builtInAdapters = adapters
    }

    public func collectSnapshot(using settings: LimitLensSettings, now: Date = Date()) -> GlobalSnapshot {
        let reservedIDs = Set(builtInAdapters.map(\.descriptor.id))
        let allAdapters = builtInAdapters + ProviderRegistry.externalAdapters(for: settings, reservedIDs: reservedIDs)

        // Each provider is read independently so one parser failure cannot block the others.
        let collected = allAdapters.map { adapter in
            adapter.collect(using: settings)
        }.map { snapshot in
            var normalized = snapshot
            // If adapters report errors without guidance, we attach a generic fallback fix path.
            if !normalized.errors.isEmpty, normalized.remediation == nil {
                normalized.remediation = "Open LimitLens settings and verify the provider source path."
            }
            return normalized
        }

        return GlobalSnapshot(capturedAt: now, providers: ProviderRegistry.sortSnapshots(collected))
    }
}
