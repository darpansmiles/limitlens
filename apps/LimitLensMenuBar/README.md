# LimitLens Menu Bar App

The active native implementation lives in the SwiftPM executable target at `Sources/LimitLensMenuBar`.
Shared launch-agent and notification support code lives in `Sources/LimitLensMenuBarSupport` under the `LimitLensMenuBarSupport` target so it can be tested without launching AppKit.

This `apps/LimitLensMenuBar` directory is reserved for distribution assets such as app packaging metadata, release notes, screenshots, and notarization artifacts.

For local installation, use `scripts/install.sh`, which creates `~/Applications/LimitLens.app` from the compiled menu bar executable.
