@echo off
REM tab from cmd - see tab.ps1. -NewTab cannot close the old tab from here,
REM since only the dot-sourced profile function can close the shell it runs in.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tab.ps1" %*
