@echo off
REM Double-click to stop PC Temp Monitor from starting at login.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Autostart.ps1" -Uninstall
