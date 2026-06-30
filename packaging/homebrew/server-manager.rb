# Homebrew formula for server-manager.
#
# Canonical copy lives in the tap repo (regnatech/homebrew-tap) as
# Formula/server-manager.rb; this versioned copy is kept here for reference.
# After tagging a release, bump `url` + `sha256` here and in the tap.
class ServerManager < Formula
  desc "Zero-config CLI to deploy & manage web apps on remote Linux servers over SSH"
  homepage "https://github.com/regnatech/server-manager"
  url "https://github.com/regnatech/server-manager/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "95999a7496492fd5cab337cd78aa15f35af31f56ac397e00240ae2bb746d0a0c"
  license "MIT"

  def install
    libexec.install "bin", "lib", "templates", "mcp", "docs", "README.md", "LICENSE"
    # bin/server resolves its install root by following this symlink.
    bin.install_symlink libexec/"bin/server"
  end

  test do
    assert_match "0.1.1", shell_output("#{bin}/server version")
  end
end
