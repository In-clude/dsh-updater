@echo off
chcp 65001 >nul
setlocal
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
rem Files downloaded/copied from the internet carry a Zone.Identifier mark, and the
rem default RemoteSigned policy refuses to run unsigned .ps1 files. Clear the mark
rem for this folder first (no-op on files without it).
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -File -Force | Unblock-File" >nul 2>nul
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-Dsh.ps1" %*
set "CODE=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %CODE%
