@echo off
rem Finds a bypass method that works on this network. Run install.cmd after it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test.ps1"
pause
