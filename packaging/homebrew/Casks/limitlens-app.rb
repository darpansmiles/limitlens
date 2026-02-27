# This cask installs the LimitLens menu bar app from the release DMG.
# Update `sha256` whenever a new release DMG is published.

cask "limitlens-app" do
  version "0.5.0"
  sha256 "ab6490cbc0fb49ad4b27af70a6adfcfd12351af08357a048a38d267b011d4ba4"

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
