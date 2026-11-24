@echo off
setlocal EnableExtensions
title WARP Rotate

set "PS1=%~dp0Warp-Rotate.ps1"
set "CODE=1"

echo.
echo   WARP rotation launcher
echo   folder: %~dp0
echo.

if not exist "%PS1%" (
  echo   [ERROR] Missing Warp-Rotate.ps1 next to this launcher.
  echo   expected: "%PS1%"
  goto done
)

set "RESETER_LAUNCHER=1"

where pwsh >nul 2>nul
if not errorlevel 1 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)
set "CODE=%ERRORLEVEL%"

:done
echo.
if "%CODE%"=="0" (
  echo   [OK] WARP rotation finished.
) else (
  echo   [ERROR] WARP rotation failed. Exit code: %CODE%
  echo   Make sure Cloudflare WARP is installed and running.
)
echo   exit code: %CODE%
echo.

if "%RESETER_NOPAUSE%"=="1" exit /b %CODE%
echo   Press any key to close this window . . .
pause >nul
exit /b %CODE%