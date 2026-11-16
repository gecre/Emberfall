# Starts the Emberfall API server and opens the admin dashboard.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\start_admin.ps1
#
# Options:
#   -Port <n>      API port (default 7575)
#   -NoBrowser     Start the server but do not open a browser
#
# If the server is already running it is reused and only the browser is opened.
param(
    [int]$Port = 7575,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$serverDir = Join-Path $root "server"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $nodeExe = $node.Source
} elseif (Test-Path "C:\Program Files\nodejs\node.exe") {
    $nodeExe = "C:\Program Files\nodejs\node.exe"
} else {
    throw "Node.js was not found. Install it or add it to PATH."
}

$url = "http://127.0.0.1:$Port/admin"
$health = "http://127.0.0.1:$Port/api/health"

function Test-ServerUp {
    try {
        $res = Invoke-RestMethod -Uri $health -TimeoutSec 1
        return $res.ok -eq $true
    } catch {
        return $false
    }
}

# --- reuse a running server -----------------------------------------------
if (Test-ServerUp) {
    Write-Host "The API server is already running on port $Port." -ForegroundColor Green
    Write-Host "Opening the admin dashboard: $url"
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}

# --- start the server ------------------------------------------------------
$logDir = Join-Path $serverDir "data"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "server.log"
$errFile = Join-Path $logDir "server.err.log"

Write-Host "Starting the Emberfall API on http://127.0.0.1:$Port/api ..."
$server = Start-Process -FilePath $nodeExe -ArgumentList "src/index.js" `
    -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $logFile -RedirectStandardError $errFile

$ready = $false
for ($i = 0; $i -lt 100; $i++) {
    if (Test-ServerUp) { $ready = $true; break }
    if ($server.HasExited) { break }
    Start-Sleep -Milliseconds 100
}

if (-not $ready) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Write-Host "--- server log ---" -ForegroundColor Red
    Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 20
    Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 20
    throw "The API server did not start on port $Port."
}

# The admin key is printed in the log; read it back so it can be shown here.
$key = ""
foreach ($line in (Get-Content $logFile -ErrorAction SilentlyContinue)) {
    if ($line -match "Admin key:\s+(\S+)") { $key = $Matches[1] }
}

Write-Host ""
Write-Host "Admin dashboard:  $url" -ForegroundColor Cyan
if ($key) { Write-Host "Admin key:       $key" -ForegroundColor Cyan }
Write-Host "(the key is already built into the page - no login needed)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Server running (PID $($server.Id)). Press Ctrl+C to stop." -ForegroundColor Green

if (-not $NoBrowser) {
    Start-Process $url
}

try {
    Wait-Process -Id $server.Id
} finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Server stopped."
}
