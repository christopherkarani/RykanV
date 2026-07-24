class Ryk < Formula
  desc "Local runtime firewall for AI agents"
  homepage "https://github.com/christopherkarani/Orca"
  version "1.2.8"
  license "Apache-2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/christopherkarani/Orca/releases/download/v#{version}/ryk-v#{version}-darwin-arm64.tar.gz"
      sha256 "{{DARWIN_ARM64_SHA256}}"
    else
      url "https://github.com/christopherkarani/Orca/releases/download/v#{version}/ryk-v#{version}-darwin-amd64.tar.gz"
      sha256 "{{DARWIN_AMD64_SHA256}}"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/christopherkarani/Orca/releases/download/v#{version}/ryk-v#{version}-linux-arm64.tar.gz"
      sha256 "{{LINUX_ARM64_SHA256}}"
    else
      url "https://github.com/christopherkarani/Orca/releases/download/v#{version}/ryk-v#{version}-linux-amd64.tar.gz"
      sha256 "{{LINUX_AMD64_SHA256}}"
    end
  end

  def install
    bin.install "bin/ryk"
    # Compat alias for one major (Phase 5a dual-name).
    if (buildpath/"bin/orca").exist?
      bin.install "bin/orca"
    else
      bin.install_symlink "ryk" => "orca"
    end
    pkgshare.install "orca-dashboard-ui"
    pkgshare.install "integrations"
    pkgshare.install "fixtures"
    pkgshare.install "schemas"
    pkgshare.install "policies"
  end

  def caveats
    <<~EOS
      ryk runtime assets are installed at:
        #{pkgshare}

      Primary CLI is `ryk`. `orca` is a compatibility alias for one major.

      To use ryk in this terminal right now, run:

          export PATH="#{bin}:$PATH"
          export ORCA_RESOURCE_ROOT="#{pkgshare}"
          # optional dual-read: RYK_RESOURCE_ROOT also accepted by some tools

      (These lines match the curl|sh installer contract. Share path remains under orca in 5a.)
    EOS
  end

  test do
    ENV["ORCA_RESOURCE_ROOT"] = pkgshare
    assert_match version.to_s, shell_output("#{bin}/ryk --version")
    assert_match version.to_s, shell_output("#{bin}/orca --version")
    system "#{bin}/ryk", "doctor"
    system "#{bin}/ryk", "packs", "--help"
    system "#{bin}/ryk", "plugin", "doctor", "hermes", "--json"
    system "#{bin}/ryk", "redteam", "--ci"
  end
end
