# Builds the Android APK so the game can be put on a phone.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_android.ps1
#
# Options:
#   -Release      Build the release APK instead of the debug one
#   -Install      Install the APK on a phone connected over USB (adb)
#   -Out <path>   Where to write the APK (default: the preset's export path)
#   -Preset <n>   Export preset name (default "Android")
param(
    [switch]$Release,
    [switch]$Install,
    [string]$Out = "",
    [string]$Preset = "Android"
)

$ErrorActionPreference = "Stop"

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$godotConsole = Join-Path $root "Godot_v4.7.2-stable_win64_console.exe"
$godotGui = Join-Path $root "Godot_v4.7.2-stable_win64.exe"

if (-not (Test-Path $godotConsole)) {
    $godotConsole = $godotGui
}
if (-not (Test-Path $godotConsole)) {
    throw "Godot binary not found next to the project folder."
}

if ([string]::IsNullOrWhiteSpace($Out)) {
    # The Android preset exports to ../Export/EmberFall.apk.
    $Out = Join-Path (Split-Path $root -Parent) "Export\EmberFall.apk"
}
$Out = [System.IO.Path]::GetFullPath($Out)
$outDir = Split-Path $Out -Parent
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$flag = if ($Release) { "--export-release" } else { "--export-debug" }

# An open Godot editor keeps export_presets.cfg in memory and writes its own
# copy back, which can drop the INTERNET permission. Set it again before the
# export so the phone build can always reach the server.
$presetFile = Join-Path $root "export_presets.cfg"
if (Test-Path $presetFile) {
    $presetText = Get-Content $presetFile -Raw
    if ($presetText -notmatch "permissions/internet=true") {
        $updated = $presetText -replace "permissions/internet=false", "permissions/internet=true"
        if ($updated -ne $presetText) {
            Set-Content -Path $presetFile -Value $updated -NoNewline
            Write-Host "Set permissions/internet=true in export_presets.cfg."
        }
    }
}

Write-Host "Exporting the '$Preset' preset to $Out ..."
Push-Location $root
try {
    & $godotConsole --headless --path . $flag $Preset $Out
    if ($LASTEXITCODE -ne 0) {
        throw "Godot export failed with exit code $LASTEXITCODE."
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $Out)) {
    throw "The export finished but no APK was written to $Out."
}

$sizeMb = [math]::Round((Get-Item $Out).Length / 1MB, 1)
Write-Host "APK built: $Out  ($sizeMb MB)"

# The Android system blocks networking without the INTERNET permission, so
# warn when the manifest is missing it.
$aapt2 = Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\build-tools" -Filter "aapt2.exe" `
    -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($aapt2) {
    # aapt2 writes harmless warnings to stderr, so do not treat them as errors.
    $ErrorActionPreference = "Continue"
    $dump = & $aapt2.FullName dump xmltree $Out --file AndroidManifest.xml 2>$null
    $ErrorActionPreference = "Stop"
    if ($dump -match "android.permission.INTERNET") {
        Write-Host "Manifest check: INTERNET permission present."
    } else {
        throw "The APK has no INTERNET permission, so the game cannot reach the server. Close the Godot editor (it overwrites export_presets.cfg), then build again."
    }
}

if ($Install) {
    $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    if (-not (Test-Path $adb)) {
        throw "adb was not found at $adb"
    }
    $devices = & $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "\S" }
    if (-not $devices) {
        throw "No phone is connected. Turn on USB debugging and plug the phone in."
    }
    Write-Host "Installing on: $devices"
    & $adb install -r $Out
    if ($LASTEXITCODE -ne 0) {
        throw "adb install failed with exit code $LASTEXITCODE."
    }
    Write-Host "Installed. Open Emberfall on the phone."
}
