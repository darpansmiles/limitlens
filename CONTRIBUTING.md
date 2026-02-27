# Contributing to LimitLens

Thanks for contributing to LimitLens.

## Local Setup

```bash
git clone https://github.com/darpansmiles/limitlens.git
cd limitlens
swift build
swift run limitlens-core-tests
swift run limitlens-menubar-tests
```

Optional local install:

```bash
bash ./scripts/install.sh --unsigned
```

## Development Workflow

1. Create a branch from `main`.
2. Keep changes scoped to one concern per PR.
3. Run build and both test runners before opening the PR.
4. Update `ARCHITECTURE.md` whenever behavior, structure, or file topology changes.
5. Update README/docs when user-facing behavior changes.

## Pull Request Guidelines

- Explain the user-visible impact and technical approach.
- Include before/after screenshots for menu bar or settings UI changes.
- Include CLI output examples for formatting or onboarding changes.
- Mention any release/distribution script changes explicitly.

## Code Style Notes

- Keep Swift code explicit and readable.
- Prefer shared core logic over duplicating policy in CLI/menu surfaces.
- Add comments where intent is non-obvious, especially around threshold, notification, and packaging policy.
- Preserve processor-agnostic behavior (`arm64` + `x86_64`) in install/release scripts.

## Reporting Bugs and Requesting Features

Use the issue templates in `.github/ISSUE_TEMPLATE`.
