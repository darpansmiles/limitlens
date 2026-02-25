# LimitLens

LimitLens is a processor-agnostic, local-first usage monitor for Codex, Claude, and Antigravity.

It ships as one Swift package with three executables:

- `limitlens` for terminal snapshots and JSON output.
- `LimitLensMenuBar` for always-on macOS top-bar monitoring and alerts.
- `limitlens-core-tests` for parser and threshold unit checks.

## Milestone Status

Milestones 1, 2, 3, and 4 are implemented:

- Shared core adapter + normalization engine.
- Native CLI with human mode, JSON mode, watch mode, and path overrides.
- Native menu bar app with adaptive refresh, threshold alerts, launch-at-login, and a built-in settings window.
- Portable unit-test harness with fixture-driven parser checks and threshold crossing/cooldown checks.
- Milestone 4 hardening: provider-pluggable architecture, unified severity semantics, permission-aware notifications, robust launch-at-login reporting, install/uninstall/doctor scripts, and CI workflow.

## Requirements

- macOS 13+
- Swift toolchain (Command Line Tools or Xcode)

## Build

```bash
cd /Users/darpan/Documents/Personal/antigravity/limitlens
swift build
```

## Install (Local Machine)

Install CLI tools + macOS app bundle:

```bash
bash ./scripts/install.sh
```

Uninstall:

```bash
bash ./scripts/uninstall.sh
```

Environment doctor:

```bash
bash ./scripts/doctor.sh
```

NPM shortcuts:

```bash
npm run limits:install
npm run limits:uninstall
npm run limits:doctor
```

## CLI Usage

One-shot snapshot:

```bash
swift run limitlens
```

JSON mode:

```bash
swift run limitlens --json
```

Watch mode:

```bash
swift run limitlens --watch --interval 30
```

Override source paths for a run:

```bash
swift run limitlens --codex-path ~/.codex/sessions --claude-path ~/.claude/projects --antigravity-logs-path "~/Library/Application Support/Antigravity/logs"
```

## Menu Bar App Usage

Launch app:

```bash
swift run LimitLensMenuBar
```

The app appears in the macOS menu bar and provides:

- Severity-colored top-bar status using a shared severity policy.
- Provider health lines with pressure/signal context.
- In-app settings window for paths, thresholds, notification mode, cooldown, and launch-at-login.
- Permission-aware notification status feedback.
- Deep-link to macOS notification settings.

## Unit Tests

Run core parser and threshold tests:

```bash
swift run limitlens-core-tests
```

NPM shortcut:

```bash
npm run limits:test
```

## Settings and Permissions

Settings are stored in:

- `~/Library/Application Support/LimitLens/settings.json`
- `~/Library/Application Support/LimitLens/runtime_state.json`

Notification permission is required for banner/sound notification modes.

Defaults:

- Thresholds: `70/75/80/85/90/95`
- Launch at login: enabled
- Notification mode: `sound+banner`

## Extending Providers

Provider architecture is incremental. New providers can be added via adapter + registry registration without redesigning core entities.

- Extension guide: [`docs/adding-providers.md`](./docs/adding-providers.md)

## Notes

`docs/SPEC.md` remains local-only and untracked by design.

`cli/limitlens.js` is kept as a legacy prototype reference.

## License

MIT. See [LICENSE.md](./LICENSE.md).
