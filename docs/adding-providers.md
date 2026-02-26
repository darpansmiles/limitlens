# Adding Providers Incrementally

LimitLens supports two extension paths:

1. Compile-time adapters for first-class provider integrations.
2. Runtime command adapters through `settings.json` with no recompile.

## Core Contract

A provider is defined by two things:

1. A `ProviderDescriptor` (`id`, `displayName`, `shortLabel`).
2. A type conforming to `ProviderAdapter`.

`ProviderAdapter` is in `Sources/LimitLensCore/ProviderAdapters.swift`.

## Minimal Steps

1. Create a new adapter in `Sources/LimitLensCore/`.
2. Give it a unique slug-style descriptor ID (for example `gemini` or `cursor`).
3. Return a `ProviderSnapshot` with confidence, status, optional pressure, and signals.
4. Register the adapter in `ProviderRegistry.builtInAdapters()`.

Because provider IDs are extensible (`ProviderName.custom(...)`), new IDs do not require changing core enums.

## Runtime Providers (No Recompile)

You can register providers under `externalProviders` in `~/Library/Application Support/LimitLens/settings.json`.

Example:

```json
{
  "allowExternalProviderCommands": true,
  "externalProviders": [
    {
      "id": "gemini",
      "displayName": "Gemini",
      "shortLabel": "Gem",
      "command": "/usr/local/bin/gemini-limitlens-bridge",
      "arguments": ["--json"],
      "timeoutSeconds": 3
    }
  ]
}
```

Runtime command adapters are ignored unless `allowExternalProviderCommands` is explicitly enabled.
Provider IDs must be slug-style (`a-z`, `0-9`, `.`, `_`, `-`), command paths must be absolute and executable, and duplicate IDs are deduped with first-entry-wins behavior.

The command must print JSON to stdout with fields aligned to `ProviderSnapshot` semantics. Minimal payload:

```json
{
  "confidence": "high",
  "currentUsagePercent": 64.5,
  "currentStatusSummary": "64.5% used"
}
```

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
