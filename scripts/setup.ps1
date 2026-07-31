#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = Split-Path -Parent $ScriptDir
$InstallDir = if ($env:RYK_INSTALL_DIR) { $env:RYK_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".ryk\bin" }

function Resolve-OrcaBin {
    $cmd = Get-Command ryk.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $localBuild = Join-Path $RepoRoot "zig-out\bin\ryk.exe"
    if (Test-Path -LiteralPath $localBuild) { return $localBuild }
    $installed = Join-Path $InstallDir "ryk.exe"
    if (Test-Path -LiteralPath $installed) { return $installed }
    return $null
}

$OrcaBin = Resolve-OrcaBin
if (-not $OrcaBin) {
    & "$ScriptDir\install.ps1"
    $OrcaBin = Join-Path $InstallDir "ryk.exe"
}

& $OrcaBin setup --auto
