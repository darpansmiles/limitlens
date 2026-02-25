# LimitLens

LimitLens is a processor-agnostic usage and limits monitor for AI coding tools.

It is inspired by the product direction of CodexBar (menu bar visibility, lightweight status, rapid refresh) while remaining open, local-first, and architecture-agnostic across Intel and Apple Silicon Macs.

## Status

Specification-approved bootstrap phase.

This repository currently contains:

- Approved product specification
- Human-friendly CLI prototype
- Architecture narration document
- MIT license

Implementation now proceeds with:

- Full native macOS menu bar app
- Threshold-based notifications
- Swift production CLI
- Packaging for Intel + Apple Silicon

## Project Name

`LimitLens`

Rationale: it communicates "seeing your limits clearly" across providers without tying the brand to one model vendor.

## What Exists Today

### 1. Detailed Spec

- [docs/SPEC.md](./docs/SPEC.md)

### 2. System Architecture Narrative

- [ARCHITECTURE.md](./ARCHITECTURE.md)

### 3. CLI Prototype

```bash
cd /Users/darpan/Documents/Personal/antigravity/limitlens
node cli/limitlens.js
```

Other modes:

```bash
node cli/limitlens.js --json
node cli/limitlens.js --watch --interval 30
npm run limits
npm run limits:json
npm run limits:watch
```

The CLI currently reads local data from:

- `~/.codex/sessions`
- `~/.claude/projects`
- `~/Library/Application Support/Antigravity/logs`

## License

MIT. See [LICENSE.md](./LICENSE.md).
