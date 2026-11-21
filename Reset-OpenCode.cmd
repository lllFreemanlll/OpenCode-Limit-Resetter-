@echo off
setlocal EnableExtensions
set "PS1=%~dp0Reset-OpenCode.ps1"

if not exist "%PS1%" (
  echo Missing Reset-OpenCode.ps1 next to this launcher.
  if "%~1"=="" pause
  exit /b 1
)

set "ARGS=%*"
if "%~1"=="" set "ARGS=-Wait -ZeroTokens"

where pwsh >nul 2>nul
if not errorlevel 1 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
)

set "CODE=%ERRORLEVEL%"
echo.
echo Exit code: %CODE%
if "%~1"=="" pause
exit /b %CODE%