# LimitLens Architecture

## Opening

LimitLens is a local-first observability system for AI usage pressure. Its central purpose is to make limit risk visible before a developer’s workflow breaks. Instead of waiting for provider errors to interrupt active coding, the system keeps pressure, context, and historical rate-limit signals visible in two places that developers already live: the terminal and the macOS menu bar.

The architecture is intentionally built around one shared engine and multiple interfaces. The shared engine reads local provider artifacts, normalizes them into a coherent model, and applies threshold policy. The interfaces then present that same model differently depending on interaction mode. The terminal path favors direct, scriptable output, while the menu-bar path favors ambient awareness, glanceability, and threshold-triggered interruption.

## Ontology

The core entity is `ProviderSnapshot`. A provider snapshot is a statement about one provider at one point in time, including current metrics when available, inferred pressure when direct quota is unavailable, and historical signals such as recent `429` evidence. `GlobalSnapshot` is the system-wide observation for one refresh cycle and is the object that both the CLI and menu bar render.

Policy is represented through `LimitLensSettings` and evaluated by `ThresholdEngine`. Settings define source paths, thresholds, notification mode, cooldown, cadence, and startup behavior. The threshold engine translates observed pressure into `ThresholdEvent` values only when upward crossing and cooldown rules allow it. Persistence of alert memory is handled through `ThresholdRuntimeState`, which stores prior percentages and last-notified timestamps so behavior remains stable across refresh cycles and app restarts.

## Geography

At the root, `Package.swift` defines the package contract. It declares the shared library `LimitLensCore`, two product interfaces `limitlens` and `LimitLensMenuBar`, and a dedicated validation executable `limitlens-core-tests`. The root `README.md` explains how to build, run, configure, and verify the system, while `LICENSE.md` defines the MIT legal boundary. The `.gitignore` keeps build artifacts and local planning docs out of source control, including the intentionally local-only `docs/SPEC.md`.

The `Sources/LimitLensCore` directory is the architecture center. The file `Models.swift` defines canonical entities and settings state. The file `Utilities.swift` contains path expansion, timestamp parsing, date formatting, regex capture, and threshold-key helpers. The file `FileSystemSupport.swift` handles directory traversal, latest-file detection, and tail reads for large logs. The file `ProcessSupport.swift` encapsulates subprocess execution for metadata lookups like local binary versions. The file `ProviderParsing.swift` contains pure parsing logic that converts raw log text into typed metrics and signals, while `ProviderAdapters.swift` handles provider-specific source discovery and orchestration of parser output. The file `SnapshotService.swift` aggregates providers into a `GlobalSnapshot`. The file `SnapshotFormatter.swift` renders snapshots for CLI prose, JSON output, and compact menu text. The file `ThresholdEngine.swift` implements threshold crossing and cooldown policy. The file `SettingsStore.swift` persists user settings and runtime state to Application Support.

The `Sources/LimitLensCLI/main.swift` file is the terminal entrypoint. It parses command flags, overlays process-level overrides on persisted settings, executes collection in single-shot or watch mode, and prints either human-readable or JSON output.

The `Sources/LimitLensMenuBar` directory contains the native macOS app runtime. The file `main.swift` handles app lifecycle, adaptive refresh scheduling, threshold evaluation, status-bar rendering, menu construction, and action routing. The file `SettingsWindowController.swift` provides the native settings panel where users can edit thresholds, paths, cadence, cooldown, notification mode, and launch-at-login behavior with validation. The file `NotificationCoordinator.swift` manages permission requests and mode-specific notification delivery. The file `LaunchAtLoginManager.swift` owns LaunchAgent creation/removal and `launchctl` synchronization.

The `Sources/LimitLensCoreTestsRunner/main.swift` file is a portable test harness executable. It loads parser fixtures from `Sources/LimitLensCoreTestsRunner/Fixtures` and validates parser extraction plus threshold policy behavior without requiring external test frameworks.

The `apps/LimitLensMenuBar/README.md` file documents the reserved distribution area for future packaging assets, and `cli/limitlens.js` remains a legacy prototype reference while Swift executables are the production path.

## Flow

In the CLI flow, the user invokes `limitlens`, arguments are parsed, persisted settings are loaded, process-level overrides are applied, and `SnapshotService` collects provider snapshots through adapters. Each adapter discovers the newest relevant artifacts, reads bounded tails, parses current and historical signals, and returns normalized provider state. The combined snapshot is then rendered either as structured JSON or terminal-friendly narrative output with dual timestamps and relative age context.

In the menu-bar flow, the app starts as an accessory process, requests notification permission, loads persisted settings/runtime memory, and begins periodic refresh. Each cycle reloads settings to pick up out-of-band edits, collects a fresh snapshot, adapts polling cadence based on pressure level, evaluates threshold crossing via `ThresholdEngine`, persists runtime state, and dispatches alerts according to the selected notification mode. The same cycle updates top-bar visual severity and menu content so passive glance state and detailed dropdown state are always derived from the same model.

When users open the settings window, the UI edits an in-memory working copy of `LimitLensSettings`, validates values, writes them via `SettingsStore`, and immediately re-applies cadence, launch-at-login, and threshold policy without requiring app restart. Launch behavior is enforced through `LaunchAtLoginManager`, which writes or removes `~/Library/LaunchAgents/com.limitlens.menubar.plist` and synchronizes with `launchctl`.

In the validation flow, `limitlens-core-tests` loads bundled fixture files, executes parser assertions and threshold-policy assertions, reports pass/fail per case, and exits nonzero on failure so it can be used as an automated gate.

## Philosophy

The architecture favors explicit confidence over false precision. If a provider exposes exact usage percentages, LimitLens reports them directly; if only historical evidence exists, LimitLens states that condition as historical signal rather than pretending exact quota visibility. This principle preserves trust when provider observability is uneven.

The architecture also favors isolation of changing concerns. Provider source discovery and pure text parsing are separated so format regressions can be fixed with tight scope, while policy and UI behavior remain stable. Interface layers depend on the same core model so CLI and menu-bar outputs stay consistent while retaining different user experiences.

Finally, the project favors practical portability. Swift implementation allows one codebase to run on both Intel and Apple Silicon, and the dedicated test runner keeps verification available even in environments where traditional XCTest tooling is unavailable.
