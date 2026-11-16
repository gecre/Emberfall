# Boots a throwaway Emberfall server, runs the Godot client end-to-end test,
# then removes the server and its database.
$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$serverDir = Join-Path $root "server"
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

$temp = Join-Path $env:TEMP ("emberfall-godot-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp | Out-Null

$port = 7599
$env:PORT = "$port"
$env:HOST = "127.0.0.1"
$env:EMBERFALL_DATA_DIR = $temp
$env:EMBERFALL_DB = (Join-Path $temp "test.sqlite")
$env:EMBERFALL_JWT_SECRET = "godot-test-secret"
$env:EMBERFALL_QUIET = "1"

$server = Start-Process -FilePath $nodeExe -ArgumentList "src/index.js" `
    -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden

$code = 1
try {
    $ready = $false
    for ($i = 0; $i -lt 100; $i++) {
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 1
            if ($health.ok) { $ready = $true; break }
        } catch {
            # server still starting
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw "Test server did not start on port $port." }

    $env:EMBERFALL_API_URL = "http://127.0.0.1:$port/api"
    $code = 0
    foreach ($scene in @("res://tools/online_test.tscn", "res://tools/character_select_test.tscn")) {
        & $godot --headless --path $root $scene
        if ($LASTEXITCODE -ne 0) {
            $code = $LASTEXITCODE
            break
        }
    }
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue
    Remove-Item Env:EMBERFALL_API_URL -ErrorAction SilentlyContinue
}

exit $code
