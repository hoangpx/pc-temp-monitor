@echo off
REM Double-click this file to start PC Temp Monitor.
REM It will ask for Administrator rights (needed to read hardware temperatures).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Monitor.ps1"
