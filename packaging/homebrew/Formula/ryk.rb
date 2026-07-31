class Ryk < Formula
  desc "Local runtime firewall for AI agents"
  homepage "https://github.com/christopherkarani/rykan"
  version "1.2.9"
  license "Apache-2.0"

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
    bin.install "bin/ryk"
    # Compat alias for one major (Phase 5a dual-name).
    if (buildpath/"bin/ryk").exist?
      bin.install "bin/ryk"
    else
      bin.install_symlink "ryk" => "orca"
    end
    (share/"orca/current").install "ryk-dashboard-ui"
    (share/"orca/current").install "integrations"
    (share/"orca/current").install "fixtures"
    (share/"orca/current").install "schemas"
    (share/"orca/current").install "policies"
    (share/"orca/current").install "ryk-pi"
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
      "RYK_RESOURCE_ROOT" => (share/"orca/current").to_s,
      "PATH" => ([bin.to_s] + user_bins + [ENV.fetch("PATH", "")]).join(File::PATH_SEPARATOR),
    }
    success = Dir.chdir(Dir.home) do
      system onboard_env, "#{bin}/ryk", "start", "--auto"
    end
    odie "ryk was installed, but protection setup failed; resolve the reported host error and reinstall ryk" unless success
  end

  def caveats
    <<~EOS
      ryk setup ran automatically. Its onboarding result reports whether active
      protection was verified or whether a host still needs attention.

      Off-ramp (remove host hooks):
        ryk stop
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ryk --version")
    assert_match version.to_s, shell_output("#{bin}/orca --version")
    system "#{bin}/ryk", "doctor"
    system "#{bin}/ryk", "packs", "--help"
    system "#{bin}/ryk", "plugin", "doctor", "hermes", "--json"
    system "#{bin}/ryk", "redteam", "--ci"
  end
end
