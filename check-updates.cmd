@echo off
chcp 65001 >nul
setlocal
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Dsh.ps1" -DryRun %*
set "CODE=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %CODE%
