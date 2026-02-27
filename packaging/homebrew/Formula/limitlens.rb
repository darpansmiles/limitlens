# This formula installs the LimitLens CLI from GitHub release artifacts.
# Update `sha256` whenever a new release tarball is published.

class Limitlens < Formula
  desc "Local-first AI usage limit monitor CLI"
  homepage "https://github.com/darpansmiles/limitlens"
  version "0.5.0"
  url "https://github.com/darpansmiles/limitlens/releases/download/v#{version}/limitlens-#{version}-universal.tar.gz"
  sha256 "731f12d20b675f7299fdf38ca116996dbd5d493e222ce7dfdb8a03216e8cd2ca"
  license "MIT"

  depends_on macos: :ventura

  def install
    # Release tarball ships a prebuilt universal `limitlens` binary.
    bin.install "limitlens"
  end

  test do
    assert_match "LimitLens CLI", shell_output("#{bin}/limitlens --help")
  end
end
