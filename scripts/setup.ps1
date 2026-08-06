#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot = Split-Path -Parent $ScriptDir
$InstallDir = if ($env:RYK_INSTALL_DIR) { $env:RYK_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".ryk\bin" }

function Resolve-RykBin {
    $cmd = Get-Command ryk.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $localBuild = Join-Path $RepoRoot "zig-out\bin\ryk.exe"
    if (Test-Path -LiteralPath $localBuild) { return $localBuild }
    $installed = Join-Path $InstallDir "ryk.exe"
    if (Test-Path -LiteralPath $installed) { return $installed }
    return $null
}

$RykBin = Resolve-RykBin
if (-not $RykBin) {
    & "$ScriptDir\install.ps1"
    $RykBin = Join-Path $InstallDir "ryk.exe"
}

& $RykBin start --auto
