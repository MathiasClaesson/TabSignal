@echo off
REM Start-Process needs an executable, so this hands the argument list to fake-wt.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-wt.ps1" %*
