/*
This file implements threshold crossing policy for LimitLens. It decides when a
provider's current pressure has crossed user-defined boundaries and enforces cooldown
behavior to prevent alert spam.

It exists separately because threshold evaluation is product policy, not parsing or UI.
Keeping policy in one place makes behavior predictable across CLI and menu bar surfaces.

This file talks to snapshot models for observed values, settings for threshold rules,
and runtime state persistence for hysteresis/cooldown memory between refresh cycles.
*/

import Foundation

public enum ThresholdEngine {
    public static func evaluate(
        snapshot: GlobalSnapshot,
        settings: LimitLensSettings,
        state: inout ThresholdRuntimeState,
        now: Date = Date()
    ) -> [ThresholdEvent] {
        var events: [ThresholdEvent] = []
        let cooldownSeconds = TimeInterval(settings.notificationCooldownMinutes * 60)

        for providerSnapshot in snapshot.providers {
            guard let pressure = providerSnapshot.pressurePercent else {
                // If a provider has no usable pressure metric, we skip crossing logic.
                continue
            }

            let provider = providerSnapshot.provider
            let providerKey = provider.rawValue
            let currentPercent = safePercent(pressure)
            let previousPercent = state.lastPercentByProvider[providerKey] ?? -1

            // We only trigger on upward crossing so steady high values do not retrigger.
            for threshold in settings.thresholds(for: provider) {
                let crossedUpward = previousPercent < Double(threshold) && currentPercent >= Double(threshold)
                guard crossedUpward else {
                    continue
                }

                let stateKey = providerThresholdKey(provider: provider, threshold: threshold)
                if let lastNotified = state.lastNotifiedByProviderThreshold[stateKey] {
                    let cooldownOpen = now.timeIntervalSince(lastNotified) >= cooldownSeconds
                    guard cooldownOpen else {
                        continue
                    }
                }

                events.append(
                    ThresholdEvent(
                        provider: provider,
                        threshold: threshold,
                        observedPercent: currentPercent,
                        triggeredAt: now
                    )
                )
                state.lastNotifiedByProviderThreshold[stateKey] = now
            }

            // Updating this baseline enables natural hysteresis through crossing checks.
            state.lastPercentByProvider[providerKey] = currentPercent
        }

        return events
    }
}
