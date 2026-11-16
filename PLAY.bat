@echo off
rem Double-click this file to play Emberfall.
rem The game uses the local save only - no server needed.
cd /d "%~dp0"
start "Emberfall" "%~dp0Godot_v4.7.2-stable_win64.exe" --path .
