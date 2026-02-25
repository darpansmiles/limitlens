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
    private let codexAdapter: ProviderAdapter
    private let claudeAdapter: ProviderAdapter
    private let antigravityAdapter: ProviderAdapter

    public init(
        codexAdapter: ProviderAdapter = CodexAdapter(),
        claudeAdapter: ProviderAdapter = ClaudeAdapter(),
        antigravityAdapter: ProviderAdapter = AntigravityAdapter()
    ) {
        self.codexAdapter = codexAdapter
        self.claudeAdapter = claudeAdapter
        self.antigravityAdapter = antigravityAdapter
    }

    public func collectSnapshot(using settings: LimitLensSettings, now: Date = Date()) -> GlobalSnapshot {
        // Each provider is read independently so one parser failure cannot block the others.
        let codex = codexAdapter.collect(using: settings)
        let claude = claudeAdapter.collect(using: settings)
        let antigravity = antigravityAdapter.collect(using: settings)

        return GlobalSnapshot(capturedAt: now, providers: [codex, claude, antigravity])
    }
}
