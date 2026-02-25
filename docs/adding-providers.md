# Adding Providers Incrementally

LimitLens now supports incremental provider growth through a registry + adapter model.

## Core Contract

A provider is defined by two things:

1. A `ProviderDescriptor` (`id`, `displayName`, `shortLabel`).
2. A type conforming to `ProviderAdapter`.

`ProviderAdapter` is in `Sources/LimitLensCore/ProviderAdapters.swift`.

## Minimal Steps

1. Create a new adapter in `Sources/LimitLensCore/`.
2. Give it a unique slug-style descriptor ID (for example `gemini` or `cursor`).
3. Return a `ProviderSnapshot` with confidence, status, optional pressure, and signals.
4. Register the adapter in `ProviderRegistry.defaultAdapters()`.

Because provider IDs are extensible (`ProviderName.custom(...)`), new IDs do not require changing core enums.

## Optional Threshold Overrides

Per-provider overrides use `settings.json` key `perProviderThresholds` keyed by provider ID.

Example:

```json
{
  "perProviderThresholds": {
    "gemini": [70, 85, 95]
  }
}
```

The settings window preserves unknown provider overrides even if it does not yet expose dedicated controls.

## Validation

After adding a provider:

```bash
swift build
swift run limitlens-core-tests
swift run limitlens
```
