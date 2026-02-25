# LimitLens Architecture

## Opening

LimitLens is a local-first observability system for AI usage pressure. Its central purpose is to make limit risk visible before a developer’s workflow breaks. Instead of waiting for provider errors to interrupt active coding, the system keeps pressure, context, and historical rate-limit signals visible in two places that developers already live: the terminal and the macOS menu bar.

The architecture is built around one shared core and multiple surfaces. The core reads provider artifacts, normalizes them into a coherent model, evaluates thresholds, and computes severity semantics. The interfaces then project that shared state differently depending on interaction style. The CLI emphasizes scriptability and precision, while the menu bar emphasizes ambient awareness and interruption only when warning thresholds are crossed.

Milestone 4 hardening reshaped the system from a fixed-provider MVP into an incrementally extensible architecture. Provider identity is no longer a closed set in practice, provider registration is centralized, severity logic is unified across all surfaces, and install/runability workflows are codified so the product can be used outside developer-only contexts.

## Ontology

The center of the model is `ProviderSnapshot`, which describes one provider at one refresh instant. A provider snapshot carries identity, confidence, current pressure when available, historical signals, source references, and parse/runtime errors. Identity is represented by `ProviderName`, which includes built-in providers and a custom slug path, and by `ProviderDescriptor`, which carries display metadata such as human-readable names and short labels.

`GlobalSnapshot` is the full multi-provider state for one capture moment. This is the object that both CLI and menu bar consume. Threshold policy is represented through `LimitLensSettings` and evaluated by `ThresholdEngine`, which emits `ThresholdEvent` values only on upward threshold crossing and only when cooldown permits. Runtime memory for this behavior lives in `ThresholdRuntimeState`, which stores prior observed pressure and last notification timestamps keyed by provider and threshold.

Severity meaning is represented by `SeverityLevel` and evaluated through `SeverityEvaluator`. That evaluator is shared by compact badges, menu rows, and global status, so the same provider state has one warning meaning everywhere.

## Geography

At repository root, `Package.swift` defines the package topology. It exports `LimitLensCore` as the shared library, `limitlens` as the CLI executable, `LimitLensMenuBar` as the macOS UI executable, and `limitlens-core-tests` as a portable validation executable. The root `README.md` gives build, run, install, and extension guidance. The root `.gitignore` excludes local planning material and build artifacts. The local-only specification remains in `docs/SPEC.md` and is intentionally untracked.

The directory `Sources/LimitLensCore` is the product kernel. The file `Models.swift` defines canonical entities and settings state, including extensible provider identity. The file `ProviderRegistry.swift` defines built-in provider descriptors, default adapter composition, and snapshot ordering policy. The file `ProviderAdapters.swift` implements source discovery and adapter orchestration for built-in providers. The file `ProviderParsing.swift` implements pure parsing functions used by adapters and tests. The file `FileSystemSupport.swift` encapsulates filesystem traversal and tail reads. The file `ProcessSupport.swift` encapsulates subprocess execution. The file `SnapshotService.swift` collects adapter output into one ordered global snapshot. The file `SeverityEvaluator.swift` centralizes provider and global warning interpretation. The file `SnapshotFormatter.swift` renders human, JSON, and compact output forms. The file `ThresholdEngine.swift` applies crossing and cooldown policy. The file `SettingsStore.swift` persists settings and runtime threshold memory in Application Support.

The directory `Sources/LimitLensCLI` contains `main.swift`, which is the terminal runtime entrypoint. It parses arguments, applies per-process overrides, runs one-shot or watch loops, and renders results with shared formatters.

The directory `Sources/LimitLensMenuBar` contains the native macOS runtime. The file `main.swift` handles lifecycle, status rendering, adaptive polling, threshold event dispatch, launch-at-login coordination, and menu construction. The file `SettingsWindowController.swift` provides a native preferences panel with path browsing, tokenized threshold editing, preset actions, and validation. The file `NotificationCoordinator.swift` manages permission state, notification delivery, and explicit delivery outcomes. The file `LaunchAtLoginManager.swift` manages LaunchAgent creation/removal via `launchctl bootstrap` and `bootout` with explicit result reporting.

The directory `Sources/LimitLensCoreTestsRunner` contains the portable test harness executable and parser fixtures. The file `main.swift` executes parser and threshold assertions and returns process exit status for CI and local gates. The `Fixtures` subdirectory contains deterministic input data for parser behavior.

The directory `scripts` contains operational tooling. The file `scripts/install.sh` builds release binaries, installs CLI commands, and creates a local app bundle under `~/Applications`. The file `scripts/uninstall.sh` removes launch agent registration and local installs. The file `scripts/doctor.sh` reports environment readiness and provider source availability. The workflow file `.github/workflows/ci.yml` runs build and core test harness checks on macOS in pull request and main branch pipelines.

## Flow

In CLI flow, the process starts in `Sources/LimitLensCLI/main.swift`, resolves settings, and invokes `SnapshotService`. The snapshot service asks each registered adapter for one provider snapshot. Adapters discover source artifacts, read bounded tails, parse raw content through `ProviderParsing`, and emit normalized values with confidence and evidence. The service orders snapshots through `ProviderRegistry`, then `SnapshotFormatter` renders either human-oriented output or JSON output.

In menu bar flow, the app starts as an accessory process, loads persisted settings and threshold runtime state, refreshes notification authorization status, and begins periodic refresh. Each refresh cycle reloads settings, collects a new global snapshot, recomputes cadence based on pressure, applies threshold policy, persists threshold runtime state, and optionally dispatches notifications. Delivery results and permission state are reflected in the menu so notification failures are not silent.

When users open settings, `SettingsWindowController` edits a working copy of `LimitLensSettings`, validates numeric and threshold input, preserves unknown provider overrides for incremental provider growth, and writes the updated settings through `SettingsStore`. The menu runtime immediately reapplies cadence and launch-at-login behavior from the saved settings.

When launch-at-login is enabled, `main.swift` resolves a stable executable path and sends that to `LaunchAtLoginManager`. The manager writes a LaunchAgent plist and calls `launchctl bootout` followed by `launchctl bootstrap`. Failure details are propagated back to the menu runtime and shown as status text. Development `.build` paths are treated as unstable, and the runtime reports that an installed app bundle is required for stable startup registration.

In validation flow, `limitlens-core-tests` reads fixture resources, runs parser and threshold checks, prints pass/fail lines, and exits nonzero on failure. CI uses this executable as the behavior gate.

## Philosophy

LimitLens prioritizes truthful confidence over false certainty. A provider with explicit percentage data is treated differently from one with only historical evidence, and that distinction is preserved in output language. The architecture also prioritizes shared meaning, so severity and threshold semantics are defined once in core and reused everywhere.

The system prefers incremental extensibility over one-off branching. Adding a new provider is an adapter and registry change, not a redesign of core entities. The settings model stores provider thresholds by provider slug, and the settings UI preserves unknown provider overrides so newly added providers do not lose configuration.

The system also values operational runability as a first-class concern. Build, test, install, uninstall, and diagnostic paths are explicit and automatable. This keeps the project viable both as developer code and as a day-to-day product utility.
