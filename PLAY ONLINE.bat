@echo off
rem Double-click this file to play Emberfall with accounts and cloud saves.
rem It starts the API server and the game; close the game to stop the server.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\start_online_dev.ps1"
pause
