@echo off
rem Opens the Emberfall admin dashboard in your browser.
rem
rem Starts the API server first if it is not already running.
rem Close this window (or press Ctrl+C) to stop the server.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_admin.ps1"
pause
