class Orca < Formula
  desc "Local runtime firewall for AI agents (compat formula; prefer ryk)"
  homepage "https://github.com/christopherkarani/rykan"
  version "1.2.9"
  license "Apache-2.0"

  # Phase 5a: formula still named orca for existing taps; ships ryk primary + orca alias.
  # Artifact URLs prefer ryk-v* (dual-published orca-v* also available on the same release).

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/christopherkarani/rykan/releases/download/v#{version}/ryk-v#{version}-darwin-arm64.tar.gz"
      sha256 "{{DARWIN_ARM64_SHA256}}"
    else
      url "https://github.com/christopherkarani/rykan/releases/download/v#{version}/ryk-v#{version}-darwin-amd64.tar.gz"
      sha256 "{{DARWIN_AMD64_SHA256}}"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/christopherkarani/rykan/releases/download/v#{version}/ryk-v#{version}-linux-arm64.tar.gz"
      sha256 "{{LINUX_ARM64_SHA256}}"
    else
      url "https://github.com/christopherkarani/rykan/releases/download/v#{version}/ryk-v#{version}-linux-amd64.tar.gz"
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
    (share/"orca/current").install "orca-dashboard-ui"
    (share/"orca/current").install "integrations"
    (share/"orca/current").install "fixtures"
    (share/"orca/current").install "schemas"
    (share/"orca/current").install "policies"
    (share/"orca/current").install "orca-pi"
  end

  def post_install
    ohai "Running ryk onboarding to wire host hooks..."
    user_bins = %w[
      .local/bin
      .npm-global/bin
      .bun/bin
      .cargo/bin
      .grok/bin
      .codex/bin
    ].map { |path| File.join(Dir.home, path) }
    onboard_env = {
      "RYK_RESOURCE_ROOT" => (share/"orca/current").to_s,
      "ORCA_RESOURCE_ROOT" => (share/"orca/current").to_s,
      "PATH" => ([bin.to_s] + user_bins + [ENV.fetch("PATH", "")]).join(File::PATH_SEPARATOR),
    }
    success = Dir.chdir(Dir.home) do
      system onboard_env, "#{bin}/ryk", "start", "--auto"
    end
    odie "ryk was installed, but protection setup failed; resolve the reported host error and install the ryk formula" unless success
  end

  def caveats
    <<~EOS
      ryk setup ran automatically. Its onboarding result reports whether active
      protection was verified or whether a host still needs attention.

      Off-ramp (remove host hooks):
        ryk stop

      This compatibility formula is deprecated; use `brew install ryk`.
    EOS
  end

  test do
    if (bin/"ryk").exist?
      assert_match version.to_s, shell_output("#{bin}/ryk --version")
    end
    assert_match version.to_s, shell_output("#{bin}/orca --version")
    system "#{bin}/orca", "doctor"
  end
end
