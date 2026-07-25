# ryk Plugin Baseline Smoke Test
# Safe checks only. No drone hardware. No network. No secrets.

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT = Resolve-Path (Join-Path $SCRIPT_DIR "..")
$ORCA_BIN = Join-Path $REPO_ROOT "zig-out\bin\orca.exe"
$EDGE_BIN = Join-Path $REPO_ROOT "zig-out\bin\edge.exe"

$ERRORS = 0

function Log-Info($msg) { Write-Host "[INFO]  $msg" }
function Log-Pass($msg) { Write-Host "[PASS]  $msg" }
function Log-Fail($msg) { Write-Host "[FAIL]  $msg"; $script:ERRORS++ }

Push-Location $REPO_ROOT

try {
    Log-Info "=== ryk Plugin Baseline Smoke Test ==="
    Log-Info "Repo: $REPO_ROOT"
    Log-Info "Date: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host ""

    # 1. Build
    Log-Info "Running zig build..."
    try {
        $null = zig build 2>$null
        Log-Pass "zig build"
    } catch {
        Log-Fail "zig build"
    }
    Write-Host ""

    # 2. Tests
    Log-Info "Running zig build test..."
    try {
        $null = zig build test 2>$null
        Log-Pass "zig build test"
    } catch {
        Log-Fail "zig build test"
    }
    Write-Host ""

    # 3. CLI smoke tests
    Log-Info "Running CLI smoke tests..."

    if (Test-Path $ORCA_BIN) {
        try { $null = & $ORCA_BIN --help 2>$null; Log-Pass "orca --help" } catch { Log-Fail "orca --help" }
        try { $null = & $ORCA_BIN version 2>$null; Log-Pass "orca version" } catch { Log-Fail "orca version" }
        try { $null = & $ORCA_BIN doctor 2>$null; Log-Pass "orca doctor" } catch { Log-Fail "orca doctor" }
        try { $null = & $ORCA_BIN redteam --ci 2>$null; Log-Pass "orca redteam --ci" } catch { Log-Fail "orca redteam --ci" }
    } else {
        Log-Fail "orca binary not found at $ORCA_BIN"
    }
    Write-Host ""

    # 4. Edge CLI smoke tests
    Log-Info "Running Edge CLI smoke tests..."

    if (Test-Path $EDGE_BIN) {
        try { $null = & $EDGE_BIN --help 2>$null; Log-Pass "edge --help" } catch { Log-Fail "edge --help" }
        try { $null = & $EDGE_BIN doctor 2>$null; Log-Pass "edge doctor" } catch { Log-Fail "edge doctor" }
        try { $null = & $EDGE_BIN redteam --ci 2>$null; Log-Pass "edge redteam --ci" } catch { Log-Fail "edge redteam --ci" }
    } else {
        Log-Fail "edge binary not found at $EDGE_BIN"
    }
    Write-Host ""

    # 5. Check baseline docs exist
    Log-Info "Checking baseline docs..."

    $BASELINE_DOC = Join-Path $REPO_ROOT "docs\integrations\current-baseline.md"
    $SAFETY_DOC = Join-Path $REPO_ROOT "docs\integrations\drone-safepoint.md"

    if (Test-Path $BASELINE_DOC) {
        Log-Pass "docs/integrations/current-baseline.md exists"
    } else {
        Log-Fail "docs/integrations/current-baseline.md missing"
    }

    if (Test-Path $SAFETY_DOC) {
        Log-Pass "docs/integrations/drone-safepoint.md exists"
    } else {
        Log-Fail "docs/integrations/drone-safepoint.md missing"
    }
    Write-Host ""

    # Summary
    Log-Info "=== Smoke Test Summary ==="
    if ($ERRORS -eq 0) {
        Write-Host "All checks passed."
        exit 0
    } else {
        Write-Host "$ERRORS check(s) failed."
        exit 1
    }
} finally {
    Pop-Location
}
