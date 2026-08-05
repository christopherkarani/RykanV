param(
    [string]$Version = $(if ($env:RYK_VERSION) { $env:RYK_VERSION } else { "1.1.0" }),
    [string]$Commit = $(if ($env:RYK_COMMIT) { $env:RYK_COMMIT } else { "unknown" }),
    [string]$BuildDate = $(if ($env:RYK_BUILD_DATE) { $env:RYK_BUILD_DATE } else { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }),
    [string]$DistDir = $(if ($env:RYK_DIST_DIR) { $env:RYK_DIST_DIR } else { "dist" }),
    [switch]$ArchiveOnly
)

$ErrorActionPreference = "Stop"

$targets = @(
    @{ Os = "darwin"; Arch = "amd64"; Zig = "x86_64-macos"; Ext = "tar.gz"; Bin = "ryk" },
    @{ Os = "darwin"; Arch = "arm64"; Zig = "aarch64-macos"; Ext = "tar.gz"; Bin = "ryk" },
    @{ Os = "linux"; Arch = "amd64"; Zig = "x86_64-linux"; Ext = "tar.gz"; Bin = "ryk" },
    @{ Os = "linux"; Arch = "arm64"; Zig = "aarch64-linux"; Ext = "tar.gz"; Bin = "ryk" },
    @{ Os = "windows"; Arch = "amd64"; Zig = "x86_64-windows"; Ext = "zip"; Bin = "ryk.exe" }
)

function Copy-ReleasePayload($Root) {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Copy-Item README.md, LICENSE, SECURITY.md, CONTRIBUTING.md -Destination $Root
    foreach ($path in @("docs", "policies", "schemas", "fixtures", "examples", "packages", "packaging", "scripts")) {
        Copy-Item $path -Destination $Root -Recurse
    }
    Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory |
        Where-Object { $_.Name -in @("__pycache__", ".pytest_cache") } |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
        Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
        Remove-Item -Force
}

if (Test-Path -LiteralPath $DistDir) { Remove-Item -LiteralPath $DistDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

foreach ($target in $targets) {
    $artifact = "ryk-v$Version-$($target.Os)-$($target.Arch).$($target.Ext)"
    $work = Join-Path $DistDir "work/$($target.Os)-$($target.Arch)"
    $prefix = Join-Path $work "prefix"
    $root = Join-Path $work "ryk-v$Version-$($target.Os)-$($target.Arch)"

    New-Item -ItemType Directory -Force -Path $prefix, $root | Out-Null
    zig build install-ryk -Dtarget=$($target.Zig) -Doptimize=ReleaseSafe -Dversion=$Version -Dcommit=$Commit -Dbuild-date=$BuildDate --prefix $prefix

    Copy-ReleasePayload $root
    New-Item -ItemType Directory -Force -Path (Join-Path $root "bin") | Out-Null
    Copy-Item -LiteralPath (Join-Path $prefix "bin/$($target.Bin)") -Destination (Join-Path $root "bin/$($target.Bin)")
    # CLI-only: Zig shell_engine evaluates in-process (no ryk-daemon product binary).

    if ($target.Ext -eq "zip") {
        Compress-Archive -LiteralPath $root -DestinationPath (Join-Path $DistDir $artifact) -Force
    } else {
        tar -C $work -czf (Join-Path $DistDir $artifact) (Split-Path -Leaf $root)
    }
    Write-Host "Built $(Join-Path $DistDir $artifact)"
}

if ($env:RYK_SIGNING_ENABLED -eq "1") {
    if (-not $env:RYK_SIGNING_COMMAND) {
        Write-Error "Signing requested but RYK_SIGNING_COMMAND is not set."
        exit 1
    }
    Invoke-Expression $env:RYK_SIGNING_COMMAND
} else {
    Write-Host "Signing skipped; set RYK_SIGNING_ENABLED=1 and RYK_SIGNING_COMMAND in release environments."
}

$checksumsPath = Join-Path $DistDir "checksums.txt"
$checksumLines = foreach ($artifact in Get-ChildItem -LiteralPath $DistDir -File | Where-Object { $_.Name -like "ryk-v*.tar.gz" -or $_.Name -like "ryk-v*.zip" } | Sort-Object Name) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact.FullName).Hash.ToLowerInvariant()
    "$hash  $($artifact.Name)"
}
if (-not $checksumLines) {
    Write-Error "No release artifacts found in $DistDir"
    exit 1
}
$checksumLines | Set-Content -LiteralPath $checksumsPath -Encoding ASCII
Write-Host "Wrote $checksumsPath"

$sbomPath = Join-Path $DistDir "sbom.json"
$sbom = [ordered]@{
    sbom_format = "placeholder"
    name = "orca-core"
    version = $Version
    generator = "scripts/build-release.ps1"
    status = "hook-only"
    note = "Phase 19 provides an SBOM hook. Replace this placeholder with CycloneDX/SPDX output in the release environment if an SBOM tool is available."
    components = @(
        [ordered]@{
            name = "ryk"
            type = "application"
            language = "zig"
            dependencies = @()
        }
    )
}
$sbom | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sbomPath -Encoding ASCII
Write-Host "Wrote $sbomPath"

if (-not $ArchiveOnly) {
    Write-Error "scripts/build-release.ps1 builds ryk archive fixtures only and does not produce release-manifest.json/package-manifests. Use scripts/build-release.sh for production release verification, or pass -ArchiveOnly for local archive smoke tests."
    exit 1
}
