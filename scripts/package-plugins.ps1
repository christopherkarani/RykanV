#!/usr/bin/env pwsh
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$defaultVersion = "1.2.0"
if (Test-Path -LiteralPath (Join-Path $repoRoot "VERSION")) {
    $defaultVersion = (Get-Content -LiteralPath (Join-Path $repoRoot "VERSION") -TotalCount 1).Trim()
}
$VERSION = if ($env:RYK_PLUGIN_VERSION) { $env:RYK_PLUGIN_VERSION } elseif ($env:RYK_VERSION) { $env:RYK_VERSION } else { $defaultVersion }
$DIST_DIR = if ($env:RYK_DIST_DIR) { $env:RYK_DIST_DIR } else { "dist/plugins" }
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT = Resolve-Path (Join-Path $SCRIPT_DIR "..")

Write-Host "Packaging ryk plugins v${VERSION}..."

if (Test-Path $DIST_DIR) {
  Remove-Item -Recurse -Force $DIST_DIR
}
New-Item -ItemType Directory -Force -Path $DIST_DIR | Out-Null

function Package-Plugin {
  param(
    [string]$PluginDir,
    [string]$ZipPath,
    [string[]]$IncludeFiles
  )

  if (-not (Test-Path $PluginDir)) {
    Write-Error "Plugin directory not found: $PluginDir"
  }

  $tempDir = Join-Path $env:TEMP "ryk-plugin-$(Get-Random)"
  New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

  try {
    foreach ($pattern in $IncludeFiles) {
      $source = Join-Path $PluginDir $pattern
      if (Test-Path $source) {
        $dest = Join-Path $tempDir $pattern
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) {
          New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        if ((Get-Item $source).PSIsContainer) {
          Copy-Item -Recurse -Force $source $destDir
        } else {
          Copy-Item -Force $source $dest
        }
      }
    }

    # Remove unwanted files
    Get-ChildItem -Recurse -Force $tempDir | Where-Object {
      $_.Name -match '\.DS_Store|\.mcp\.json|drone|build|tmp|secret'
    } | Remove-Item -Recurse -Force

    Compress-Archive -Path (Join-Path $tempDir "*") -DestinationPath $ZipPath -Force
    Write-Host "Created $ZipPath"
  } finally {
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}

# Package Codex plugin
$CODEX_PLUGIN_DIR = Join-Path $REPO_ROOT "integrations/codex-plugin"
$CODEX_ZIP = Join-Path $DIST_DIR "ryk-codex-plugin-v${VERSION}.zip"
Package-Plugin -PluginDir $CODEX_PLUGIN_DIR -ZipPath $CODEX_ZIP -IncludeFiles @(
  ".codex-plugin/plugin.json",
  "skills",
  "hooks",
  "README.md"
)

# Package Claude Code plugin
$CLAUDE_PLUGIN_DIR = Join-Path $REPO_ROOT "integrations/claude-code-plugin"
$CLAUDE_ZIP = Join-Path $DIST_DIR "orca-claude-code-plugin-v${VERSION}.zip"
Package-Plugin -PluginDir $CLAUDE_PLUGIN_DIR -ZipPath $CLAUDE_ZIP -IncludeFiles @(
  ".claude-plugin/plugin.json",
  "skills",
  "hooks",
  "README.md"
)

# Package OpenCode plugin
$OPENCODE_PLUGIN_DIR = Join-Path $REPO_ROOT "integrations/opencode-plugin"
$OPENCODE_ZIP = Join-Path $DIST_DIR "ryk-opencode-plugin-v${VERSION}.zip"
if (Test-Path $OPENCODE_PLUGIN_DIR) {
  Package-Plugin -PluginDir $OPENCODE_PLUGIN_DIR -ZipPath $OPENCODE_ZIP -IncludeFiles @(
    "orca.ts",
    "README.md",
    "package.json",
    "examples"
  )
} else {
  Write-Warning "OpenCode plugin directory not found: $OPENCODE_PLUGIN_DIR"
}

# Package Claude marketplace catalog
$MARKETPLACE_DIR = Join-Path $REPO_ROOT "integrations/claude-marketplace"
$MARKETPLACE_ZIP = Join-Path $DIST_DIR "orca-claude-marketplace-v${VERSION}.zip"
if (Test-Path $MARKETPLACE_DIR) {
  Package-Plugin -PluginDir $MARKETPLACE_DIR -ZipPath $MARKETPLACE_ZIP -IncludeFiles @(
    ".claude-plugin/marketplace.json",
    "README.md"
  )
} else {
  Write-Warning "Claude marketplace directory not found: $MARKETPLACE_DIR"
}

# Generate checksums
Write-Host "Generating checksums..."
$CHECKSUMS_FILE = Join-Path $DIST_DIR "ryk-plugin-checksums.txt"
$checksums = @()

foreach ($file in Get-ChildItem -Path $DIST_DIR -Filter "*.zip") {
  $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash.ToLower()
  $checksums += "$hash  $($file.Name)"
}

if ($checksums.Count -eq 0) {
  Write-Error "No plugin artifacts found in $DIST_DIR"
}

$checksums | Out-File -FilePath $CHECKSUMS_FILE -Encoding utf8
Write-Host "Created $CHECKSUMS_FILE"

# Verify no secrets in artifacts
Write-Host "Scanning artifacts for potential secrets..."
$SECRET_PATTERNS = @('password', 'secret', 'token', 'api_key', 'apikey', 'private_key', 'privkey', 'aws_access', 'aws_secret', 'github_token', 'gcp_key', 'azure_key')
$SCAN_ISSUES = 0

foreach ($file in Get-ChildItem -Path $DIST_DIR -Filter "*.zip") {
  # List contents and check for suspicious filenames
  $entries = [System.IO.Compression.ZipFile]::OpenRead($file.FullName).Entries
  foreach ($entry in $entries) {
    foreach ($pattern in $SECRET_PATTERNS) {
      if ($entry.Name -imatch $pattern -and $entry.Name -inotmatch 'fake_' -and $entry.Name -inotmatch 'README' -and $entry.Name -inotmatch 'SKILL\.md' -and $entry.Name -inotmatch 'hooks\.json' -and $entry.Name -inotmatch 'plugin\.json' -and $entry.Name -inotmatch 'marketplace\.json') {
        Write-Warning "Potential secret-like filename in $($file.Name): $($entry.Name)"
        $SCAN_ISSUES++
      }
    }
  }
}

# Scan file contents for secret patterns
foreach ($file in Get-ChildItem -Path $DIST_DIR -Filter "*.zip") {
  $tmpDir = Join-Path $env:TEMP "orca-scan-$(Get-Random)"
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  try {
    Expand-Archive -Path $file.FullName -DestinationPath $tmpDir -Force
    $files = Get-ChildItem -Recurse -File $tmpDir
    foreach ($f in $files) {
      $content = Get-Content -Raw $f.FullName
      foreach ($pattern in $SECRET_PATTERNS) {
        $regex = "(?i)$pattern\s*[:=]\s*[\"']?[a-zA-Z0-9_/-]{16,}"
        if ($content -match $regex) {
          $match = $content | Select-String -Pattern $regex | Select-Object -First 1
          $line = if ($match) { $match.Line.Trim() } else { "(match found)" }
          # Skip fake/example/placeholder values
          if ($line -inotmatch 'fake_' -and $line -inotmatch 'example' -and $line -inotmatch 'placeholder' -and $line -inotmatch 'your_') {
            Write-Warning "Potential secret pattern in $($file.Name) / $($f.FullName.Replace($tmpDir, '')): $line"
            $SCAN_ISSUES++
          }
        }
      }
    }
  } finally {
    if (Test-Path $tmpDir) {
      Remove-Item -Recurse -Force $tmpDir
    }
  }
}

if ($SCAN_ISSUES -eq 0) {
  Write-Host "Secret scan passed. No obvious secrets found in artifacts."
} else {
  throw "Secret scan found $SCAN_ISSUES potential issues. Failing release packaging."
}

Write-Host ""
Write-Host "Plugin packaging complete. Artifacts in ${DIST_DIR}:"
Get-ChildItem -Path $DIST_DIR | Format-Table -AutoSize
Write-Host ""
Get-Content $CHECKSUMS_FILE
