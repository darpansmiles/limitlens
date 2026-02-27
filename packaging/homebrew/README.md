# Homebrew Tap Assets

This directory contains Formula and Cask definitions for a `homebrew-limitlens` tap repository.

## Expected tap structure

- `Formula/limitlens.rb`
- `Casks/limitlens-app.rb`

## Publish flow

1. Build release artifacts (`limitlens-<version>-universal.tar.gz` and `LimitLens-<version>.dmg`).
2. Upload those artifacts to GitHub release `v<version>`.
3. Update SHA256 values in the Formula and Cask.
4. Copy these files into your tap repository (for example `darpansmiles/homebrew-limitlens`).
5. Validate:

```bash
brew tap darpansmiles/limitlens
brew install darpansmiles/limitlens/limitlens
brew install --cask darpansmiles/limitlens/limitlens-app
```
