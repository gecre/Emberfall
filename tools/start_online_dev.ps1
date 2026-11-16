# Starts the Emberfall API server and the game so the online features can be
# tried out by hand.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\start_online_dev.ps1
#
# Options:
#   -Port <n>    API port (default 7575)
#   -NoGame      Only start the server and leave it running
#   -Headless    Run the game without a window (useful for smoke tests)
#   -Lan         Bind the API to every network interface so a phone on the
#                same Wi-Fi can reach it (prints the address to use)
param(
    [int]$Port = 7575,
    [switch]$NoGame,
    [switch]$Headless,
    [switch]$Lan
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$serverDir = Join-Path $root "server"
$godotConsole = Join-Path $root "Godot_v4.7.2-stable_win64_console.exe"
$godotGui = Join-Path $root "Godot_v4.7.2-stable_win64.exe"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $nodeExe = $node.Source
} elseif (Test-Path "C:\Program Files\nodejs\node.exe") {
    $nodeExe = "C:\Program Files\nodejs\node.exe"
} else {
    throw "Node.js was not found. Install it or add it to PATH."
}

if (-not (Test-Path $godotConsole)) {
    throw "Godot console binary not found at $godotConsole"
}

if (-not (Test-Path (Join-Path $serverDir "node_modules"))) {
    Write-Host "Installing server dependencies..."
    & (Join-Path (Split-Path $nodeExe) "npm.cmd") install --prefix $serverDir --no-audit --no-fund
}

$env:PORT = "$Port"
if ($Lan) {
    $env:HOST = "0.0.0.0"
} else {
    $env:HOST = "127.0.0.1"
}
$env:EMBERFALL_API_URL = "http://127.0.0.1:$Port/api"

Write-Host "Starting the Emberfall API on http://$($env:HOST):$Port/api ..."
$logDir = Join-Path $serverDir "data"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "server.log"
$server = Start-Process -FilePath $nodeExe -ArgumentList "src/index.js" `
    -WorkingDirectory $serverDir -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $logFile -RedirectStandardError (Join-Path $logDir "server.err.log")

$ready = $false
for ($i = 0; $i -lt 100; $i++) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 1
        if ($health.ok) { $ready = $true; break }
    } catch {
        # still starting
    }
    if ($server.HasExited) { break }
    Start-Sleep -Milliseconds 100
}
if (-not $ready) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Write-Host "--- server log ---"
    Get-Content $logFile -ErrorAction SilentlyContinue | Select-Object -Last 20
    Get-Content (Join-Path $logDir "server.err.log") -ErrorAction SilentlyContinue | Select-Object -Last 20
    throw "The API server did not start on port $Port. See server\data\server.log"
}
Write-Host "API is up: http://127.0.0.1:$Port/api  (log: server\data\server.log)"

if ($Lan) {
    # A phone cannot use 127.0.0.1, so print the addresses it can use.
    $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        Select-Object -ExpandProperty IPAddress -Unique
    if ($addresses) {
        Write-Host "Reachable from a phone on the same Wi-Fi (enter this in the game's Server field):"
        foreach ($address in $addresses) {
            Write-Host "  http://$address`:$Port/api"
        }
    } else {
        Write-Host "No network address found. Check that the computer is on Wi-Fi."
    }
    Write-Host "Windows Firewall must allow Node.js on private networks."
}

if ($NoGame) {
    Write-Host "Server running (PID $($server.Id)). Press Ctrl+C to stop."
    try {
        Wait-Process -Id $server.Id
    } finally {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$godotBin = $godotGui
# "." is used because the project path contains a space and Start-Process does
# not quote arguments for us.
$godotArgs = @("--path", ".")
if ($Headless) {
    $godotArgs += "--headless"
    $godotBin = $godotConsole
    $godotArgs += "--quit-after", "3600"
}

Write-Host "Starting the game. Close the window to stop the server."
try {
    # Run from the project folder so the path never needs quoting (it contains
    # a space, which would otherwise be split into two arguments).
    Push-Location $root
    try {
        $game = Start-Process -FilePath $godotBin -ArgumentList $godotArgs `
            -WorkingDirectory $root -PassThru
    } finally {
        Pop-Location
    }
    Wait-Process -Id $game.Id
} finally {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item Env:EMBERFALL_API_URL -ErrorAction SilentlyContinue
    Write-Host "Server stopped."
}
