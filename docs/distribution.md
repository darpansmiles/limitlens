# Distribution and Onboarding Guide (v0.5)

This guide documents the release flow for CLI and menu bar distribution.

## 1. Build release artifacts

Unsigned local artifacts:

```bash
bash ./scripts/build-release-assets.sh --version 0.5.0 --unsigned
```

Signed/notarized artifacts:

```bash
bash ./scripts/build-release-assets.sh \
  --version 0.5.0 \
  --sign-identity "Developer ID Application: Example, Inc." \
  --notarize-profile "limitlens-notary"
```

Artifacts:

- `dist/limitlens-0.5.0-universal.tar.gz`
- `dist/LimitLens-0.5.0.dmg`

## 2. Apple signing and notarization prerequisites

You need Apple Developer Program membership for Developer ID distribution.

Setup once:

1. Install Xcode Command Line Tools.
2. Import your Developer ID Application certificate into Keychain Access.
3. Configure notarytool keychain profile:

```bash
xcrun notarytool store-credentials "limitlens-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

If you do not have Developer ID credentials yet, use `--unsigned` and ship with a clear "notarization pending" note.

## 3. Publish GitHub releases

Create release notes with `Added`, `Changed`, and `Fixed` sections.

- `docs/releases/v0.4.0.md`
- `docs/releases/v0.5.0.md`

Create releases:

```bash
bash ./scripts/create-release.sh --version 0.4.0 --notes-file docs/releases/v0.4.0.md
bash ./scripts/create-release.sh --version 0.5.0 --notes-file docs/releases/v0.5.0.md
```

## 4. Update Homebrew formulas

After release artifacts are uploaded, compute checksums:

```bash
shasum -a 256 dist/limitlens-0.5.0-universal.tar.gz
shasum -a 256 dist/LimitLens-0.5.0.dmg
```

Apply checksums:

```bash
bash ./scripts/update-homebrew-formulas.sh \
  --version 0.5.0 \
  --cli-sha256 <CLI_SHA256> \
  --app-sha256 <DMG_SHA256>
```

Publish to tap repo:

```bash
bash ./scripts/publish-homebrew-tap.sh --tap-repo darpansmiles/homebrew-limitlens
```

## 5. Validate onboarding UX

CLI first run:

```bash
limitlens
```

Expected:

- One-time welcome box.
- Provider detection lines (`✓` / `✗`).
- Severity color explanation.

Menu first launch:

- Welcome section appears with provider detection and `Configure Paths →`.
- Welcome section hides after first settings save or after 48 hours.
- Source issues show `⚠ Fix` action and open settings focused on the correct path field.
