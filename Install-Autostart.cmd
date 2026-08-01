@echo off
REM Double-click to make PC Temp Monitor start automatically at login.
REM It will ask for Administrator rights (accept the prompt).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Autostart.ps1"
