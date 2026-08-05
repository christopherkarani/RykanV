param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("opencode", "openclaw", "hermes", "hermess")]
    [string]$Host,
    [ValidateSet("project", "global")]
    [string]$Scope = "project"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$doctorHost = if ($Host -eq "hermess") { "hermes" } else { $Host }

function Get-RepoVersion {
    $versionPath = Join-Path $repoRoot "VERSION"
    if (Test-Path -LiteralPath $versionPath) {
        return (Get-Content -LiteralPath $versionPath -TotalCount 1).Trim()
    }
    return "1.2.0"
}

function Resolve-OrcaExecutable([string]$Candidate) {
    if (-not $Candidate) { return $null }
    if (Test-Path -LiteralPath $Candidate) { return (Resolve-Path -LiteralPath $Candidate).Path }
    $command = Get-Command $Candidate -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Test-OrcaSupportsHermes([string]$OrcaBin) {
    $payload = Get-Content -Raw (Join-Path $repoRoot "tests/fixtures/hook-safe.json")
    $output = $payload | & $OrcaBin hook hermes pre_tool_call 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if (-not $output) { return $true }
    try {
        $parsed = $output | ConvertFrom-Json
        return $parsed.decision -ne 'block'
    } catch {
        return $output -notmatch '"decision"\s*:\s*"block"'
    }
}

function Test-OrcaCandidate([string]$Candidate) {
    $resolved = Resolve-OrcaExecutable $Candidate
    if (-not $resolved) { return $null }
    if ($doctorHost -eq "hermes") {
        if (Test-OrcaSupportsHermes $resolved) { return $resolved }
        return $null
    }
    return $resolved
}

function Resolve-OrcaBin {
    $candidates = @(
        $env:RYK_BIN,
        (Join-Path $repoRoot "zig-out/bin/ryk.exe"),
        (Join-Path $repoRoot "zig-out/bin/ryk"),
        (Join-Path $HOME ".local/bin/ryk.exe"),
        (Join-Path $HOME ".local/bin/ryk"),
        (Join-Path $HOME ".ryk/bin/ryk.exe"),
        (Join-Path $HOME ".ryk/bin/ryk")
    )
    $pathOrca = Get-Command "ryk" -ErrorAction SilentlyContinue
    if ($pathOrca) { $candidates += $pathOrca.Source }

    foreach ($candidate in $candidates) {
        $resolved = Test-OrcaCandidate $candidate
        if ($resolved) { return $resolved }
    }
    return $null
}

$rykBin = Resolve-OrcaBin
if (-not $rykBin) {
    $env:RYK_VERSION = Get-RepoVersion
    $distDir = Join-Path $repoRoot "dist"
    if (Test-Path -LiteralPath $distDir) {
        $env:RYK_ARTIFACT_DIR = $distDir
    }
    & (Join-Path $repoRoot "scripts/install.ps1")
    $installDir = if ($env:RYK_INSTALL_DIR) {
        $env:RYK_INSTALL_DIR
    } else {
        Join-Path $HOME ".ryk\bin"
    }
    $rykBin = Join-Path $installDir "ryk.exe"
}

$resolvedOrca = Resolve-OrcaExecutable $rykBin
if (-not $resolvedOrca) {
    throw "orca binary not found after install attempt"
}
$rykBin = $resolvedOrca

if ($doctorHost -eq "hermes" -and -not (Test-OrcaSupportsHermes $rykBin)) {
    throw "orca at $rykBin does not support Hermes hooks (upgrade required)"
}

if ($doctorHost -eq "opencode") {
    & $rykBin plugin install opencode --scope $Scope --yes
} elseif ($doctorHost -eq "hermes") {
    & $rykBin plugin install hermes --yes
} else {
    & $rykBin plugin install openclaw --yes
}

& $rykBin plugin doctor $doctorHost
