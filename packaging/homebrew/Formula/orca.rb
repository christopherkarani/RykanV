class Orca < Formula
  desc "Local runtime firewall for AI agents (compat formula; prefer ryk)"
  homepage "https://github.com/christopherkarani/Orca"
  version "1.2.8"
  license "Apache-2.0"

  # Phase 5a: formula still named orca for existing taps; ships ryk primary + orca alias.
  # Artifact URLs prefer ryk-v* (dual-published orca-v* also available on the same release).

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
    if (buildpath/"bin/ryk").exist?
      bin.install "bin/ryk"
    end
    if (buildpath/"bin/orca").exist?
      bin.install "bin/orca"
    elsif (buildpath/"bin/ryk").exist?
      bin.install_symlink "ryk" => "orca"
    else
      bin.install "bin/orca"
    end
    pkgshare.install "orca-dashboard-ui"
    pkgshare.install "integrations"
    pkgshare.install "fixtures"
    pkgshare.install "schemas"
    pkgshare.install "policies"
  end

  def caveats
    <<~EOS
      Deprecated formula name: prefer `brew install ryk` when available.
      Primary binary is ryk; orca remains a PATH alias for one major.

      Runtime assets:
        #{pkgshare}

          export PATH="#{bin}:$PATH"
          export ORCA_RESOURCE_ROOT="#{pkgshare}"
    EOS
  end

  test do
    ENV["ORCA_RESOURCE_ROOT"] = pkgshare
    if (bin/"ryk").exist?
      assert_match version.to_s, shell_output("#{bin}/ryk --version")
    end
    assert_match version.to_s, shell_output("#{bin}/orca --version")
    system "#{bin}/orca", "doctor"
  end
end
