# This cask installs the LimitLens menu bar app from the release DMG.
# Update `sha256` whenever a new release DMG is published.

cask "limitlens-app" do
  version "0.5.0"
  sha256 "50ee1d2b0210e8b720803762c54970ed22c2caa86d2021d2358b41e785ab799f"

  url "https://github.com/darpansmiles/limitlens/releases/download/v#{version}/LimitLens-#{version}.dmg"
  name "LimitLens"
  desc "Menu bar monitor for Codex, Claude, and Antigravity usage pressure"
  homepage "https://github.com/darpansmiles/limitlens"

  app "LimitLens.app"

  zap trash: [
    "~/Library/Application Support/LimitLens",
    "~/Library/LaunchAgents/com.limitlens.menubar.plist",
  ]
end
