# Runs the whole Emberfall test suite: the server API test, the Godot
# client/server tests and the offline regression scenes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\test_all.ps1
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$godot = Join-Path $root "Godot_v4.7.2-stable_win64_console.exe"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $nodeExe = $node.Source
} elseif (Test-Path "C:\Program Files\nodejs\node.exe") {
    $nodeExe = "C:\Program Files\nodejs\node.exe"
} else {
    throw "Node.js was not found. Install it or add it to PATH."
}

if (-not (Test-Path $godot)) {
    throw "Godot console binary not found at $godot"
}

$failed = @()

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        $script:failed += $Name
        Write-Host "FAILED: $Name" -ForegroundColor Red
    }
}

Invoke-Step "Server API test" {
    & $nodeExe (Join-Path $root "server\test\api_test.js")
}

Invoke-Step "Server backup/restore test" {
    & $nodeExe (Join-Path $root "server\test\backup_test.js")
}

Invoke-Step "Server admin CLI test" {
    & $nodeExe (Join-Path $root "server\test\admin_test.js")
}

Invoke-Step "Server admin dashboard test" {
    & $nodeExe (Join-Path $root "server\test\admin_web_test.js")
}

Invoke-Step "Client/server tests (Godot)" {
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $root "server\test\run_godot_online_test.ps1")
}

Invoke-Step "Offline regression: mobile UI" {
    & $godot --headless --path $root res://tools/mobile_ui_smoke.tscn
}

Invoke-Step "Offline regression: stats" {
    & $godot --headless --path $root res://tools/test_stats.tscn
}

Invoke-Step "Offline regression: loot" {
    & $godot --headless --path $root res://tools/loot_test_scene.tscn
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "ALL SUITES PASSED" -ForegroundColor Green
    exit 0
}
Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
exit 1
