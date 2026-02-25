# LimitLens Architecture

## Opening

LimitLens exists to make invisible usage pressure visible before it becomes workflow failure. The system is built around a simple operating assumption: developers do not need another dashboard they have to remember to open, they need a quiet companion that remains present while they work and warns them early when they are approaching service limits. The project therefore combines two faces of the same engine. One face is terminal-native and optimized for direct, textual clarity. The other is a native macOS menu bar presence optimized for ambient awareness and threshold-based interruption only when it is justified.

The project is intentionally local-first. Instead of building a remote dependency graph that asks for cloud credentials and account scopes in phase one, it reads the local artifacts that provider tools already emit. This keeps the system lightweight, private by default, and resilient to API changes that would otherwise break external integrations. The architecture is shaped around adapters that read provider-specific sources, a normalization layer that translates disparate signals into a coherent model, and an alerting layer that decides when to notify based on threshold crossing and cooldown behavior.

## Ontology

The central entity in LimitLens is a provider snapshot. A provider snapshot is the system's current understanding of one tool's limit condition at a specific moment in time. It contains two kinds of truth that must be kept distinct. The first is current status, which is what we can assert right now from the freshest available records, such as a concrete usage percentage or a recent context pressure metric. The second is historical signal, which is evidence that something happened, such as a prior rate-limit event in logs, without claiming that the condition is still active.

A global snapshot is a composition of provider snapshots captured in one refresh cycle. The global snapshot is what the CLI prints and what the menu bar UI renders. Threshold definitions are separate entities because they encode policy rather than observation. A threshold set says what the user cares about, while snapshots say what the world looks like. Notification events are produced when observed values cross policy boundaries in the upward direction and survive cooldown rules. Configuration ties these pieces together by describing where sources live on disk, which thresholds are active, which notification mode the user prefers, and whether launch-at-login is enabled.

## Geography

The root file `README.md` introduces the product promise and current project status so a new contributor can understand whether they are looking at a planning branch or a release-ready branch. The `LICENSE.md` file defines the legal boundary under MIT terms and is part of the project's distribution contract.

The `docs/SPEC.md` document is the product contract for implementation and contains the approved decisions that engineering should treat as constraints rather than suggestions. It records scope, threshold policy, permissions expectations, and milestone sequencing so architectural tradeoffs remain anchored to user intent.

The `cli/limitlens.js` file is the active executable prototype. It currently performs provider discovery, parses local artifacts, normalizes the result into one snapshot object, and renders either a human-readable report or JSON. This file is intentionally doing more than one responsibility during the prototype stage because it allows rapid iteration on source semantics before those responsibilities are split into a shared core package.

The `apps/LimitLensMenuBar/README.md` file marks the location reserved for the native macOS top-bar implementation. It is currently a placeholder so repository structure already reflects the intended product topology while implementation is underway.

The `package.json` file is a lightweight execution manifest for the prototype phase. It does not define a production runtime architecture; it only provides simple scripts so contributors and reviewers can execute the current CLI quickly.

## Flow

The most important runtime path begins when a user invokes the CLI. The process parses command arguments, resolves any home-directory shorthand in configured paths, and then reads each provider source in parallel. Provider-specific extraction logic scans for the latest usable records, preferring concrete signals over noisy events. The resulting provider-specific findings are normalized into one snapshot that preserves both current status and historical signals. That unified snapshot is then rendered either as human prose with local-plus-UTC timestamps and age deltas or as structured JSON for machine consumers.

The primary menu bar path follows the same data movement but changes presentation and policy behavior. A background refresh cycle pulls provider snapshots, evaluates threshold crossing rules, updates top-bar state color and text, and conditionally emits notifications according to user-selected mode. When users open the dropdown, they are not triggering a new model of truth; they are inspecting the same normalized snapshot currently driving alert logic. This keeps the app coherent because visibility and notification are always derived from the same state.

## Philosophy

LimitLens prefers explicit confidence over false precision. If a provider emits a numeric usage percent, the system treats that as high-confidence status. If a provider only reveals rate-limit errors in logs, the system surfaces that as historical evidence and avoids pretending it knows exact remaining quota. This distinction is central to user trust and is reflected directly in output language.

The architecture also favors adapter isolation. Each provider has different artifact formats and stability guarantees, so provider-specific parsing should evolve independently while the rest of the system consumes a stable normalized model. This allows us to change or replace one adapter without destabilizing the CLI renderer, threshold engine, or menu bar view model.

Finally, the project accepts a pragmatic tradeoff in phase one: local parsing over cloud APIs. That choice reduces integration complexity and privacy surface area at the cost of incomplete visibility for some providers. The system addresses that cost by clearly labeling inferred signals and by preserving extension points for richer integrations in later phases without rewriting the product core.
