param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("opencode", "openclaw", "hermes")]
    [string]$Host,
    [ValidateSet("project", "global")]
    [string]$Scope = "project"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$doctorHost = $Host

function Get-RepoVersion {
    $versionPath = Join-Path $repoRoot "VERSION"
    if (Test-Path -LiteralPath $versionPath) {
        return (Get-Content -LiteralPath $versionPath -TotalCount 1).Trim()
    }
    return "1.2.9"
}

function Resolve-RykExecutable([string]$Candidate) {
    if (-not $Candidate) { return $null }
    if (Test-Path -LiteralPath $Candidate) { return (Resolve-Path -LiteralPath $Candidate).Path }
    $command = Get-Command $Candidate -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Test-RykSupportsHermes([string]$RykBin) {
    $payload = Get-Content -Raw (Join-Path $repoRoot "tests/fixtures/hook-safe.json")
    $output = $payload | & $RykBin hook hermes pre_tool_call 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if (-not $output) { return $false }
    try {
        $parsed = $output | ConvertFrom-Json
        return $parsed.decision -in @('allow', 'warn', 'ask')
    } catch {
        return $output -match '"decision"\s*:\s*"(allow|warn|ask)"'
    }
}

function Test-RykCandidate([string]$Candidate) {
    $resolved = Resolve-RykExecutable $Candidate
    if (-not $resolved) { return $null }
    if ($doctorHost -eq "hermes") {
        if (Test-RykSupportsHermes $resolved) { return $resolved }
        return $null
    }
    return $resolved
}

function Resolve-RykBin {
    $candidates = @(
        $env:RYK_BIN,
        (Join-Path $repoRoot "zig-out/bin/ryk.exe"),
        (Join-Path $repoRoot "zig-out/bin/ryk"),
        (Join-Path $HOME ".local/bin/ryk.exe"),
        (Join-Path $HOME ".local/bin/ryk"),
        (Join-Path $HOME ".ryk/bin/ryk.exe"),
        (Join-Path $HOME ".ryk/bin/ryk")
    )
    $pathRyk = Get-Command "ryk" -ErrorAction SilentlyContinue
    if ($pathRyk) { $candidates += $pathRyk.Source }

    foreach ($candidate in $candidates) {
        $resolved = Test-RykCandidate $candidate
        if ($resolved) { return $resolved }
    }
    return $null
}

$rykBin = Resolve-RykBin
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

$resolvedRyk = Resolve-RykExecutable $rykBin
if (-not $resolvedRyk) {
    throw "ryk binary not found after install attempt"
}
$rykBin = $resolvedRyk

if ($doctorHost -eq "hermes" -and -not (Test-RykSupportsHermes $rykBin)) {
    throw "ryk at $rykBin does not support Hermes hooks (upgrade required)"
}

if ($doctorHost -eq "opencode") {
    & $rykBin plugin install opencode --scope $Scope --yes
} elseif ($doctorHost -eq "hermes") {
    & $rykBin plugin install hermes --yes
} else {
    & $rykBin plugin install openclaw --yes
}

& $rykBin plugin doctor $doctorHost
