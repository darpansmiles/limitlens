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
    private let adapters: [any ProviderAdapter]

    public init(adapters: [any ProviderAdapter] = ProviderRegistry.defaultAdapters()) {
        self.adapters = adapters
    }

    public func collectSnapshot(using settings: LimitLensSettings, now: Date = Date()) -> GlobalSnapshot {
        // Each provider is read independently so one parser failure cannot block the others.
        let collected = adapters.map { adapter in
            adapter.collect(using: settings)
        }

        return GlobalSnapshot(capturedAt: now, providers: ProviderRegistry.sortSnapshots(collected))
    }
}
